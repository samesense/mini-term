// swift-tools-version: 6.2
import PackageDescription

// The transport is independently buildable/testable without the iOS SDK or Ghostty binary.
let package = Package(
    name: "MiniTermCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MiniTermCore", targets: ["MiniTermCore"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0"),
    ],
    targets: [
        .target(name: "MiniTermCore", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "MiniTermCoreTests", dependencies: ["MiniTermCore",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
