import ActivityKit
import Foundation

public struct VaultyxUploadAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public enum Stage: String, Codable, Sendable {
            case queued, uploading, sealing, sealed, failed
        }

        public var stage: Stage
        public var bytesUploaded: Int64
        public var totalBytes: Int64
        public var filesRemaining: Int
        /// Always empty in the happy path (zero-knowledge: server never sees
        /// plaintext names). Display "Encrypted file" when empty.
        public var currentFilename: String

        public init(
            stage: Stage,
            bytesUploaded: Int64,
            totalBytes: Int64,
            filesRemaining: Int,
            currentFilename: String = ""
        ) {
            self.stage = stage
            self.bytesUploaded = bytesUploaded
            self.totalBytes = totalBytes
            self.filesRemaining = filesRemaining
            self.currentFilename = currentFilename
        }
    }

    public let batchId: String
    public let batchStartedAt: Date
    public let totalFiles: Int

    public init(batchId: String, batchStartedAt: Date, totalFiles: Int) {
        self.batchId = batchId
        self.batchStartedAt = batchStartedAt
        self.totalFiles = totalFiles
    }
}
