import SwiftUI
import UIKit
import os

/// Full-screen blocking error view shown when vault-store bootstrap fails
/// (either Keychain or the on-device encrypted database itself). This
/// prevents the vault from being usable until the issue is resolved — the
/// app must never look like a normal, empty vault when the real one
/// couldn't be opened (2026-07-26 Codex audit, #210).
struct KeychainBootstrapErrorView: View {
    /// The actual underlying error, so both the user-visible copy and the
    /// copyable diagnostics reflect the real cause rather than a generic
    /// Keychain-only message that doesn't fit a SwiftData store failure.
    let error: Error
    /// Runs a real, non-destructive re-check and returns its outcome —
    /// never a no-op (see `VaultServices.retryBootstrap()`).
    let onRetry: () -> VaultServices.BootstrapRetryOutcome
    @State private var diagnosticsCopied = false
    @State private var retryResultMessage: String?

    private var diagnosticsString: String {
        let device = UIDevice.current.model
        let osVersion = UIDevice.current.systemVersion
        let bundle = Bundle.main.bundleIdentifier ?? "unknown"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        return """
        Vaultyx Bootstrap Error Diagnostics
        ===================================
        Device: \(device)
        OS Version: \(osVersion)
        Bundle: \(bundle)
        App Version: \(appVersion) (Build \(buildNumber))
        Timestamp: \(Date().formatted(date: .abbreviated, time: .standard))
        Error: \(error.localizedDescription)
        """
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.lock.fill")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(.red)

                    Text("Vault Setup Failed")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Vaultyx couldn't open your encrypted vault storage. Your files have not been touched or deleted — this may be a temporary device issue.")
                        .font(.system(size: 16, weight: .regular))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)

                    if let retryResultMessage {
                        Text(retryResultMessage)
                            .font(.system(size: 14, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.orange)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    Button(action: {
                        switch onRetry() {
                        case .resolvedRelaunchRequired:
                            retryResultMessage = "Your vault storage is available again. Please force-quit and reopen Vaultyx to finish recovering."
                        case .stillFailing:
                            retryResultMessage = "Still unable to open your vault storage. Please try again shortly, or contact support if this persists."
                        }
                    }) {
                        Text("Retry")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button(action: {
                        UIPasteboard.general.string = diagnosticsString
                        withAnimation(.easeInOut(duration: 0.2)) {
                            diagnosticsCopied = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                diagnosticsCopied = false
                            }
                        }
                    }) {
                        Text(diagnosticsCopied ? "Diagnostics Copied" : "Copy Diagnostics")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.systemGray5))
                            .foregroundStyle(diagnosticsCopied ? .green : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 24)

                VStack(spacing: 8) {
                    Text("If this persists, please contact support:")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)

                    Link("support@katafract.com", destination: URL(string: "mailto:support@katafract.com")!)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(.vertical, 32)
        }
    }
}

#Preview {
    struct PreviewError: LocalizedError {
        var errorDescription: String? { "Preview store-open failure" }
    }
    return KeychainBootstrapErrorView(error: PreviewError(), onRetry: { .stillFailing(PreviewError()) })
}
