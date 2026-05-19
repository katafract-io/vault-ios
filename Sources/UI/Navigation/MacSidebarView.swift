#if targetEnvironment(macCatalyst)
import SwiftUI

struct MacSidebarView: View {
    @Binding var selection: MacSidebarItem?

    var body: some View {
        List(MacSidebarItem.allCases, selection: $selection) { item in
            Label(item.rawValue, systemImage: item.icon)
        }
        .listStyle(.sidebar)
        .navigationTitle("Vaultyx")
    }
}

#endif
