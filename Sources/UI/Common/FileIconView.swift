import SwiftUI
import KatafractStyle

/// Monochromatic sapphire file-type tile — 40×40pt rounded-10 with subtle
/// fill + hairline stroke. Replaces the previous rainbow-iconography look
/// (Drive-esque) with quiet, premium Katafract-family chrome.
struct FileIconView: View {
    let item: VaultFileItem

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.kataSapphire.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.kataSapphire.opacity(0.2), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.kataSapphire)
            )
    }

    var iconName: String {
        if item.isFolder { return "folder.fill" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.text.fill"
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
}

/// Compact sync-state badge used in the file row trailing region.
///
///   - `.synced`         → small gold `lock.shield.fill` (the "quietly expensive" flex)
///   - `.uploading(x)`   → sapphire-tinted capsule with progress percent
///   - `.downloading(x)` → same shape, different glyph
///   - `.conflict`       → amber warning triangle
///   - `.offline`        → sapphire pin glyph (not orange — we're not Google Drive)
///   - `.pendingUpload`  → cyan "Queued" capsule (waiting for drain worker)
///   - `.partial`        → cyan "Resuming" capsule (some chunks ACK'd, more pending)
struct SyncStatusBadge: View {
    let state: VaultFileItem.SyncStateDisplay

    var body: some View {
        switch state {
        case .synced:
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.kataGold.opacity(0.85))
                .accessibilityLabel("Encrypted, synced")
        case .uploading(let progress):
            UploadingPill(progress: progress, mode: .uploading)
        case .downloading(let progress):
            UploadingPill(progress: progress, mode: .downloading)
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
                .accessibilityLabel("Sync conflict")
        case .offline:
            Image(systemName: "pin.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.kataSapphire.opacity(0.85))
                .accessibilityLabel("Kept offline")
        case .pendingUpload:
            QueuedPill(label: "Queued")
        case .partial:
            QueuedPill(label: "Resuming")
        }
    }
}

/// Cyan pill badge for files in the persist-first upload queue.
/// Distinct from the `UploadingPill` (which tracks live progress) — this
/// signals "accepted, will upload when connectivity allows."
struct QueuedPill: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.cyan.opacity(0.9))
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.cyan.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.cyan.opacity(0.12)))
        .overlay(Capsule().stroke(Color.cyan.opacity(0.35), lineWidth: 0.5))
        .accessibilityLabel(label == "Queued"
            ? "Queued for upload" : "Upload resuming")
    }
}

/// The in-progress capsule. `Sealed` is a terminal celebration state that
/// plays briefly after an uploading badge completes — fires a success haptic
/// and swaps to gold shield-check. Callers own the "uploading → sealed"
/// transition by watching the underlying sync state.
struct UploadingPill: View {
    enum Mode { case uploading, downloading, sealed }

    let progress: Double
    let mode: Mode

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(glyphColor)
                .symbolEffect(.pulse, options: .repeating, value: mode)

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(backgroundColor)
        )
        .overlay(
            Capsule().stroke(strokeColor, lineWidth: 0.5)
        )
    }

    private var glyph: String {
        switch mode {
        case .uploading:   return "arrow.up.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .sealed:      return "checkmark.shield.fill"
        }
    }

    private var label: String {
        switch mode {
        case .uploading, .downloading:
            return "\(Int(progress * 100))%"
        case .sealed:
            return "Sealed"
        }
    }

    private var glyphColor: Color {
        mode == .sealed ? Color.kataGold : Color.kataSapphire
    }

    private var textColor: Color {
        mode == .sealed ? Color.kataGold.opacity(0.9) : Color.kataSapphire.opacity(0.85)
    }

    private var backgroundColor: Color {
        mode == .sealed ? Color.kataGold.opacity(0.15) : Color.kataSapphire.opacity(0.18)
    }

    private var strokeColor: Color {
        mode == .sealed ? Color.kataGold.opacity(0.4) : Color.kataSapphire.opacity(0.4)
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
        .frame(width: 40, height: 40)

        FileIconView(item: VaultFileItem(
            id: "2", name: "Photos", isFolder: true,
            sizeBytes: 0, modifiedAt: Date(), syncState: .synced, isPinned: false
        ))
        .frame(width: 40, height: 40)

        SyncStatusBadge(state: .synced)
        SyncStatusBadge(state: .uploading(0.42))
        SyncStatusBadge(state: .downloading(0.78))
        UploadingPill(progress: 1, mode: .sealed)
        SyncStatusBadge(state: .conflict)
        SyncStatusBadge(state: .offline)
    }
    .padding()
}
