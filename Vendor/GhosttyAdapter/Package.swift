// swift-tools-version: 6.2
import PackageDescription

// Pinned Swift UI wrapper, with narrow host input hooks. The engine binary and
// HID-to-Ghostty translation still come from the same upstream release.
let package = Package(
    name: "MiniTermGhosttyAdapter",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MiniTermGhosttyTerminal", targets: ["MiniTermGhosttyTerminal"])],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026102101"),
        .package(url: "https://github.com/Lakr233/DisplayLink.git", from: "3.0.1"),
    ],
    targets: [.target(
        name: "MiniTermGhosttyTerminal",
        dependencies: [.product(name: "GhosttyKit", package: "libghostty-spm"), "DisplayLink"],
        path: "Sources/GhosttyTerminal",
        resources: [.copy("Resources/Ghostty"), .copy("Resources/terminfo"), .process("Resources/Localization")],
        swiftSettings: [
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("ExistentialAny"),
        ]
    )],
    swiftLanguageModes: [.v6]
)
