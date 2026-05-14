import SwiftUI

struct CustodyBadge: View {
    let isCustodial: Bool

    var body: some View {
        if isCustodial {
            Image(systemName: "lock.shield.fill")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(3)
                .background(Circle().fill(Color.blue.opacity(0.6)))
        }
    }
}

#Preview {
    CustodyBadge(isCustodial: true)
}
