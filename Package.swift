// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AudioCapture",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "AudioCapture",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            resources: [
                .process("PrivacyInfo.xcprivacy"),
                .process("Assets.xcassets"),
                .process("AppIcon.icns")
            ]
        )
    ]
)
