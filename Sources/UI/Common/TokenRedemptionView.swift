import SwiftUI

/// Sheet shown from the paywall's "Redeem existing token" link. User pastes
/// a raw Katafract server token (Stripe subscriber or founder grant); we
/// validate via `/v1/token/info` and unlock if it grants Sovereign access.
struct TokenRedemptionView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var rawToken: String = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var successInfo: TokenInfoResponse?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste your token", text: $rawToken, axis: .vertical)
                        .lineLimit(3...6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Redeem Token")
                } footer: {
                    Text("Stripe subscribers and founders can unlock Vaultyx with an existing Katafract token. The token never leaves your device after this step.")
                }

                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if let info = successInfo {
                    Section("Token details") {
                        LabeledContent("Plan", value: info.plan ?? "—")
                        LabeledContent("Founder", value: info.is_founder ? "Yes" : "No")
                        if let exp = info.expires_at {
                            LabeledContent("Expires",
                                value: info.is_founder ? "Never" :
                                    Date(timeIntervalSince1970: TimeInterval(exp))
                                    .formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
            .navigationTitle("Redeem Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isChecking ? "Checking…" : "Redeem") {
                        Task { await redeem() }
                    }
                    .bold()
                    .disabled(isChecking || rawToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func redeem() async {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        do {
            let info = try await store.redeemToken(rawToken)
            successInfo = info
            // Give the user a half-beat to see the confirmation then dismiss
            // all the way to the app. PaywallView watches subscriptionState
            // and dismisses itself too.
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
