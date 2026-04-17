import SwiftUI
import CryptoKit

/// Paste-24-words flow. Decodes, verifies checksum, overwrites the master
/// key in Keychain, reseeds VaultKeyManager. **Destructive if the user has
/// existing data encrypted under a different master key** — we warn before
/// committing.
struct RestoreFromPhraseView: View {
    @EnvironmentObject private var services: VaultServices
    @Environment(\.dismiss) private var dismiss

    @State private var input: String = ""
    @State private var errorMessage: String?
    @State private var showOverwriteConfirm = false
    @State private var restored = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste your 24-word phrase here",
                              text: $input, axis: .vertical)
                        .lineLimit(6...12)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                } header: {
                    Text("Recovery Phrase")
                } footer: {
                    Text("Separate words with spaces or newlines. Case and extra whitespace don't matter.")
                }

                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text("⚠️ Restoring with a different phrase will make this device unable to decrypt any files encrypted under the current key. Only proceed if you're restoring from a backup, not starting fresh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Restore from Phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Restore") { attemptRestore() }
                        .bold()
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Overwrite current key?", isPresented: $showOverwriteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Overwrite", role: .destructive) {
                    Task { await commitRestore() }
                }
            } message: {
                Text("This replaces the current master key. Files encrypted under the old key will become unreadable on this device.")
            }
            .alert("Restored", isPresented: $restored) {
                Button("OK") { dismiss() }
            } message: {
                Text("Master key restored from recovery phrase.")
            }
        }
    }

    private func attemptRestore() {
        errorMessage = nil
        let words = input
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            _ = try RecoveryPhrase.key(from: words)
            showOverwriteConfirm = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitRestore() async {
        let words = input
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            let newKey = try RecoveryPhrase.key(from: words)
            let bytes = newKey.withUnsafeBytes { Data($0) }
            try Keychain.set(bytes, forKey: MasterKeyBootstrap.keychainKey, synchronizable: true)
            await services.keyManager.setMasterKeyDirectly(newKey)
            restored = true
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
