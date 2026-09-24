// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SampleTimeSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SampleTimeSpike", path: "Sources/SampleTimeSpike")
    ]
)
