#if targetEnvironment(macCatalyst)
import SwiftUI

struct MacRootView: View {
    @ObservedObject private var lock = BiometricLock.shared
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @State private var showLapsedPaywall = false
    @State private var sidebarSelection: MacSidebarItem? = .allFiles

    var isReadOnly: Bool {
        subscriptionStore.subscriptionState == .notSubscribed
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            MacSidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } content: {
            switch sidebarSelection {
            case .allFiles, .none:
                NavigationStack {
                    FileBrowserView(folderId: nil, isReadOnly: isReadOnly)
                }
            case .photos:
                NavigationStack {
                    PhotosView()
                }
            case .recent:
                NavigationStack {
                    RecentsView()
                }
            case .settings:
                NavigationStack {
                    SettingsView()
                }
            }
        } detail: {
            Text("Select an item")
                .foregroundStyle(.secondary)
        }
        .onChange(of: subscriptionStore.subscriptionState) { oldState, newState in
            // Detect transition from subscribed/redeemed to notSubscribed
            switch (oldState, newState) {
            case (.subscribed, .notSubscribed), (.redeemed, .notSubscribed):
                showLapsedPaywall = true
                dlog("subscription lapsed, showing paywall", category: "subscription")
            default:
                break
            }
        }
        .fullScreenCover(isPresented: $showLapsedPaywall) {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer()

                    CapacityPickerView()

                    Spacer()

                    Button {
                        showLapsedPaywall = false
                        dlog("dismissed lapsed subscription paywall", category: "subscription")
                    } label: {
                        Text("Continue in read-only mode")
                            .font(.kataBody(15, weight: .semibold))
                            .foregroundStyle(Color.kataSapphire)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.kataSapphire.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .interactiveDismissDisabled()
        }
    }
}

enum MacSidebarItem: String, CaseIterable, Identifiable {
    case allFiles = "All Files"
    case photos = "Photos"
    case recent = "Recent"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .allFiles: return "folder.fill"
        case .photos: return "photo.fill"
        case .recent: return "clock.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

#endif
