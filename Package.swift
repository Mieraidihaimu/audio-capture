// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AudioCapture",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")
    ],
    targets: [
        .executableTarget(
            name: "AudioCapture",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: "Sources"
        )
    ]
)
