// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Vaultyx",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Vault",
            dependencies: [],
            path: "Sources"
        )
    ]
)

// Note: Extension targets (Share, FileProvider) require xcodegen or native Xcode project.
// - ShareExtension/Info.plist: share-sheet integration
// - FileProvider/Info.plist: Files.app + Finder integration
//
// To build extensions, use:
//   xcodebuild -scheme Vault -configuration Release build
// or generate Xcode project with xcodegen and add targets manually.

