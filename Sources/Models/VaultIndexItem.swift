import Foundation
import SwiftData

@Model
final class VaultIndexItem {
    @Attribute(.unique) var id: UUID
    var parentId: UUID?
    var name: String
    var path: String
    var mime: String
    var sizeBytes: Int
    var createdAt: Date
    var modifiedAt: Date
    var syncedAt: Date?
    var custodyState: String
    var thumbKey: String?
    var originalKey: String?
    var exifKey: String?
    var isDeleted: Bool = false
    var deletedAt: Date?
    var assetIdentifier: String?

    init(
        id: UUID = UUID(),
        parentId: UUID? = nil,
        name: String,
        path: String,
        mime: String,
        sizeBytes: Int,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        syncedAt: Date? = nil,
        custodyState: String = "stored",
        thumbKey: String? = nil,
        originalKey: String? = nil,
        exifKey: String? = nil,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        assetIdentifier: String? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.path = path
        self.mime = mime
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.syncedAt = syncedAt
        self.custodyState = custodyState
        self.thumbKey = thumbKey
        self.originalKey = originalKey
        self.exifKey = exifKey
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.assetIdentifier = assetIdentifier
    }
}
