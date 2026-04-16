import Foundation

/// Vault API client — communicates with artemis /v1/vault/* endpoints
public actor VaultAPIClient {

    private let baseURL: URL
    private var authToken: String?

    public init(baseURL: URL = URL(string: "https://api.katafract.com")!) {
        self.baseURL = baseURL
    }

    public func setAuthToken(_ token: String) {
        self.authToken = token
    }

    // MARK: - Presign

    public func presignPut(fileId: String, chunkHash: String) async throws -> URL {
        let body: [String: String] = [
            "file_id": fileId,
            "chunk_hash": chunkHash,
            "operation": "put"
        ]
        let response: PresignResponse = try await post("/v1/vault/presign", body: body)
        guard let url = URL(string: response.url) else {
            throw VaultAPIClientError.invalidURL
        }
        return url
    }

    public func presignGet(fileId: String, chunkHash: String) async throws -> URL {
        let body: [String: String] = [
            "file_id": fileId,
            "chunk_hash": chunkHash,
            "operation": "get"
        ]
        let response: PresignResponse = try await post("/v1/vault/presign", body: body)
        guard let url = URL(string: response.url) else {
            throw VaultAPIClientError.invalidURL
        }
        return url
    }

    // MARK: - Manifest

    public func uploadManifest(fileId: String, encryptedManifest: Data) async throws {
        let body: [String: String] = [
            "file_id": fileId,
            "manifest_b64": encryptedManifest.base64EncodedString()
        ]
        _ = try await post("/v1/vault/manifest", body: body) as ManifestResponse
    }

    public func fetchManifest(fileId: String) async throws -> Data {
        let response: ManifestResponse = try await get("/v1/vault/manifest/\(fileId)")
        guard let data = Data(base64Encoded: response.manifestB64) else {
            throw VaultAPIClientError.invalidBase64
        }
        return data
    }

    // MARK: - Keys

    public func storeKey(keyId: String, encryptedKeyBlob: Data) async throws {
        let body: [String: String] = [
            "key_id": keyId,
            "key_blob_b64": encryptedKeyBlob.base64EncodedString()
        ]
        _ = try await post("/v1/vault/keys", body: body) as KeyResponse
    }

    public func fetchKey(keyId: String) async throws -> Data {
        let response: KeyResponse = try await get("/v1/vault/keys/\(keyId)")
        guard let data = Data(base64Encoded: response.keyBlobB64) else {
            throw VaultAPIClientError.invalidBase64
        }
        return data
    }

    // MARK: - Helpers

    private func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw VaultAPIClientError.httpError
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw VaultAPIClientError.httpError
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // Response types
    private struct PresignResponse: Decodable {
        let url: String
    }

    private struct ManifestResponse: Decodable {
        let manifestB64: String
    }

    private struct KeyResponse: Decodable {
        let keyBlobB64: String
    }
}

public enum VaultAPIClientError: Error {
    case invalidURL
    case invalidBase64
    case httpError
    case decodingError
}
