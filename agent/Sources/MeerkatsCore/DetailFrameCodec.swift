import Foundation

/// 詳細層のフレーム列をパック配列に符号化する(ADR-0004)。
///
/// 詳細層は常に「その異常区間をまるごと取り出す」としか読まれず、フレーム単位で条件検索する
/// 場面が無い。行として持ってもSQLの利点が働かないまま行数とインデックスの負担だけが残るため、
/// BLOBに収める。10秒の区間で比較すると約30KBが約2.5KBになる。
///
/// 代償として、フォーマットはスキーマの外側の取り決めになる。1フレームあたりのバイト数を
/// 変える変更は過去のデータを読めなくするため、`version` を先頭に置いて識別できるようにしてある。
public enum DetailFrameCodec {
    public static let version: UInt8 = 1
    /// Float32のdBFS(4バイト) + フラグ(1バイト)
    public static let bytesPerFrame = 5
    private static let headerSize = 1

    private struct Flags {
        static let speech: UInt8 = 1 << 0
        static let clipped: UInt8 = 1 << 1
    }

    /// フレームの時刻は符号化しない。等間隔であることを前提に、
    /// 区間の開始時刻とフレーム長から復元する。
    public static func encode(_ frames: [FrameMetrics]) -> Data {
        var data = Data(capacity: headerSize + frames.count * bytesPerFrame)
        data.append(version)

        for frame in frames {
            var level = Float32(frame.dbfs).bitPattern.littleEndian
            withUnsafeBytes(of: &level) { data.append(contentsOf: $0) }

            var flags: UInt8 = 0
            if frame.isSpeech { flags |= Flags.speech }
            // クリップは詳細層では有無のみ。比率は常時層が1秒平均として保持している。
            if frame.clipRatio > 0 { flags |= Flags.clipped }
            data.append(flags)
        }
        return data
    }

    public enum DecodeError: Error, Equatable {
        case empty
        case unsupportedVersion(UInt8)
        case truncated(byteCount: Int)
    }

    /// - Parameters:
    ///   - startUs: 区間の先頭フレームの単調時刻
    ///   - frameDurationUs: フレーム長(マイクロ秒)
    public static func decode(
        _ data: Data,
        startUs: Int64,
        frameDurationUs: Int64
    ) throws -> [FrameMetrics] {
        guard let first = data.first else { throw DecodeError.empty }
        guard first == version else { throw DecodeError.unsupportedVersion(first) }

        let payload = data.dropFirst(headerSize)
        guard payload.count % bytesPerFrame == 0 else {
            throw DecodeError.truncated(byteCount: payload.count)
        }

        let bytes = [UInt8](payload)
        var frames: [FrameMetrics] = []
        frames.reserveCapacity(bytes.count / bytesPerFrame)

        for index in stride(from: 0, to: bytes.count, by: bytesPerFrame) {
            // リトルエンディアンのバイト列から組み立てた時点でネイティブの値になっている。
            // ここでさらに UInt32(littleEndian:) を通すと二重変換になる。
            let bits = UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            let level = Double(Float32(bitPattern: bits))
            let flags = bytes[index + 4]

            frames.append(
                FrameMetrics(
                    monotonicUs: startUs + Int64(index / bytesPerFrame) * frameDurationUs,
                    dbfs: level,
                    clipRatio: (flags & Flags.clipped) != 0 ? 1 : 0,
                    isSpeech: (flags & Flags.speech) != 0
                )
            )
        }
        return frames
    }
}
