import Foundation
import SwiftData
import CryptoKit

/// Core sync engine — manages upload queue, download queue, conflict detection.
/// Operates on VaultCrypto + FastCDC interfaces.
@MainActor
public class VaultSyncEngine: ObservableObject {

    private let apiClient: VaultAPIClient
    private let modelContext: ModelContext
    private var uploadTask: Task<Void, Never>?

    @Published public var syncState: EngineState = .idle
    @Published public var activeUploads: Int = 0
    @Published public var activeDownloads: Int = 0

    public enum EngineState {
        case idle
        case syncing
        case uploading
        case downloading
        case error(String)
    }

    public init(apiClient: VaultAPIClient, modelContext: ModelContext) {
        self.apiClient = apiClient
        self.modelContext = modelContext
    }

    // MARK: - Upload

    /// Encrypt and upload a file. Chunks in parallel (max 8 concurrent).
    public func uploadFile(
        localURL: URL,
        parentFolderId: String?,
        folderKey: SymmetricKey,
        masterKey: SymmetricKey
    ) async throws -> String {
        syncState = .uploading
        activeUploads += 1
        defer { activeUploads -= 1 }

        let fileId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let data = try Data(contentsOf: localURL)

        // 1. Chunk with FastCDC
        let chunks = FastCDC.split(data)

        // 2. Encrypt each chunk with its own key
        var chunkDescriptors: [VaultManifest.ChunkDescriptor] = []
        var encryptedChunks: [(hash: String, data: Data)] = []

        for (index, chunk) in chunks.enumerated() {
            let chunkData = data[chunk.offset..<(chunk.offset + chunk.length)]
            let chunkKey = VaultCrypto.generateChunkKey()
            let encrypted = try VaultCrypto.encrypt(Data(chunkData), key: chunkKey)
            let encryptedKeyBlob = try VaultCrypto.encryptChunkKey(chunkKey, with: folderKey)
            let encryptedKeyB64 = encryptedKeyBlob.base64EncodedString()

            chunkDescriptors.append(VaultManifest.ChunkDescriptor(
                hash: chunk.hash,
                size: chunk.length,
                encryptedKeyB64: encryptedKeyB64,
                offsetInFile: chunk.offset
            ))
            encryptedChunks.append((hash: chunk.hash, data: encrypted))
        }

        // 3. Upload chunks in parallel batches of 8
        try await uploadChunksBatch(encryptedChunks, fileId: fileId)

        // 4. Build and encrypt manifest
        let filenameEnc = try encryptFilename(localURL.lastPathComponent, folderKey: folderKey)
        let manifest = VaultManifest(
            fileId: fileId,
            filenameEnc: filenameEnc,
            mimeTypeEnc: "",
            totalSize: Int64(data.count),
            createdAt: Date().timeIntervalSince1970,
            modifiedAt: Date().timeIntervalSince1970,
            parentVersion: 0,
            chunks: chunkDescriptors
        )

        let manifestData = try JSONEncoder().encode(manifest)
        let encryptedManifest = try VaultCrypto.encrypt(manifestData, key: folderKey)

        // 5. Upload manifest
        try await apiClient.uploadManifest(fileId: fileId, encryptedManifest: encryptedManifest)

        // 6. Save to local SwiftData
        let localFile = LocalFile(
            fileId: fileId,
            parentFolderId: parentFolderId,
            manifestVersion: 1,
            chunkHashes: chunks.map(\.hash),
            sizeBytes: Int64(data.count),
            modifiedAt: Date(),
            syncState: "synced",
            isPinned: false
        )
        modelContext.insert(localFile)
        try modelContext.save()

        syncState = .idle
        return fileId
    }

    private func uploadChunksBatch(_ chunks: [(hash: String, data: Data)], fileId: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for chunk in chunks {
                if inFlight >= 8 {
                    try await group.next()
                    inFlight -= 1
                }
                group.addTask {
                    let url = try await self.apiClient.presignPut(fileId: fileId, chunkHash: chunk.hash)
                    var req = URLRequest(url: url)
                    req.httpMethod = "PUT"
                    req.httpBody = chunk.data
                    req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    _ = try await URLSession.shared.data(for: req)
                }
                inFlight += 1
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Download

    /// Download and decrypt a file. Returns decrypted data.
    public func downloadFile(
        fileId: String,
        folderKey: SymmetricKey
    ) async throws -> Data {
        syncState = .downloading
        activeDownloads += 1
        defer { activeDownloads -= 1 }

        // 1. Fetch and decrypt manifest
        let encryptedManifest = try await apiClient.fetchManifest(fileId: fileId)
        let manifestData = try VaultCrypto.decrypt(encryptedManifest, key: folderKey)
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: manifestData)

        // 2. Download and decrypt chunks in order
        var fileData = Data()
        fileData.reserveCapacity(Int(manifest.totalSize))

        for chunk in manifest.chunks {
            let url = try await apiClient.presignGet(fileId: fileId, chunkHash: chunk.hash)
            let (encryptedChunkData, _) = try await URLSession.shared.data(from: url)

            // Decrypt chunk key
            guard let encryptedKeyData = Data(base64Encoded: chunk.encryptedKeyB64) else {
                throw VaultSyncEngineError.invalidBase64
            }
            let chunkKey = try VaultCrypto.decryptChunkKey(encryptedKeyData, with: folderKey)

            // Decrypt chunk
            let plainChunk = try VaultCrypto.decrypt(encryptedChunkData, key: chunkKey)
            fileData.append(plainChunk)
        }

        syncState = .idle
        return fileData
    }

    // MARK: - Conflict detection

    /// Check if local file conflicts with remote version.
    /// Returns true if conflict exists (local manifestVersion != remote parentVersion).
    public func checkConflict(fileId: String, localVersion: Int, folderKey: SymmetricKey) async throws -> Bool {
        let encryptedManifest = try await apiClient.fetchManifest(fileId: fileId)
        let manifestData = try VaultCrypto.decrypt(encryptedManifest, key: folderKey)
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: manifestData)
        return manifest.parentVersion != localVersion
    }

    /// Create a conflict copy with timestamp suffix
    public func createConflictCopy(fileId: String, originalName: String) -> String {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).prefix(10)
        let nameWithoutExt = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension
        return ext.isEmpty
            ? "\(nameWithoutExt) (conflict \(timestamp))"
            : "\(nameWithoutExt) (conflict \(timestamp)).\(ext)"
    }

    // MARK: - Helpers

    private func encryptFilename(_ name: String, folderKey: SymmetricKey) throws -> String {
        let nameData = Data(name.utf8)
        let encrypted = try VaultCrypto.encrypt(nameData, key: folderKey)
        return encrypted.base64EncodedString()
    }

    public func decryptFilename(_ encB64: String, folderKey: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: encB64) else { return "unknown" }
        let decrypted = try VaultCrypto.decrypt(data, key: folderKey)
        return String(data: decrypted, encoding: .utf8) ?? "unknown"
    }
}

public enum VaultSyncEngineError: Error {
    case invalidBase64
    case decryptionFailed
    case manifestDecodeError
}
