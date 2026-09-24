// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NATBehaviourSpike",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NATBehaviourSpike", path: "Sources/NATBehaviourSpike")
    ]
)
