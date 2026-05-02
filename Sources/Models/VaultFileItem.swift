import SwiftUI

struct VaultFileItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isFolder: Bool
    let sizeBytes: Int64
    let modifiedAt: Date
    let parentFolderId: String?
    let syncState: SyncStateDisplay
    let isPinned: Bool
    var thumbnailImage: UIImage?

    init(
        id: String,
        name: String,
        isFolder: Bool,
        sizeBytes: Int64,
        modifiedAt: Date,
        parentFolderId: String? = nil,
        syncState: SyncStateDisplay,
        isPinned: Bool,
        thumbnailImage: UIImage? = nil
    ) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.parentFolderId = parentFolderId
        self.syncState = syncState
        self.isPinned = isPinned
        self.thumbnailImage = thumbnailImage
    }

    enum SyncStateDisplay: Equatable {
        case synced
        case uploading(Double)
        case downloading(Double)
        case conflict
        case offline
        /// Queued for background upload — not yet started.
        case pendingUpload
        /// Some chunks confirmed, more still queued (resumed across launch).
        case partial
    }

    var subtitle: String {
        if isFolder { return "Folder" }
        return "\(formattedSize) · \(formattedDate)"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var formattedDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: modifiedAt, relativeTo: Date())
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: VaultFileItem, rhs: VaultFileItem) -> Bool {
        lhs.id == rhs.id
    }
}
