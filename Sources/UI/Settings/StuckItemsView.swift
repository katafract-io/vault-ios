import SwiftUI
import SwiftData
import KatafractStyle
import OSLog

struct StuckItemsView: View {
    @EnvironmentObject private var services: VaultServices
    @Environment(\.modelContext) private var modelContext
    @State private var stuckFiles: [LocalFile] = []
    @State private var orphanFiles: [LocalFile] = []
    private let logger = Logger(subsystem: "com.katafract.vault", category: "stuck-items")

    var body: some View {
        List {
            if stuckFiles.isEmpty && orphanFiles.isEmpty {
                ContentUnavailableView {
                    Label("No stuck items", systemImage: "checkmark.seal")
                } description: {
                    Text("All files are syncing normally")
                }
            } else {
                if !stuckFiles.isEmpty {
                    Section {
                        ForEach(stuckFiles, id: \.fileId) { file in
                            stuckItemRow(file: file)
                        }
                    } header: {
                        sectionHeader("Files in trouble")
                    }
                }

                if !orphanFiles.isEmpty {
                    Section {
                        ForEach(orphanFiles, id: \.fileId) { file in
                            orphanItemRow(file: file)
                        }
                    } header: {
                        sectionHeader("Stuck files (cannot recover)")
                    }
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

    private func orphanItemRow(file: LocalFile) -> some View {
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
                    Text("Modified: \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.kataCaption(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    purgeOrphan(file)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.red.opacity(0.04))
    }

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
        case "orphan": return Color.red
        case "manifest_failed": return Color.red
        case "manifest_pending": return Color.orange
        case "conflict": return Color.purple
        case "pending_upload": return Color.cyan
        default: return Color.gray
        }
    }

    private func displayName(for state: String) -> String {
        switch state {
        case "orphan": return "Orphan"
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
        let stuckDescriptor = FetchDescriptor<LocalFile>(
            predicate: #Predicate {
                $0.syncState == "manifest_pending"
                    || $0.syncState == "manifest_failed"
                    || $0.syncState == "conflict"
                    || $0.syncState == "pending_upload"
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )

        let orphanDescriptor = FetchDescriptor<LocalFile>(
            predicate: #Predicate { $0.syncState == "orphan" },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )

        let stuckItems = (try? modelContext.fetch(stuckDescriptor)) ?? []
        let orphanItems = (try? modelContext.fetch(orphanDescriptor)) ?? []

        await MainActor.run {
            self.stuckFiles = stuckItems
            self.orphanFiles = orphanItems
        }
    }

    // MARK: - Actions

    private func purgeOrphan(_ file: LocalFile) {
        dlog("purgeOrphan: deleting orphan file \(file.filename) (id: \(file.fileId))", category: "stuck-items", level: .info)

        modelContext.delete(file)

        let backedUpDescriptor = FetchDescriptor<BackedUpAsset>(
            predicate: #Predicate { $0.fileId == file.fileId }
        )
        if let backedUp = (try? modelContext.fetch(backedUpDescriptor)).first {
            modelContext.delete(backedUp)
        }

        let chunkDescriptor = FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate { $0.fileId == file.fileId }
        )
        let chunks = (try? modelContext.fetch(chunkDescriptor)) ?? []
        for chunk in chunks {
            modelContext.delete(chunk)
        }

        do {
            try modelContext.save()
            dlog("purgeOrphan: deleted orphan file and \(chunks.count) chunk(s)", category: "stuck-items", level: .info)
            Task {
                await loadStuckItems()
            }
        } catch {
            dlog("purgeOrphan save failed: \(error.localizedDescription)", category: "stuck-items", level: .error)
        }
    }

    private func forceRetryFile(_ file: LocalFile) {
        dlog("force-retry stuck file: \(file.filename) (id: \(file.fileId))", category: "stuck-items", level: .info)

        file.manifestAttempts = 0
        file.nextManifestRetryAt = .distantPast

        if file.syncState == "manifest_failed" || file.syncState == "conflict" {
            file.syncState = "pending_upload"
        }

        let fileId = file.fileId
        let descriptor = FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate { $0.fileId == fileId }
        )
        let chunks = (try? modelContext.fetch(descriptor)) ?? []
        for chunk in chunks {
            chunk.inFlightTaskIdentifier = nil
            chunk.lastDispatchedAt = nil
            chunk.nextRetryAt = .distantPast
            chunk.attempts = 0
        }

        do {
            try modelContext.save()
            dlog("force-retry saved: reset \(chunks.count) chunk(s) for \(file.fileId)", category: "stuck-items", level: .info)

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
