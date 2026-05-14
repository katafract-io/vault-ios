import SwiftUI

struct BackupDashboardCard: View {
    @ObservedObject var viewModel: PhotosViewModel
    @State private var showDetailSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if viewModel.syncStatus == .syncing {
                        Text("Backing up… \(viewModel.backedUpCount) of \(viewModel.totalCount) photos")
                            .font(.headline)
                            .foregroundColor(.primary)
                    } else {
                        Text("\(viewModel.backedUpCount) photos backed up")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }

                    HStack(spacing: 8) {
                        if let lastSealed = viewModel.lastSealedAt {
                            Text("Last sealed \(timeAgoString(lastSealed)) ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Never sealed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text("•")
                            .foregroundColor(.secondary)

                        Text("\(formatBytes(viewModel.storageUsed)) of \(formatBytes(viewModel.quotaBytes)) used")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .center, spacing: 8) {
                    statusIcon

                    CircularProgressView(
                        progress: viewModel.totalCount > 0 ? Double(viewModel.backedUpCount) / Double(viewModel.totalCount) : 0
                    )
                    .frame(width: 48, height: 48)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.systemGray5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            showDetailSheet = true
        }
        .sheet(isPresented: $showDetailSheet) {
            BackupDashboardDetailSheet(viewModel: viewModel)
        }
    }

    private var statusIcon: some View {
        Group {
            if viewModel.syncStatus == .error {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.red)
            } else if viewModel.syncStatus == .syncing {
                Image(systemName: "clock.badge")
                    .font(.system(size: 20))
                    .foregroundColor(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.green)
            }
        }
    }

    private func timeAgoString(_ date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .hour, .day], from: date, to: Date())

        if let day = components.day, day > 0 {
            return "\(day)d"
        } else if let hour = components.hour, hour > 0 {
            return "\(hour)h"
        } else if let minute = components.minute, minute > 0 {
            return "\(minute)m"
        } else {
            return "now"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    BackupDashboardCard(viewModel: {
        let vm = PhotosViewModel(modelContext: nil, services: nil)
        vm.backedUpCount = 47103
        vm.totalCount = 47103
        vm.lastSealedAt = Date(timeIntervalSinceNow: -240)
        vm.storageUsed = 13_222_000_000
        vm.quotaBytes = 1_099_511_627_776
        return vm
    }())
}
