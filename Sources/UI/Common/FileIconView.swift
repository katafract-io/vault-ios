import SwiftUI

struct FileIconView: View {
    let item: VaultFileItem

    var body: some View {
        Image(systemName: iconName)
            .font(.title2)
            .foregroundStyle(iconColor)
    }

    var iconName: String {
        if item.isFolder { return "folder.fill" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo.fill"
        case "mp4", "mov", "m4v": return "video.fill"
        case "mp3", "m4a", "wav", "aac": return "music.note"
        case "zip", "tar", "gz": return "archivebox.fill"
        case "doc", "docx": return "doc.richtext.fill"
        case "xls", "xlsx": return "tablecells.fill"
        case "txt", "md": return "doc.text.fill"
        default: return "doc.fill"
        }
    }

    var iconColor: Color {
        if item.isFolder { return .blue }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return .red
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return .purple
        case "mp4", "mov": return .orange
        case "mp3", "m4a", "wav": return .green
        case "doc", "docx": return .blue
        case "xls", "xlsx": return .green
        default: return .gray
        }
    }
}

struct SyncStatusBadge: View {
    let state: VaultFileItem.SyncStateDisplay

    var body: some View {
        switch state {
        case .synced:
            EmptyView()
        case .uploading(let progress):
            CircularProgressView(progress: progress, color: .blue)
                .frame(width: 16, height: 16)
        case .downloading(let progress):
            CircularProgressView(progress: progress, color: .green)
                .frame(width: 16, height: 16)
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
        case .offline:
            Image(systemName: "pin.fill")
                .foregroundStyle(.orange)
                .font(.caption2)
        }
    }
}

struct CircularProgressView: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        FileIconView(item: VaultFileItem(
            id: "1", name: "document.pdf", isFolder: false,
            sizeBytes: 1000, modifiedAt: Date(), syncState: .synced, isPinned: false
        ))
        FileIconView(item: VaultFileItem(
            id: "2", name: "Photos", isFolder: true,
            sizeBytes: 0, modifiedAt: Date(), syncState: .synced, isPinned: false
        ))
        SyncStatusBadge(state: .uploading(0.5))
        SyncStatusBadge(state: .conflict)
        SyncStatusBadge(state: .offline)
    }
}
