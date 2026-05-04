import SwiftUI
import SwiftData
import KatafractStyle
import OSLog

struct StuckItemsView: View {
    @EnvironmentObject private var services: VaultServices
    @Environment(\.modelContext) private var modelContext
    @State private var stuckFiles: [LocalFile] = []
    private let logger = Logger(subsystem: "com.katafract.vault", category: "stuck-items")

    var body: some View {
        List {
            if stuckFiles.isEmpty {
                ContentUnavailableView {
                    Label("No stuck items", systemImage: "checkmark.seal")
                } description: {
                    Text("All files are syncing normally")
                }
            } else {
                Section {
                    ForEach(stuckFiles, id: \.fileId) { file in
                        stuckItemRow(file: file)
                    }
                } header: {
                    sectionHeader("Files in trouble")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Stuck Items")
        .task {
            await loadStuckItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultyxFileSynced)) { _ in
            Task { await loadStuckItems() }
        }
        .refreshable {
            await loadStuckItems()
        }
    }

    // MARK: - Row builder

    private func stuckItemRow(file: LocalFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.filename)
                        .font(.kataBody(15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(file.fileId)
                        .font(.kataCaption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospaced()
                }
                Spacer()
                stateLabel(for: file.syncState)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if file.manifestAttempts > 0 {
                        Text("Manifest attempts: \(file.manifestAttempts)")
                            .font(.kataCaption(11))
                            .foregroundStyle(.secondary)
                    }
                    Text("Modified: \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.kataCaption(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    forceRetryFile(file)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.kataSapphire.opacity(0.04))
    }

    private func stateLabel(for state: String) -> some View {
        Text(displayName(for: state))
            .font(.kataCaption(11, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor(for: state))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func badgeColor(for state: String) -> Color {
        switch state {
        case "manifest_failed": return Color.red
        case "manifest_pending": return Color.orange
        case "conflict": return Color.purple
        case "pending_upload": return Color.cyan
        default: return Color.gray
        }
    }

    private func displayName(for state: String) -> String {
        switch state {
        case "manifest_failed": return "Manifest Failed"
        case "manifest_pending": return "Manifest Pending"
        case "conflict": return "Conflict"
        case "pending_upload": return "Pending Upload"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.kataCaption(11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Color.kataSapphire)
    }

    // MARK: - Data loading

    private func loadStuckItems() async {
        let descriptor = FetchDescriptor<LocalFile>(
            predicate: #Predicate {
                $0.syncState == "manifest_pending"
                    || $0.syncState == "manifest_failed"
                    || $0.syncState == "conflict"
                    || $0.syncState == "pending_upload"
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )

        let items = (try? modelContext.fetch(descriptor)) ?? []
        await MainActor.run {
            self.stuckFiles = items
        }
    }

    // MARK: - Actions

    private func forceRetryFile(_ file: LocalFile) {
        dlog("force-retry stuck file: \(file.filename) (id: \(file.fileId))", category: "stuck-items", level: .info)

        // Reset manifest attempt counter
        file.manifestAttempts = 0
        file.nextManifestRetryAt = .distantPast

        // If in manifest_failed, reset to pending_upload so it retries
        if file.syncState == "manifest_failed" {
            file.syncState = "pending_upload"
        }

        // Clear in-flight markers on all associated chunks
        let descriptor = FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate { $0.fileId == file.fileId }
        )
        let chunks = (try? modelContext.fetch(descriptor)) ?? []
        for chunk in chunks {
            chunk.inFlightTaskIdentifier = nil
            chunk.lastDispatchedAt = nil
            chunk.nextRetryAt = .distantPast
        }

        do {
            try modelContext.save()
            dlog("force-retry saved: reset \(chunks.count) chunk(s) for \(file.fileId)", category: "stuck-items", level: .info)

            // Trigger the drain
            Task {
                await services.syncEngine.syncPending()
                await loadStuckItems()
            }
        } catch {
            dlog("force-retry save failed: \(error.localizedDescription)", category: "stuck-items", level: .error)
        }
    }
}

#Preview {
    NavigationStack {
        StuckItemsView()
            .environmentObject(VaultServices())
    }
}
