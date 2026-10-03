// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JobHunter",
    defaultLocalization: "de",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "JobHunter", targets: ["JobHunter"]),
        .library(name: "JobHunterCore", targets: ["JobHunterCore"]),
    ],
    targets: [
        // Models, API client, Keychain, new-job detection: no UI, fully unit-tested.
        .target(name: "JobHunterCore"),
        // SwiftUI app (bundled into JobHunter.app by scripts/build-app.sh).
        .executableTarget(name: "JobHunter", dependencies: ["JobHunterCore"]),
        .testTarget(
            name: "JobHunterCoreTests",
            dependencies: ["JobHunterCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
