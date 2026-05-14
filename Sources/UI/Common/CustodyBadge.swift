import SwiftUI
import KatafractStyle

/// Single reusable `CustodyBadge` SwiftUI view showing custody state of a vault item.
/// Renders as a 20x20pt badge on file rows and photo cells.
///
/// States are composable (e.g., stripped+inVault, tunneled+verified), but the default
/// rendering shows the dominant state. A detail view variant shows all active states.
struct CustodyBadge: View {
    let state: CustodyState
    var size: CGFloat = 20
    var showDetail: Bool = false

    var body: some View {
        if showDetail {
            detailView
        } else {
            compactView
        }
    }

    @ViewBuilder
    private var compactView: some View {
        let dominant = state.dominantState

        ZStack {
            Image(systemName: dominantSymbol(for: dominant))
                .font(.system(size: size * 0.8))
                .foregroundStyle(dominantColor(for: dominant))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var detailView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if state.contains(.verified) {
                    BadgeRow(symbol: "lock.shield.fill", color: .green, label: "Verified")
                }
                if state.contains(.stripped) {
                    BadgeRow(symbol: "scissors", color: .purple, label: "EXIF Stripped")
                }
                if state.contains(.inVault) {
                    BadgeRow(symbol: "lock.shield.ring.fill", color: .green, label: "In Vault")
                }
                if state.contains(.sealed) {
                    BadgeRow(symbol: "lock.fill", color: .orange, label: "Sealed")
                }
                if state.contains(.onDevice) {
                    BadgeRow(symbol: "lock.fill", color: .gray, label: "On Device")
                }
                if state.contains(.tunneled) {
                    BadgeRow(symbol: "wave.3.forward", color: .blue, label: "Tunneled")
                }
            }
        }
    }

    private func dominantSymbol(for custody: CustodyState) -> String {
        switch custody {
        case .verified:
            return "lock.shield.fill"  // lock with checkmark implied by "fill"
        case .stripped:
            return "scissors"
        case .inVault:
            return "lock.shield.ring.fill"
        case .sealed:
            return "lock.fill"
        case .onDevice:
            return "lock.fill"
        case .tunneled:
            return "wave.3.forward"
        default:
            return "lock.fill"
        }
    }

    private func dominantColor(for custody: CustodyState) -> Color {
        switch custody {
        case .verified:
            return .green
        case .stripped:
            return .purple
        case .inVault:
            return .green
        case .sealed:
            return .orange
        case .onDevice:
            return .gray
        case .tunneled:
            return .blue
        default:
            return .gray
        }
    }

    private var accessibilityLabel: String {
        var labels: [String] = []

        if state.contains(.verified) { labels.append("Verified") }
        if state.contains(.stripped) { labels.append("EXIF stripped") }
        if state.contains(.inVault) { labels.append("In vault") }
        if state.contains(.sealed) { labels.append("Sealed") }
        if state.contains(.onDevice) { labels.append("On device") }
        if state.contains(.tunneled) { labels.append("Tunneled") }

        return labels.isEmpty ? "Unknown state" : labels.joined(separator: ", ")
    }
}

/// Helper row for detail view showing individual custody state.
private struct BadgeRow: View {
    let symbol: String
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)

            Text(label)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("On Device").font(.caption).foregroundStyle(.secondary)
                CustodyBadge(state: .onDevice)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sealed").font(.caption).foregroundStyle(.secondary)
                CustodyBadge(state: .sealed)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("In Vault").font(.caption).foregroundStyle(.secondary)
                CustodyBadge(state: .inVault)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Verified").font(.caption).foregroundStyle(.secondary)
                CustodyBadge(state: .verified)
            }
        }

        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stripped").font(.caption).foregroundStyle(.secondary)
                CustodyBadge(state: .stripped)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tunneled").font(.caption).foregroundStyle(.secondary)
                CustodyBadge(state: .tunneled)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Stripped+InVault").font(.caption).foregroundStyle(.secondary)
                CustodyBadge(state: [.stripped, .inVault])
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Verified+Tunneled").font(.caption).foregroundStyle(.secondary)
                CustodyBadge(state: [.verified, .tunneled])
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Detail View (Verified + Stripped + InVault)")
                .font(.caption)
                .foregroundStyle(.secondary)

            CustodyBadge(state: [.verified, .stripped, .inVault], showDetail: true)
        }

        Spacer()
    }
    .padding()
}
