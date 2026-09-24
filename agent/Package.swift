// swift-tools-version:5.9
import PackageDescription

// MeerkatsCore は AVFoundation に依存しない純粋ロジックのみを置く。
// 音声キャプチャは実機でしか動かせないため、検証できる部分をここに寄せている。
//
// MeerkatsBurrow は名刺の交換(ADR-0011)。CryptoKit にしか依存せず、AVFoundation にも
// 音声にも触れないので、判断はCIで検証できる。ネットワークを持つのは後の段階で、
// そこは実機でしか確かめられない。
//
// MeerkatsSentry は実機依存の薄いシェル。見張り(ADR-0011)。AVAudioEngine・AppKit・SwiftUI に触れるのはこちらだけで、
// 判断は持たない。CIでビルドと署名までは確かめられるが、マイクを伴う動作は実機でしか確認できない。
let package = Package(
    name: "Meerkats",
    // 14.4 は Core Audio のプロセスタップが入った版(ADR-0008)。受信音声の取得に要る。
    // 13.0 だった下限は ScreenCaptureKit が音声に対応した版に合わせたもので、
    // その手段を採らないと決めた時点で維持する理由が無くなっている。
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "MeerkatsCore"),
        .target(name: "MeerkatsBurrow"),
        .executableTarget(name: "MeerkatsSentry", dependencies: ["MeerkatsCore"]),
        .testTarget(name: "MeerkatsCoreTests", dependencies: ["MeerkatsCore"]),
        .testTarget(name: "MeerkatsBurrowTests", dependencies: ["MeerkatsBurrow"]),
    ]
)
