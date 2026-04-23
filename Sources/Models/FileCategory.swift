import Foundation

enum FileCategory: String, CaseIterable, Equatable {
    case all = "All"
    case photos = "Photos"
    case documents = "Documents"
    case videos = "Videos"
    case audio = "Audio"
    case other = "Other"

    var label: String {
        self.rawValue
    }

    static func category(forFilename filename: String) -> FileCategory {
        let ext = (filename as NSString).pathExtension.lowercased()

        let photoExts = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "raw", "dng", "tiff"]
        let docExts = ["pdf", "doc", "docx", "txt", "md", "rtf", "pages", "key", "ppt", "pptx", "xls", "xlsx", "csv", "numbers"]
        let videoExts = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "hevc"]
        let audioExts = ["mp3", "m4a", "wav", "aiff", "flac", "aac", "ogg", "opus"]

        if photoExts.contains(ext) {
            return .photos
        } else if docExts.contains(ext) {
            return .documents
        } else if videoExts.contains(ext) {
            return .videos
        } else if audioExts.contains(ext) {
            return .audio
        } else {
            return .other
        }
    }

    func matches(filename: String) -> Bool {
        if self == .all {
            return true
        }
        return FileCategory.category(forFilename: filename) == self
    }

    var iconName: String {
        switch self {
        case .all:
            return "square.grid.2x2"
        case .photos:
            return "photo.fill"
        case .documents:
            return "doc.fill"
        case .videos:
            return "play.rectangle.fill"
        case .audio:
            return "music.note"
        case .other:
            return "doc.questionmark"
        }
    }
}
