// swift-tools-version:5.9
import PackageDescription

// MeerkatsCore は AVFoundation に依存しない純粋ロジックのみを置く。
// 音声キャプチャは実機でしか動かせないため、検証できる部分をここに寄せている。
let package = Package(
    name: "Meerkats",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MeerkatsCore"),
        .testTarget(name: "MeerkatsCoreTests", dependencies: ["MeerkatsCore"]),
    ]
)
