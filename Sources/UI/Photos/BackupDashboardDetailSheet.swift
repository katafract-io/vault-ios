import SwiftUI
import BackgroundTasks

struct BackupDashboardDetailSheet: View {
    @ObservedObject var viewModel: PhotosViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    HStack {
                        Text("Last sync")
                        Spacer()
                        Text(formattedLastSyncTime)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Pending uploads")
                        Spacer()
                        Text("\(viewModel.queueCount)")
                            .foregroundColor(.secondary)
                    }
                }

                if !viewModel.errorLog.isEmpty {
                    Section("Recent errors") {
                        ForEach(viewModel.errorLog, id: \.self) { error in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .lineLimit(3)
                            }
                        }
                    }
                }

                Section {
                    Button(action: triggerSync) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Sync Now")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Backup Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var formattedLastSyncTime: String {
        if let lastSealed = viewModel.lastSealedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: lastSealed)
        }
        return "Never"
    }

    private func triggerSync() {
        let request = BGProcessingTaskRequest(identifier: "com.katafract.vault.photosync")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            viewModel.syncStatus = .syncing
        } catch {
            viewModel.errorLog.append("Failed to schedule sync: \(error.localizedDescription)")
            viewModel.syncStatus = .error
        }
    }
}

#Preview {
    BackupDashboardDetailSheet(viewModel: {
        let vm = PhotosViewModel(modelContext: nil, services: nil)
        vm.backedUpCount = 47103
        vm.totalCount = 47103
        vm.lastSealedAt = Date(timeIntervalSinceNow: -240)
        vm.queueCount = 5
        vm.errorLog = ["Failed to upload IMG_001.jpg: Network timeout"]
        return vm
    }())
}
