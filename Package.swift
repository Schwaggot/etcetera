// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "etcetera",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "EtcdKit", targets: ["EtcdKit"]),
        .library(name: "EtcdSchema", targets: ["EtcdSchema"]),
        .library(name: "EtceteraCore", targets: ["EtceteraCore"]),
        .executable(name: "etcetera-cli", targets: ["etcetera-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")
    ],
    targets: [
        .target(name: "EtcdKit", resources: [.process("Localizable.xcstrings")]),
        .target(
            name: "EtcdSchema",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            resources: [.process("Localizable.xcstrings")]
        ),
        // The application's models and logic without any UI, so they are
        // testable with `swift test`. Views live in App/.
        .target(
            name: "EtceteraCore", dependencies: ["EtcdKit", "EtcdSchema"],
            resources: [.process("Localizable.xcstrings")]
        ),
        .executableTarget(name: "etcetera-cli", dependencies: ["EtcdKit"]),
        .testTarget(
            name: "EtcdKitTests",
            dependencies: ["EtcdKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "EtcdSchemaTests",
            dependencies: ["EtcdSchema"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "EtceteraCoreTests",
            dependencies: [
                "EtceteraCore", "EtcdKit", "EtcdSchema", .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
    ]
)
