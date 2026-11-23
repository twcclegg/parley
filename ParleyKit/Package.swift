// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParleyKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "ParleyCore", targets: ["ParleyCore"]),
        .library(name: "ParleySSH", targets: ["ParleySSH"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.2"),
    ],
    targets: [
        // The Claude Code stream-json protocol and the transcript built from it. No UI, no network.
        .target(name: "ParleyCore"),
        // A small SSH client over Apple's swift-nio-ssh: connect, authenticate, run one command
        // with its stdin and stdout as byte streams.
        .target(
            name: "ParleySSH",
            dependencies: [
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .testTarget(
            name: "ParleyCoreTests",
            dependencies: ["ParleyCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
