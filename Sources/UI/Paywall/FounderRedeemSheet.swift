import SwiftUI
import KatafractStyle

/// Sheet shown from the paywall's "Have a founder code?" link. User enters
/// a founder code, we validate via `/v1/founder/redeem/{code}` GET preview endpoint,
/// then POST to claim. On success, token is stashed in Keychain and user is
/// granted Sovereign entitlement.
struct FounderRedeemSheet: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var isChecking = false
    @State private var isClaiming = false
    @State private var errorMessage: String?
    @State private var previewInfo: FounderCodePreviewResponse?
    @State private var showSuccessMessage = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Founder code",
                        text: $code,
                        axis: .vertical
                    )
                    .lineLimit(1)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .keyboardType(.asciiCapable)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: code) {
                        // Clear preview when user modifies code
                        if !code.isEmpty {
                            previewInfo = nil
                            errorMessage = nil
                        }
                    }
                } header: {
                    Text("Founder Code")
                } footer: {
                    Text("Enter your founder code to unlock Vaultyx Sovereign, including 1 TB encrypted storage and priority support.")
                }

                // Show preview details if available
                if let preview = previewInfo {
                    Section("Redeem as") {
                        LabeledContent("Recipient", value: preview.label)
                        LabeledContent("Plan", value: preview.plan)
                        if !preview.claimed {
                            LabeledContent("Status", value: "Available")
                                .foregroundStyle(.green)
                        } else {
                            LabeledContent("Status", value: "Already claimed")
                                .foregroundStyle(.red)
                        }
                    }
                }

                // Show error if preview or redemption fails
                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                // Show success message
                if showSuccessMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Code redeemed successfully", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Your Sovereign access has been unlocked. Closing in a moment...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Founder Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if previewInfo != nil && !previewInfo!.claimed && !isClaiming {
                        Button(isClaiming ? "Redeeming…" : "Redeem") {
                            Task { await claimCode() }
                        }
                        .bold()
                        .disabled(isClaiming || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else if previewInfo == nil {
                        Button(isChecking ? "Checking…" : "Check") {
                            Task { await previewCode() }
                        }
                        .bold()
                        .disabled(isChecking || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func previewCode() async {
        isChecking = true
        errorMessage = nil
        previewInfo = nil
        defer { isChecking = false }

        do {
            let preview = try await store.previewFounderCode(code)
            previewInfo = preview

            if preview.claimed {
                errorMessage = "This code has already been redeemed."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func claimCode() async {
        isClaiming = true
        errorMessage = nil
        defer { isClaiming = false }

        do {
            _ = try await store.redeemFounderCode(code)
            showSuccessMessage = true

            // Dismiss after brief delay
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
