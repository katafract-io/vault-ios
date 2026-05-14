import SwiftUI
import KatafractStyle
import OSLog

struct S3KeyManagementView: View {
    @EnvironmentObject private var services: VaultServices
    @State private var keys: [S3AccessKey] = []
    @State private var showGenerateSheet = false
    @State private var showKeyReveal = false
    @State private var revealedKey: GeneratedS3Key?
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let logger = Logger(subsystem: "com.katafract.vault", category: "s3-keys")
    private let s3Endpoint = "s3.objstore.io"

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect rclone, Cyberduck, or any S3-compatible app to your Vaultyx storage.")
                        .font(.kataCaption(12))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text(s3Endpoint)
                            .font(.kataBody(13))
                            .monospaced()
                            .foregroundStyle(.primary)

                        Spacer()

                        Button {
                            UIPasteboard.general.string = s3Endpoint
                            KataHaptic.light.fire()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.kataSapphire)
                        }
                    }
                    .padding(10)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .listRowBackground(Color.clear)
            } header: {
                sectionHeader("Endpoint")
            }

            Section {
                if keys.isEmpty && !isLoading {
                    ContentUnavailableView {
                        Label("No keys", systemImage: "key.slash")
                    } description: {
                        Text("Generate your first access key to get started")
                    }
                } else if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Loading keys...")
                            .font(.kataBody(15))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(keys, id: \.keyId) { key in
                        keyRow(key)
                    }
                }
            } header: {
                sectionHeader("Access Keys")
            }

            Section {
                Button {
                    KataHaptic.revealed.fire()
                    showGenerateSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.kataSapphire)
                        Text("Generate New Key")
                            .font(.kataBody(15, weight: .semibold))
                            .foregroundStyle(Color.kataSapphire)
                        Spacer()
                    }
                }
                .listRowBackground(Color.kataSapphire.opacity(0.04))
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .font(.kataCaption(12))
                        .foregroundStyle(.red)
                }
            }

            Section {
                Link(destination: URL(string: "https://docs.katafract.io/vaultyx/s3")!) {
                    HStack(spacing: 12) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.kataSapphire)
                            .frame(width: 28)
                        Text("rclone Setup Guide")
                            .font(.kataBody(15))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.kataSapphire.opacity(0.04))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("S3 Access")
        .task {
            await loadKeys()
        }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateS3KeySheet { key in
                revealedKey = key
                showKeyReveal = true
                showGenerateSheet = false
                Task { await loadKeys() }
            }
        }
        .sheet(isPresented: $showKeyReveal) {
            if let key = revealedKey {
                S3KeyRevealView(key: key) {
                    showKeyReveal = false
                    revealedKey = nil
                }
            }
        }
    }

    private func keyRow(_ key: S3AccessKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.label)
                        .font(.kataBody(15, weight: .medium))
                        .foregroundStyle(.primary)

                    let createdDate = DateFormatter.localizedString(
                        from: Date(timeIntervalSince1970: TimeInterval(key.createdAt)),
                        dateStyle: .medium,
                        timeStyle: .none
                    )
                    let lastUsedText = key.lastUsedAt > 0
                        ? "Last used \(timeAgoString(from: key.lastUsedAt))"
                        : "Never used"

                    Text("Created \(createdDate) — \(lastUsedText)")
                        .font(.kataCaption(11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    Task { await revokeKey(key) }
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.kataSapphire.opacity(0.04))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.kataCaption(11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Color.kataSapphire)
    }

    private func timeAgoString(from timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.day, .hour, .minute], from: date, to: now)

        if let days = components.day, days > 0 {
            return "\(days)d ago"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h ago"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m ago"
        } else {
            return "just now"
        }
    }

    // MARK: - API Methods (mocked for now)

    private func loadKeys() async {
        // BLOCKER: VLT-B3 — S3 key endpoints not yet implemented in vault.py
        // Mocking with placeholder data for UI development

        isLoading = true
        errorMessage = nil

        // Simulate network delay
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Mock data for demonstration
        await MainActor.run {
            keys = [
                S3AccessKey(
                    keyId: "key_001",
                    label: "Cyberduck (Mac)",
                    createdAt: Int64(Date().addingTimeInterval(-86400 * 7).timeIntervalSince1970),
                    lastUsedAt: Int64(Date().addingTimeInterval(-3600 * 2).timeIntervalSince1970)
                ),
                S3AccessKey(
                    keyId: "key_002",
                    label: "rclone (Laptop)",
                    createdAt: Int64(Date().addingTimeInterval(-86400 * 3).timeIntervalSince1970),
                    lastUsedAt: Int64(Date().addingTimeInterval(-86400).timeIntervalSince1970)
                )
            ]
            isLoading = false
            dlog("loaded \(keys.count) mocked S3 keys", category: "s3-keys", level: .info)
        }
    }

    private func revokeKey(_ key: S3AccessKey) async {
        // BLOCKER: VLT-B3 — DELETE /v1/vault/s3-keys/{keyId} not yet implemented
        // Mocking the delete action for UI development

        dlog("revoking S3 key: \(key.keyId)", category: "s3-keys", level: .info)

        await MainActor.run {
            keys.removeAll { $0.keyId == key.keyId }
            KataHaptic.heavy.fire()
        }
    }
}

// MARK: - Data Models

struct S3AccessKey: Identifiable {
    let id: String { keyId }
    let keyId: String
    let label: String
    let createdAt: Int64
    let lastUsedAt: Int64
}

struct GeneratedS3Key {
    let accessKeyId: String
    let secretAccessKey: String
    let label: String
}

// MARK: - Generate Sheet

struct GenerateS3KeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    let onKeyGenerated: (GeneratedS3Key) -> Void
    private let logger = Logger(subsystem: "com.katafract.vault", category: "s3-keys")

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Key label", text: $label, prompt: Text("e.g., 'Cyberduck', 'rclone'"))
                        .font(.kataBody(15))
                } header: {
                    Text("Key Label")
                        .font(.kataCaption(11, weight: .semibold))
                        .tracking(1.2)
                } footer: {
                    Text("Use a descriptive name to identify where this key is used.")
                        .font(.kataCaption(12))
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.kataCaption(12))
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await generateKey() }
                    } label: {
                        HStack(spacing: 8) {
                            if isGenerating {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.8)
                            }
                            Text("Generate Key")
                                .font(.kataBody(15, weight: .semibold))
                                .foregroundStyle(Color.kataSapphire)
                            Spacer()
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)
                    .listRowBackground(Color.kataSapphire.opacity(0.04))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Generate New Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func generateKey() async {
        // BLOCKER: VLT-B3 — POST /v1/vault/s3-keys not yet implemented
        // Mocking key generation for UI development

        isGenerating = true
        errorMessage = nil

        // Simulate network delay
        try? await Task.sleep(nanoseconds: 500_000_000)

        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)

        // Mock generated credentials
        let accessKeyId = "AKIA" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let secretAccessKey = UUID().uuidString.replacingOccurrences(of: "-", with: "") +
                             UUID().uuidString.replacingOccurrences(of: "-", with: "")

        await MainActor.run {
            let generatedKey = GeneratedS3Key(
                accessKeyId: String(accessKeyId),
                secretAccessKey: secretAccessKey,
                label: trimmedLabel
            )
            isGenerating = false
            dlog("mocked S3 key generation for: \(trimmedLabel)", category: "s3-keys", level: .info)
            onKeyGenerated(generatedKey)
        }
    }
}

// MARK: - Key Reveal View

struct S3KeyRevealView: View {
    @Environment(\.dismiss) private var dismiss
    let key: GeneratedS3Key
    let onDismiss: () -> Void
    @State private var copiedField: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("⚠️ Save these credentials now. You won't see them again.")
                            .font(.kataCaption(12))
                            .foregroundStyle(.orange)
                            .padding(10)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                    }
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Important")
                        .font(.kataCaption(11, weight: .semibold))
                        .tracking(1.2)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Access Key ID")
                            .font(.kataCaption(11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Text(key.accessKeyId)
                                .font(.kataBody(13))
                                .monospaced()
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)

                            Spacer()

                            Button {
                                UIPasteboard.general.string = key.accessKeyId
                                copiedField = "accessKey"
                                KataHaptic.light.fire()

                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedField = nil
                                }
                            } label: {
                                Image(systemName: copiedField == "accessKey" ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(copiedField == "accessKey" ? .green : Color.kataSapphire)
                            }
                        }
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                } header: {
                    Text("Access Key")
                        .font(.kataCaption(11, weight: .semibold))
                        .tracking(1.2)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Secret Access Key")
                            .font(.kataCaption(11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Text(key.secretAccessKey)
                                .font(.kataBody(13))
                                .monospaced()
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)

                            Spacer()

                            Button {
                                UIPasteboard.general.string = key.secretAccessKey
                                copiedField = "secretKey"
                                KataHaptic.light.fire()

                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedField = nil
                                }
                            } label: {
                                Image(systemName: copiedField == "secretKey" ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(copiedField == "secretKey" ? .green : Color.kataSapphire)
                            }
                        }
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                } header: {
                    Text("Secret Key")
                        .font(.kataCaption(11, weight: .semibold))
                        .tracking(1.2)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use these credentials with rclone, Cyberduck, Mountain Duck, or any S3-compatible tool to access your vault.")
                            .font(.kataCaption(12))
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                } header: {
                    Text("How to use")
                        .font(.kataCaption(11, weight: .semibold))
                        .tracking(1.2)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("S3 Credentials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                        onDismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        S3KeyManagementView()
            .environmentObject(VaultServices())
    }
}
