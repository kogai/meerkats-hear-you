import CryptoKit
import Foundation

/// 対を結ぶために手渡しするコード(ADR-0017 決定1)。
///
/// **公開鍵そのものを載せる。** 鍵が手渡しの経路だけを通るので、ランデブーは取り違えようがなく、
/// 受け取った側が指紋を突き合わせる作業も要らない。
///
/// 載せないもの。
///
/// - **相手の名前。** 受け取った側が誰から貰ったかを知っているので、そちらで名付ける。
///   コードに入れると、貰った経路と食い違う名前が並ぶ余地を作るだけになる
/// - **ランデブーの宛先。** 導入ごとの設定であって、相手ごとのものではない
public enum InviteCode {
    /// 先頭の目印。末尾の数字は形式の版で、変えるときはここを上げる。
    public static let prefix = "meerkats1:"

    /// 貼り間違いを捕まえるための検査値。公開鍵のハッシュの先頭。
    static let checksumBytes = 4

    public enum DecodeError: Error, Equatable {
        case wrongPrefix
        case notBase64
        case wrongLength(Int)
        /// 長さは合っているが中身が壊れている。**1文字の書き換えはここでしか捕まらない。**
        case checksumMismatch
    }

    public static func encode(_ identity: PeerIdentity) -> String {
        var payload = identity.publicKey
        payload.append(contentsOf: checksum(for: identity.publicKey))
        return prefix + base64url(payload)
    }

    /// 貼られた文字列から相手の身元を取り出す。
    ///
    /// **壊れていたら必ず投げる。** 黙って違う鍵を受け入れると、繋がらない対ができて、
    /// しかも原因が分からない。ADR-0009 が「黙って繋がらないことは特に悪い」と書いた形になる。
    public static func decode(_ text: String) throws -> PeerIdentity {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { throw DecodeError.wrongPrefix }

        let body = String(trimmed.dropFirst(prefix.count))
        guard let payload = data(fromBase64url: body) else { throw DecodeError.notBase64 }

        let expected = PeerIdentity.publicKeyBytes + checksumBytes
        guard payload.count == expected else { throw DecodeError.wrongLength(payload.count) }

        let key = Data(payload.prefix(PeerIdentity.publicKeyBytes))
        let tail = Array(payload.suffix(checksumBytes))
        // **長さの検査だけでは足りない。** 切れたコードは長さで捕まるが、
        // 1文字だけ書き換わったコードは同じ長さの別の鍵になって通ってしまう。
        guard tail == checksum(for: key) else { throw DecodeError.checksumMismatch }

        guard let identity = PeerIdentity(publicKey: key) else {
            throw DecodeError.wrongLength(key.count)
        }
        return identity
    }

    static func checksum(for publicKey: Data) -> [UInt8] {
        Array(SHA256.hash(data: publicKey).prefix(checksumBytes))
    }

    /// 貼って運ぶので、URLに入れても壊れない字だけを使う。
    /// 詰めの `=` も落とす。チャットや表計算を経由すると落ちることがあり、
    /// 落ちた形でも読めるようにしておくほうが安い。
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(fromBase64url text: String) -> Data? {
        var restored = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while restored.count % 4 != 0 {
            restored.append("=")
        }
        return Data(base64Encoded: restored)
    }
}
