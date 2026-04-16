import SwiftUI

struct LockScreenView: View {
    @ObservedObject var lock = BiometricLock.shared
    @State private var isAuthenticating = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue)

                VStack(spacing: 8) {
                    Text("Vault is Locked")
                        .font(.title2.bold())
                    Text("Use \(lock.biometryType) to unlock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if failed {
                    Text("Authentication failed. Try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                Button {
                    Task { await authenticate() }
                } label: {
                    HStack {
                        Image(systemName: lock.biometryType == "Face ID" ? "faceid" : "touchid")
                        Text("Unlock with \(lock.biometryType)")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(14)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .disabled(isAuthenticating)
            }
        }
        .task { await authenticate() }
    }

    func authenticate() async {
        isAuthenticating = true
        failed = false
        let success = await lock.unlock()
        isAuthenticating = false
        if !success { failed = true }
    }
}
