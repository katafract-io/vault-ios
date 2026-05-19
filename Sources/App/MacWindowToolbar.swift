#if targetEnvironment(macCatalyst)
import UIKit
import SwiftUI

/// Mac Catalyst window configuration for Vaultyx app.
/// Provides native macOS window sizing, toolbar, and minimum dimensions.
enum MacWindowConfig {
    /// Configure the current window with Mac-native sizing and toolbar.
    /// Call this from VaultApp.init() to apply settings at launch.
    @MainActor
    static func setup() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0 is UIWindowScene }) as? UIWindowScene else {
            return
        }

        // Set window title to "Vaultyx"
        windowScene.windows.forEach { window in
            window.windowScene?.title = "Vaultyx"
        }

        // Configure minimum size restrictions via UIWindowScene
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 600)
    }
}
#endif
