import SwiftUI
import UIKit
import os

/// Full-screen blocking error view shown when Keychain bootstrap fails.
/// This prevents the vault from being usable until the issue is resolved.
struct KeychainBootstrapErrorView: View {
    let onRetry: () -> Void
    @State private var diagnosticsCopied = false

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

                    Text("Vaultyx cannot protect your files because it couldn't save the encryption key securely. This may be a temporary device issue.")
                        .font(.system(size: 16, weight: .regular))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                }
                .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    Button(action: onRetry) {
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
    KeychainBootstrapErrorView(onRetry: {})
}
