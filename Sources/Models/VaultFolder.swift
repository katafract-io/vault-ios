import Foundation
import SwiftData

/// Client-side cache of a server-side `vault_folders` row.
///
/// `name` is the decrypted plaintext folder name; the encrypted blob lives
/// server-side under `name_enc`. We cache the plaintext locally so the
/// browser renders instantly without re-decrypting on every render.
@Model final class VaultFolder {
    @Attribute(.unique) var folderId: String
    var parentFolderId: String?
    var name: String
    var createdAt: Date
    var modifiedAt: Date

    init(folderId: String,
         parentFolderId: String? = nil,
         name: String,
         createdAt: Date = Date(),
         modifiedAt: Date = Date()) {
        self.folderId = folderId
        self.parentFolderId = parentFolderId
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
