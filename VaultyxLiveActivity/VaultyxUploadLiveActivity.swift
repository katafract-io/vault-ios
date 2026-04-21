import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Palette helpers (inlined — no KatafractStyle dep in widget target)

private extension Color {
    static let kataMidnight  = Color(red: 0.05, green: 0.06, blue: 0.12)
    static let kataSapphire  = Color(red: 0.09, green: 0.22, blue: 0.62)
    static let kataIce       = Color(red: 0.88, green: 0.92, blue: 0.98)
    static let kataGold      = Color(red: 0.76, green: 0.58, blue: 0.20)
    static let kataChampagne = Color(red: 0.94, green: 0.84, blue: 0.60)
    /// Used only for the "failed" hairline break — not red, not orange.
    static let kataFailCrimson = Color(red: 0.65, green: 0.08, blue: 0.12)
}

// MARK: - Byte formatting

private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB]
    formatter.countStyle = .binary
    formatter.allowsNonnumericFormatting = false
    let result = formatter.string(fromByteCount: bytes)
    return result
}

private func progressFraction(_ state: VaultyxUploadAttributes.ContentState) -> Double {
    guard state.totalBytes > 0 else { return 0 }
    return min(1.0, Double(state.bytesUploaded) / Double(state.totalBytes))
}

private func stageLabel(_ stage: VaultyxUploadAttributes.ContentState.Stage) -> String {
    switch stage {
    case .queued:    return "Queued for the vault"
    case .uploading: return "Sending to the vault"
    case .sealing:   return "Sealing…"
    case .sealed:    return "Inside the Enclave."
    case .failed:    return "Couldn't seal."
    }
}

// MARK: - Seal Ring (reusable across all DI views)

/// A circular progress ring that uses a gold hairline while uploading/sealing,
/// transitions to a solid gold fill when sealed, and shows a crimson gap at
/// 12 o'clock on failure. Inner fill is kataSapphire.
private struct SealRing: View {
    let stage: VaultyxUploadAttributes.ContentState.Stage
    let progress: Double
    let size: CGFloat

    private var lineWidth: CGFloat { max(1.0, size * 0.04) }

    var body: some View {
        ZStack {
            // Inner sapphire core
            Circle()
                .fill(Color.kataSapphire)
                .frame(width: size - lineWidth * 2, height: size - lineWidth * 2)

            // Track ring (always present)
            Circle()
                .stroke(Color.kataGold.opacity(0.25), lineWidth: lineWidth)
                .frame(width: size, height: size)

            // Progress arc / sealed fill / failure indicator
            switch stage {
            case .sealed:
                // Solid gold outer ring when sealed
                Circle()
                    .stroke(Color.kataGold, lineWidth: lineWidth)
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .fill(Color.kataGold.opacity(0.12))
                    )
            case .failed:
                // Crimson gap arc at 12-o'clock break — draws most of the ring
                // except a small notch gap at the top
                Circle()
                    .trim(from: 0.05, to: 0.95)
                    .stroke(Color.kataFailCrimson, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size, height: size)
            default:
                // Standard progress hairline
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(Color.kataGold, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size, height: size)
                    .animation(.linear(duration: 0.3), value: progress)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - LiveActivity Widget

struct VaultyxUploadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VaultyxUploadAttributes.self) { context in
            // Lock Screen / banner view
            LockScreenView(context: context)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.kataMidnight)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view
                DynamicIslandExpandedRegion(.leading) {
                    SealRing(
                        stage: context.state.stage,
                        progress: progressFraction(context.state),
                        size: 32
                    )
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingLabel(state: context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    HairlineProgressBar(progress: progressFraction(context.state))
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    FilesRemainingLabel(state: context.state)
                        .padding(.bottom, 4)
                }
            } compactLeading: {
                // Compact — leading: seal icon
                SealRing(
                    stage: context.state.stage,
                    progress: progressFraction(context.state),
                    size: 18
                )
                .padding(.leading, 2)
            } compactTrailing: {
                // Compact — trailing: percent or "Sealed."
                CompactTrailingLabel(state: context.state)
                    .padding(.trailing, 2)
            } minimal: {
                // Minimal: just the seal at smallest size
                SealRing(
                    stage: context.state.stage,
                    progress: progressFraction(context.state),
                    size: 16
                )
            }
        }
    }
}

// MARK: - Lock Screen / Banner view

private struct LockScreenView: View {
    let context: ActivityViewContext<VaultyxUploadAttributes>

    private var state: VaultyxUploadAttributes.ContentState { context.state }
    private var progress: Double { progressFraction(state) }

    var body: some View {
        HStack(spacing: 14) {
            SealRing(stage: state.stage, progress: progress, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(stageLabel(state.stage))
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundStyle(Color.kataIce)
                    .lineLimit(1)

                Text(subtitleText(state))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.kataChampagne)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private func subtitleText(_ state: VaultyxUploadAttributes.ContentState) -> String {
        let uploaded = formatBytes(state.bytesUploaded)
        let total = formatBytes(state.totalBytes)
        let files = state.filesRemaining
        if files > 1 {
            return "\(files) files · \(uploaded) / \(total)"
        } else {
            return "\(uploaded) / \(total)"
        }
    }
}

// MARK: - Expanded region sub-views

private struct TrailingLabel: View {
    let state: VaultyxUploadAttributes.ContentState

    var body: some View {
        if state.stage == .sealed {
            VStack(spacing: 1) {
                Text("Sealed.")
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(Color.kataChampagne)
                // Gold hairline underline
                Rectangle()
                    .fill(Color.kataGold)
                    .frame(height: 0.5)
            }
        } else {
            let pct = Int(progressFraction(state) * 100)
            Text("\(pct)%")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.kataChampagne)
        }
    }
}

private struct HairlineProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Rectangle()
                    .fill(Color.kataGold.opacity(0.25))
                    .frame(width: geo.size.width, height: 2)

                // Fill
                Rectangle()
                    .fill(Color.kataChampagne)
                    .frame(width: geo.size.width * CGFloat(progress), height: 2)
                    .animation(.linear(duration: 0.3), value: progress)
            }
        }
        .frame(height: 2)
        .clipShape(Capsule())
    }
}

private struct FilesRemainingLabel: View {
    let state: VaultyxUploadAttributes.ContentState

    var body: some View {
        let remaining = state.filesRemaining
        if remaining > 0 {
            Text("\(remaining) file\(remaining == 1 ? "" : "s") remaining")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.kataIce)
        } else {
            Text("All files processed")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.kataIce)
        }
    }
}

// MARK: - Compact trailing

private struct CompactTrailingLabel: View {
    let state: VaultyxUploadAttributes.ContentState

    var body: some View {
        if state.stage == .sealed {
            Text("Sealed.")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.kataChampagne)
        } else if state.stage == .failed {
            Text("Failed")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.kataFailCrimson)
        } else {
            let pct = Int(progressFraction(state) * 100)
            Text("\(pct)%")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.kataChampagne)
        }
    }
}
