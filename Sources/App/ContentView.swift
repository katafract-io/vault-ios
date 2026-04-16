import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Text("Vault")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Zero-Knowledge File Encryption")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
