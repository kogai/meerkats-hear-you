// swift-tools-version:5.9
import PackageDescription

// MeerkatsCore は AVFoundation に依存しない純粋ロジックのみを置く。
// 音声キャプチャは実機でしか動かせないため、検証できる部分をここに寄せている。
//
// MeerkatsSentry は実機依存の薄いシェル。見張り(ADR-0011)。AVAudioEngine・AppKit・SwiftUI に触れるのはこちらだけで、
// 判断は持たない。CIでビルドと署名までは確かめられるが、マイクを伴う動作は実機でしか確認できない。
let package = Package(
    name: "Meerkats",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MeerkatsCore"),
        .executableTarget(name: "MeerkatsSentry", dependencies: ["MeerkatsCore"]),
        .testTarget(name: "MeerkatsCoreTests", dependencies: ["MeerkatsCore"]),
    ]
)
