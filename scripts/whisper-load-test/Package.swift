// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperLoadTest",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "WhisperKit", path: "/Users/sichengyu/Documents/Github/TransFlow/.local-packages/WhisperKit")
    ],
    targets: [
        .executableTarget(name: "WhisperLoadTest", dependencies: ["WhisperKit"], path: ".")
    ]
)
