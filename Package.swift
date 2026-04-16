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
