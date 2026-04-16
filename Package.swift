// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Vault",
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

// Note: Share extension target requires xcodegen or native Xcode project.
// See ShareExtension/Info.plist for target configuration.

