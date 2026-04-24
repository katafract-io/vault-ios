import Foundation

/// Vault API client — communicates with artemis /v1/* endpoints.
public actor VaultAPIClient {

    private let baseURL: URL
    private var authToken: String?

    public init(baseURL: URL = URL(string: "https://api.katafract.com")!) {
        self.baseURL = baseURL
    }

    public func setAuthToken(_ token: String?) {
        self.authToken = token
    }

    public func hasAuthToken() -> Bool {
        authToken != nil
    }

    // MARK: - Token validation & redemption

    /// POST /v1/token/validate/apple — used after a StoreKit purchase to
    /// exchange a JWS transaction for an opaque server-side token.
    /// Never call from simulator (see feedback_simulator_no_token.md).
    public func validateAppleTransaction(
        jwsTransaction: String,
        transactionID: String,
        originalTransactionID: String,
        productID: String,
        bundleID: String
    ) async throws -> TokenValidationResponse {
        let body = ValidateAppleBody(
            transaction_id: transactionID,
            original_transaction_id: originalTransactionID,
            product_id: productID,
            bundle_id: bundleID,
            jws_transaction: jwsTransaction
        )
        return try await post("/v1/token/validate/apple", body: body, authOverride: nil)
    }

    /// GET /v1/token/info — validates an arbitrary Bearer token and returns
    /// its plan + founder status. Used for the paywall's "redeem existing
    /// token" flow (Stripe subscribers, founders with manually-granted
    /// tokens). Does not mutate server state; safe to call in simulator.
    public func lookupToken(rawToken: String) async throws -> TokenInfoResponse {
        return try await get("/v1/token/info", authOverride: rawToken)
    }

    // MARK: - Founder code redemption

    /// GET /v1/founder/redeem/{code} — preview a founder code before claiming.
    /// Returns label, claimed status, plan, and founder flag. Does not require auth.
    public func previewFounderCode(_ code: String) async throws -> FounderCodePreviewResponse {
        return try await get("/v1/founder/redeem/\(code)", authOverride: nil)
    }

    /// POST /v1/founder/redeem — claim a founder code and receive a server token.
    /// Returns the token + plan details. Does not require auth (code is the credential).
    public func redeemFounderCode(_ code: String, deviceId: String?) async throws -> FounderCodeRedeemResponse {
        let body = FounderCodeRedeemBody(code: code, device_id: deviceId)
        return try await post("/v1/founder/redeem", body: body, authOverride: nil)
    }

    // MARK: - Vault provisioning

    /// POST /v1/vault/init — idempotent. Creates vault_users row on first
    /// call, no-op on subsequent. Requires a valid auth token.
    public func vaultInit() async throws -> VaultInitResponse {
        return try await post("/v1/vault/init", body: EmptyBody(), authOverride: nil)
    }

    /// GET /v1/vault/meta — returns quota + usage. 404 if vault_init hasn't
    /// been called yet for this user.
    public func vaultMeta() async throws -> VaultMetaResponse {
        return try await get("/v1/vault/meta", authOverride: nil)
    }

    // MARK: - Presign

    public func presignPut(fileId: String, chunkHash: String) async throws -> URL {
        let body = PresignBody(file_id: fileId, chunk_hash: chunkHash, operation: "put")
        let response: PresignResponse = try await post("/v1/vault/presign", body: body, authOverride: nil)
        guard let url = URL(string: response.url) else { throw VaultAPIClientError.invalidURL }
        return url
    }

    public func presignGet(fileId: String, chunkHash: String) async throws -> URL {
        let body = PresignBody(file_id: fileId, chunk_hash: chunkHash, operation: "get")
        let response: PresignResponse = try await post("/v1/vault/presign", body: body, authOverride: nil)
        guard let url = URL(string: response.url) else { throw VaultAPIClientError.invalidURL }
        return url
    }

    // MARK: - Manifest

    public func uploadManifest(
        fileId: String,
        encryptedManifest: Data,
        filenameEnc: String,
        parentFolderId: String?,
        sizeBytes: Int64,
        chunkCount: Int,
        chunkHashes: [String]
    ) async throws {
        let body = ManifestUploadBody(
            file_id: fileId,
            manifest_data: encryptedManifest.base64EncodedString(),
            filename_enc: filenameEnc,
            parent_folder_id: parentFolderId,
            size_bytes: sizeBytes,
            chunk_count: chunkCount,
            chunk_hashes: chunkHashes)
        _ = try await post("/v1/vault/manifest", body: body, authOverride: nil) as ManifestResponse
    }

    // MARK: - Trash / restore / purge

    public func listTrashFiles(offset: Int = 0, limit: Int = 1000) async throws -> TrashFilesResponse {
        return try await get("/v1/vault/trash?offset=\(offset)&limit=\(limit)", authOverride: nil)
    }

    public func listTrashFolders(offset: Int = 0, limit: Int = 1000) async throws -> TrashFoldersResponse {
        return try await get("/v1/vault/trash/folders?offset=\(offset)&limit=\(limit)", authOverride: nil)
    }

    public func restoreFile(fileId: String) async throws {
        _ = try await post("/v1/vault/files/\(fileId)/restore", body: EmptyBody(), authOverride: nil) as RestoreResponse
    }

    public func restoreFolder(folderId: String) async throws -> FolderRestoreResponse {
        return try await post("/v1/vault/folders/\(folderId)/restore", body: EmptyBody(), authOverride: nil)
    }

    /// Soft-delete a file to the trash (moves manifest to trash/ prefix,
    /// sets deleted_at). Recoverable via `restoreFile` for 30 days.
    /// Tolerant of 404/410 (orphan files already missing manifest).
    public func softDeleteFile(fileId: String) async throws {
        do {
            _ = try await delete("/v1/vault/files/\(fileId)") as FileDeleteResponse
        } catch let VaultAPIClientError.httpError(status, _) where status == 404 || status == 410 {
            // Manifest already missing (orphan) — treat as success
            return
        }
    }

    /// Permanently delete a trashed file right now (skip the 30-day wait).
    public func purgeFile(fileId: String) async throws {
        _ = try await delete("/v1/vault/files/\(fileId)/purge") as FileDeleteResponse
    }

    /// POST /v1/vault/reconcile — scan vault for orphaned files.
    /// Returns list of findings with status (ok | orphan_no_manifest | orphan_no_chunks).
    /// If purge=true, permanently deletes orphans.
    public func reconcileVault(purge: Bool = false) async throws -> VaultReconcileResponse {
        let queryParam = purge ? "?purge=true" : "?purge=false"
        return try await post("/v1/vault/reconcile\(queryParam)", body: EmptyBody(), authOverride: nil)
    }

    // MARK: - Folders

    public func createFolder(folderId: String, parentFolderId: String?, nameEnc: String) async throws -> FolderRecord {
        let body = FolderCreateBody(
            folder_id: folderId, parent_folder_id: parentFolderId, name_enc: nameEnc)
        return try await post("/v1/vault/folders", body: body, authOverride: nil)
    }

    public func listFolders() async throws -> FolderListResponse {
        return try await get("/v1/vault/folders", authOverride: nil)
    }

    public func renameFolder(folderId: String, nameEnc: String) async throws {
        let body = FolderRenameBody(name_enc: nameEnc)
        _ = try await patch("/v1/vault/folders/\(folderId)", body: body) as FolderRenameResponse
    }

    public func renameFile(fileId: String, filenameEnc: String) async throws {
        let body = FileRenameBody(filename_enc: filenameEnc)
        _ = try await patch("/v1/vault/files/\(fileId)", body: body) as FileRenameResponse
    }

    public func moveFile(fileId: String, newParentFolderId: String?) async throws {
        let body = MoveBody(parent_folder_id: newParentFolderId)
        _ = try await patch("/v1/vault/files/\(fileId)/parent", body: body) as MoveResponse
    }

    public func moveFolder(folderId: String, newParentFolderId: String?) async throws {
        let body = MoveBody(parent_folder_id: newParentFolderId)
        _ = try await patch("/v1/vault/folders/\(folderId)/parent", body: body) as MoveResponse
    }

    public func deleteFolder(folderId: String) async throws {
        _ = try await delete("/v1/vault/folders/\(folderId)") as FolderDeleteResponse
    }

    // MARK: - Tree

    public func listFiles(offset: Int = 0, limit: Int = 1000) async throws -> TreeListResponse {
        return try await get("/v1/vault/tree?offset=\(offset)&limit=\(limit)", authOverride: nil)
    }

    /// List recently accessed files (ordered by last access time).
    public func listRecentFiles(limit: Int = 20) async throws -> TreeListResponse {
        return try await get("/v1/vault/recents?limit=\(limit)", authOverride: nil)
    }

    public func fetchManifest(fileId: String) async throws -> Data {
        let response: ManifestResponse = try await get("/v1/vault/manifest/\(fileId)", authOverride: nil)
        guard let data = Data(base64Encoded: response.manifest_data) else {
            throw VaultAPIClientError.invalidBase64
        }
        return data
    }

    // MARK: - Keys

    public func storeKey(keyId: String, encryptedKeyBlob: Data) async throws {
        let body = KeyStoreBody(
            key_id: keyId, key_blob_b64: encryptedKeyBlob.base64EncodedString())
        _ = try await post("/v1/vault/keys", body: body, authOverride: nil) as KeyResponse
    }

    public func fetchKey(keyId: String) async throws -> Data {
        let response: KeyResponse = try await get("/v1/vault/keys/\(keyId)", authOverride: nil)
        guard let data = Data(base64Encoded: response.keyBlobB64) else {
            throw VaultAPIClientError.invalidBase64
        }
        return data
    }

    // MARK: - HTTP helpers

    /// `authOverride` lets the caller pass a one-shot Bearer (e.g. for token
    /// redemption) instead of using the stored `authToken`.
    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        authOverride: String?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw VaultAPIClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = authOverride ?? authToken {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfHTTPError(data: data, response: response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func patch<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw VaultAPIClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfHTTPError(data: data, response: response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func delete<Response: Decodable>(
        _ path: String
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw VaultAPIClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfHTTPError(data: data, response: response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func get<Response: Decodable>(
        _ path: String,
        authOverride: String?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw VaultAPIClientError.invalidURL
        }
        var request = URLRequest(url: url)
        if let bearer = authOverride ?? authToken {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.throwIfHTTPError(data: data, response: response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func throwIfHTTPError(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VaultAPIClientError.httpError(status: 0, body: "")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VaultAPIClientError.httpError(status: http.statusCode, body: body)
        }
    }

    // MARK: - Response types (public for callers that need to inspect fields)

    private struct EmptyBody: Encodable {}

    private struct ValidateAppleBody: Encodable {
        let transaction_id: String
        let original_transaction_id: String
        let product_id: String
        let bundle_id: String
        let jws_transaction: String
    }

    private struct PresignBody: Encodable {
        let file_id: String
        let chunk_hash: String
        let operation: String
    }

    private struct ManifestUploadBody: Encodable {
        let file_id: String
        let manifest_data: String  // base64 encrypted manifest blob
        let filename_enc: String
        let parent_folder_id: String?
        let size_bytes: Int64
        let chunk_count: Int
        let chunk_hashes: [String]
    }

    private struct RestoreResponse: Decodable {
        let file_id: String
        let restored_at: Int
    }

    private struct FileDeleteResponse: Decodable {
        let file_id: String
    }

    private struct FolderCreateBody: Encodable {
        let folder_id: String
        let parent_folder_id: String?
        let name_enc: String
    }

    private struct FolderRenameBody: Encodable {
        let name_enc: String
    }

    private struct FolderRenameResponse: Decodable {
        let folder_id: String
        let modified_at: Int
    }

    private struct FileRenameBody: Encodable {
        let filename_enc: String
    }

    private struct FileRenameResponse: Decodable {
        let file_id: String
        let modified_at: Int
    }

    private struct MoveBody: Encodable {
        let parent_folder_id: String?
    }

    private struct MoveResponse: Decodable {
        let file_id: String?
        let folder_id: String?
        let parent_folder_id: String?
        let modified_at: Int?
    }

    private struct FolderDeleteResponse: Decodable {
        let folder_id: String
        let deleted_at: Int
    }

    private struct KeyStoreBody: Encodable {
        let key_id: String
        let key_blob_b64: String
    }

    private struct PresignResponse: Decodable {
        let url: String
    }

    private struct ManifestResponse: Decodable {
        let file_id: String
        let manifest_data: String
        let size_bytes: Int64
        let chunk_count: Int
        let created_at: Int
        let modified_at: Int
        let version: Int
    }

    private struct KeyResponse: Decodable {
        let keyBlobB64: String
    }
}

// MARK: - Public response types

public struct TokenValidationResponse: Decodable, Sendable {
    public let token: String
    public let expires_at: Int
    public let plan: String
    public let is_founder: Bool
    public let is_admin: Bool
}

public struct TokenInfoResponse: Decodable, Sendable {
    public let valid: Bool
    public let plan: String?
    public let is_founder: Bool
    public let is_admin: Bool
    public let expires_at: Int?
    public let max_peers: Int?

    /// Plans that entitle the token holder to Vaultyx Sovereign storage.
    public static let sovereignPlans: Set<String> =
        ["sovereign", "sovereign_annual"]

    /// True if this token unlocks Vaultyx — either a Sovereign subscriber or
    /// a founder grant. Admin alone does not unlock (admin is orthogonal).
    public var unlocksVaultyx: Bool {
        guard valid else { return false }
        if is_founder { return true }
        if let plan, TokenInfoResponse.sovereignPlans.contains(plan) { return true }
        return false
    }
}

public struct VaultInitResponse: Decodable, Sendable {
    public let user_id: String
    public let created: Bool
    public let quota_bytes: Int64
    public let storage_tier: String
}

public struct VaultMetaResponse: Decodable, Sendable {
    public let user_id: String
    public let usage_bytes: Int64
    public let quota_bytes: Int64
    public let quota_exceeded: Bool
}

public struct FolderRecord: Decodable, Sendable {
    public let folder_id: String
    public let parent_folder_id: String?
    public let name_enc: String
    public let created_at: Int
    public let modified_at: Int
}

public struct FolderListResponse: Decodable, Sendable {
    public let folders: [FolderRecord]
    public let count: Int
}

public struct FileRecord: Decodable, Sendable {
    public let file_id: String
    public let parent_folder_id: String?
    public let filename_enc: String
    public let size_bytes: Int64
    public let chunk_count: Int
    public let created_at: Int
    public let modified_at: Int
    public let version: Int
}

public struct TreeListResponse: Decodable, Sendable {
    public let files: [FileRecord]
    public let count: Int
    public let offset: Int
    public let limit: Int
}

public struct TrashFileRecord: Decodable, Sendable, Identifiable {
    public let file_id: String
    public let filename_enc: String
    public let size_bytes: Int64
    public let deleted_at: Int
    public let expires_at: Int
    public var id: String { file_id }
}

public struct TrashFilesResponse: Decodable, Sendable {
    public let files: [TrashFileRecord]
    public let count: Int
    public let offset: Int
    public let limit: Int
}

public struct TrashFolderRecord: Decodable, Sendable, Identifiable {
    public let folder_id: String
    public let parent_folder_id: String?
    public let name_enc: String
    public let deleted_at: Int
    public let expires_at: Int
    public var id: String { folder_id }
}

public struct TrashFoldersResponse: Decodable, Sendable {
    public let folders: [TrashFolderRecord]
    public let count: Int
    public let offset: Int
    public let limit: Int
}

public struct FolderRestoreResponse: Decodable, Sendable {
    public let folder_id: String
    public let restored_at: Int
    public let restored_folder_count: Int
    public let restored_file_count: Int
}

public struct VaultReconcileResponse: Decodable, Sendable {
    public let findings: [VaultReconcileFinding]
    public let total_files: Int
    public let orphan_count: Int
    public let purged_count: Int
    public let purge_mode: Bool
}

public struct VaultReconcileFinding: Decodable, Sendable {
    public let file_id: String
    public let filename_enc: String
    public let size_bytes: Int64
    public let status: String  // "ok" | "orphan_no_manifest" | "orphan_no_chunks" | "unknown_error"
    public let purged: Bool
}

// MARK: - Founder code response types

public struct FounderCodePreviewResponse: Decodable, Sendable {
    public let label: String
    public let claimed: Bool
    public let plan: String
    public let is_founder: Bool
}

public struct FounderCodeRedeemResponse: Decodable, Sendable {
    public let token: String
    public let plan: String
    public let is_founder: Bool
    public let expires_at: Int?
    public let label: String
}

// MARK: - Error types

public enum VaultAPIClientError: Error, CustomStringConvertible {
    case invalidURL
    case invalidBase64
    case httpError(status: Int, body: String)
    case decodingError

    public var description: String {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidBase64: return "Invalid base64 payload"
        case .httpError(let s, let b): return "HTTP \(s): \(b.prefix(200))"
        case .decodingError: return "JSON decoding error"
        }
    }
}

// MARK: - Private body types

private struct FounderCodeRedeemBody: Encodable {
    let code: String
    let device_id: String?
}
