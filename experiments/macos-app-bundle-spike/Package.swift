// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LevelSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LevelSpike", path: "Sources/LevelSpike")
    ]
)
