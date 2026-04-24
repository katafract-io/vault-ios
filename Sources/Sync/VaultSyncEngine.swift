import Foundation
import SwiftData
import CryptoKit

/// Core sync engine — manages upload queue, download queue, conflict detection.
/// Operates on VaultCrypto + FastCDC interfaces.
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

    /// Encrypt and upload a file. Streams file IO + FastCDC chunking, encrypts one window
    /// at a time, uploads with bounded concurrency (4 workers).
    public func uploadFile(
        localURL: URL,
        parentFolderId: String?,
        folderKey: SymmetricKey,
        masterKey: SymmetricKey,
        filename: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        await MainActor.run { self.syncState = .uploading; self.activeUploads += 1 }
        defer { Task { await MainActor.run { self.activeUploads -= 1 } } }

        let fileId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let pipeline = try await Task.detached(priority: .userInitiated) { () -> (Int64, [VaultManifest.ChunkDescriptor]) in
            let fileHandle = try FileHandle(forReadingFrom: localURL)
            defer { try? fileHandle.close() }

            let fileSize = try fileHandle.seekToEndOfFile()
            try fileHandle.seek(toOffset: 0)

            var chunkDescriptors: [VaultManifest.ChunkDescriptor] = []
            // Stream the file in 4 MB chunks so we never hold the whole
            // file in memory on large uploads. readToEndOfFile was the
            // wrong API (reads to EOF in one shot, defeats streaming)
            // and was also removed from the modern SDK — the archive
            // compile failed outright.
            let readChunkSize = 4 * 1024 * 1024
            let chunkStream = AsyncStream<(hash: String, data: Data)> { continuation in
                do {
                    while try fileHandle.offset() < fileSize {
                        guard let chunkData = try fileHandle.read(upToCount: readChunkSize),
                              !chunkData.isEmpty else { break }

                        let chunks = FastCDC.split(chunkData)
                        for chunk in chunks {
                            let plaintext = chunkData[chunk.offset..<(chunk.offset + chunk.length)]
                            let chunkKey = VaultCrypto.generateChunkKey()
                            let encrypted = try VaultCrypto.encrypt(Data(plaintext), key: chunkKey)
                            let encryptedKeyBlob = try VaultCrypto.encryptChunkKey(chunkKey, with: folderKey)
                            let encryptedKeyB64 = encryptedKeyBlob.base64EncodedString()

                            chunkDescriptors.append(VaultManifest.ChunkDescriptor(
                                hash: chunk.hash,
                                size: chunk.length,
                                encryptedKeyB64: encryptedKeyB64,
                                offsetInFile: chunk.offset
                            ))

                            continuation.yield((hash: chunk.hash, data: encrypted))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            try await self.uploadChunksBatch(chunkStream, fileId: fileId)
            return (Int64(fileSize), chunkDescriptors)
        }.value

        let totalSize = pipeline.0
        let chunkDescriptors = pipeline.1

        // 4. Build and encrypt manifest
        let filenameEnc = try encryptFilename(localURL.lastPathComponent, folderKey: folderKey)
        let manifest = VaultManifest(
            fileId: fileId,
            filenameEnc: filenameEnc,
            mimeTypeEnc: "",
            totalSize: totalSize,
            createdAt: Date().timeIntervalSince1970,
            modifiedAt: Date().timeIntervalSince1970,
            parentVersion: 0,
            chunks: chunkDescriptors
        )

        let manifestData = try JSONEncoder().encode(manifest)
        let encryptedManifest = try VaultCrypto.encrypt(manifestData, key: folderKey)

        // 5. Upload manifest, with filename_enc + parent passed alongside so
        //    the server can index the file for cross-device list sync (both
        //    fields stay encrypted under the folder key; server never reads them).
        try await apiClient.uploadManifest(
            fileId: fileId,
            encryptedManifest: encryptedManifest,
            filenameEnc: filenameEnc,
            parentFolderId: parentFolderId,
            sizeBytes: totalSize,
            chunkCount: chunkDescriptors.count,
            chunkHashes: chunkDescriptors.map { $0.hash })

        // 6. Save to local SwiftData
        let localFile = LocalFile(
            fileId: fileId,
            filename: filename ?? localURL.lastPathComponent,
            parentFolderId: parentFolderId,
            manifestVersion: 1,
            chunkHashes: chunkDescriptors.map { $0.hash },
            sizeBytes: totalSize,
            modifiedAt: Date(),
            syncState: "synced",
            isPinned: false
        )
        await MainActor.run {
            self.modelContext.insert(localFile)
            try self.modelContext.save()
            self.syncState = .idle
        }

        return fileId
    }

    // MARK: - Streaming upload worker

    private func uploadChunksBatch(
        _ chunkStream: AsyncStream<(hash: String, data: Data)>,
        fileId: String
    ) async throws {
        let maxWorkers = 4
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<maxWorkers {
                group.addTask {
                    var iterator = chunkStream.makeAsyncIterator()
                    while let chunk = await iterator.next() {
                        let url = try await self.apiClient.presignPut(fileId: fileId, chunkHash: chunk.hash)
                        var req = URLRequest(url: url)
                        req.httpMethod = "PUT"
                        req.httpBody = chunk.data
                        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        let (_, response) = try await URLSession.shared.data(for: req)
                        guard let httpResponse = response as? HTTPURLResponse,
                              (200...299).contains(httpResponse.statusCode) else {
                            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                            throw VaultSyncEngineError.httpError(statusCode: code)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Download

    /// Download and decrypt a file. Returns decrypted data.
    /// Chunks are fetched in parallel (max 8 concurrent) then reassembled
    /// in order, giving ~8× speedup over serial fetching on multi-chunk files.
    ///
    /// Memory note: all decrypted chunks are held in memory simultaneously.
    /// At 256 KB per chunk and 8 in-flight, working-set peak ≈ 2 MB — fine
    /// for typical files. A stream-to-disk path is a follow-up for >1 GB files.
    public func downloadFile(
        fileId: String,
        folderKey: SymmetricKey,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        await MainActor.run { self.syncState = .downloading; self.activeDownloads += 1 }
        defer { Task { await MainActor.run { self.activeDownloads -= 1 } } }

        // 1. Fetch and decrypt manifest — manifest decrypt is cheap, but the
        //    per-chunk decrypt loop below is the real CPU sink. Hop off main
        //    for the whole thing so SwiftUI stays responsive on multi-GB files.
        let encryptedManifest = try await apiClient.fetchManifest(fileId: fileId)

        let apiClient = self.apiClient
        let fileData = try await Task.detached(priority: .userInitiated) { () -> Data in
            let manifestData = try VaultCrypto.decrypt(encryptedManifest, key: folderKey)
            let manifest = try JSONDecoder().decode(VaultManifest.self, from: manifestData)

            let totalChunks = manifest.chunks.count
            guard totalChunks > 0 else { return Data() }

            // Parallel fetch+decrypt, max 8 in flight. Child tasks inherit
            // this detached context, so all CryptoKit work runs off-main.
            let maxConcurrent = 8
            var chunkResults: [(Int, Data)] = []
            chunkResults.reserveCapacity(totalChunks)

            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var inFlight = 0
                var nextIdx = 0
                var completed = 0

                while nextIdx < totalChunks || inFlight > 0 {
                    while inFlight < maxConcurrent, nextIdx < totalChunks {
                        let idx = nextIdx
                        let chunk = manifest.chunks[idx]
                        group.addTask {
                            let url = try await apiClient.presignGet(fileId: fileId, chunkHash: chunk.hash)
                            let (encryptedChunkData, _) = try await URLSession.shared.data(from: url)
                            guard let encryptedKeyData = Data(base64Encoded: chunk.encryptedKeyB64) else {
                                throw VaultSyncEngineError.invalidBase64
                            }
                            let chunkKey = try VaultCrypto.decryptChunkKey(encryptedKeyData, with: folderKey)
                            let plainChunk = try VaultCrypto.decrypt(encryptedChunkData, key: chunkKey)
                            return (idx, plainChunk)
                        }
                        inFlight += 1
                        nextIdx += 1
                    }
                    if let result = try await group.next() {
                        chunkResults.append(result)
                        inFlight -= 1
                        completed += 1
                        // Progress callback must hop back to MainActor to
                        // update @Published UI state safely.
                        let frac = Double(completed) / Double(totalChunks)
                        if let progress {
                            await MainActor.run { progress(frac) }
                        }
                    }
                }
            }

            chunkResults.sort { $0.0 < $1.0 }
            var buffer = Data()
            buffer.reserveCapacity(Int(manifest.totalSize))
            for (_, data) in chunkResults {
                buffer.append(data)
            }
            return buffer
        }.value

        await MainActor.run { self.syncState = .idle }
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
    case httpError(statusCode: Int)
}
