import SwiftUI
import Photos
import KatafractStyle

struct AlbumPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = AlbumPickerViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                // Dark sapphire background
                Color.kataSapphire.opacity(0.1)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header with Select All toggle
                    HStack {
                        Text("ALBUMS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            let allSelected = viewModel.albums.allSatisfy { $0.isSelected }
                            if allSelected {
                                viewModel.deselectAll()
                            } else {
                                viewModel.selectAll()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                Text("Select All")
                                    .font(.caption)
                            }
                            .foregroundStyle(Color.kataGold)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()
                        .padding(.vertical, 8)

                    if viewModel.isLoading {
                        // Skeleton loading state
                        VStack(spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(.systemGray5).opacity(0.5))
                                        .frame(width: 44, height: 44)

                                    VStack(alignment: .leading, spacing: 4) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(.systemGray5).opacity(0.5))
                                            .frame(height: 12)
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(.systemGray5).opacity(0.5))
                                            .frame(width: 100, height: 10)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.vertical, 12)
                    } else if viewModel.albums.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No albums found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        List {
                            ForEach(viewModel.albums) { album in
                                albumRow(for: album)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }

                    Spacer()

                    // Save button with gold gradient
                    VStack(spacing: 12) {
                        Divider()

                        Button {
                            _ = viewModel.save()
                            dismiss()
                        } label: {
                            Text("Save Selection")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .foregroundStyle(Color.black.opacity(0.85))
                                .background(
                                    LinearGradient(
                                        colors: [
                                            Color.kataGold,
                                            Color.kataGold.opacity(0.85)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                    .background(Color(.systemBackground).opacity(0.95))
                }
            }
            .navigationTitle("Choose Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await viewModel.loadAlbums()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func albumRow(for album: AlbumItem) -> some View {
        HStack(spacing: 12) {
            // Album thumbnail (44x44)
            if let coverAssetId = album.coverAssetId {
                PhotoThumbnailView(
                    assetLocalIdentifier: coverAssetId,
                    targetSize: CGSize(width: 44, height: 44)
                )
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray5))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(.secondary)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("\(album.assetCount) \(album.assetCount == 1 ? "photo" : "photos")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Toggle selection
            Image(systemName: album.isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(album.isSelected ? Color.kataGold : Color(.systemGray3))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleSelection(for: album)
        }
    }
}

#Preview {
    AlbumPickerSheet()
}
