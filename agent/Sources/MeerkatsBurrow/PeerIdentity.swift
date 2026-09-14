import CryptoKit
import Foundation

/// 相手の身元。**公開鍵そのもの**である(ADR-0017)。
///
/// 公開鍵は招待コードで手渡しされ、ランデブーを通らない。したがって
/// 「この鍵は本当にこの人のものか」を確かめる手順は要らない。**渡ってきた経路が答えである。**
public struct PeerIdentity: Equatable, Hashable {
    /// Curve25519 の公開鍵。32バイト。
    public let publicKey: Data

    public init?(publicKey: Data) {
        guard publicKey.count == PeerIdentity.publicKeyBytes else { return nil }
        self.publicKey = publicKey
    }

    public static let publicKeyBytes = 32

    /// ランデブーに預ける名刺を引くための値(ADR-0017 決定3)。
    ///
    /// **公開鍵そのものは預けない。** ハッシュなので、ランデブーはこれから鍵を復元できない。
    /// 誰と誰が繋いでいるかは見えるが(元々見えている)、鍵は見えない。
    ///
    /// 相手は招待コードで得た鍵から同じ値を計算し、それで自分あての名刺を見つける。
    public var identifier: String {
        Hex.string(SHA256.hash(data: publicKey))
    }

    /// 一覧に出すための短い表示(ADR-0017 決定4)。
    ///
    /// **突き合わせのためではない。** 鍵は手渡しで届くので、人が比べる作業は無い。
    /// 要るのは「どの鍵で誰と対になっているか」を一覧で見分けることと、
    /// 変わったときに気づけることの2つで、どちらも能動的に比べる作業ではない。
    ///
    /// **したがって、これは安全の境界ではない。** 8バイトに切り詰めてあるのは、
    /// 一覧で5人ぶん並べたときに見分けられれば足りるからである。
    /// 鍵の正しさをこの値で判断してはいけない。
    ///
    /// 16進にしてあるのは、等幅で並べたときに字形が紛れないためである。
    /// 4文字ごとに区切るのは、目で追う単位を作るため。
    public var fingerprint: String {
        let digest = Array(SHA256.hash(data: publicKey).prefix(8))
        let hex = Hex.string(digest)
        return stride(from: 0, to: hex.count, by: 4)
            .map { offset -> String in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                let end = hex.index(start, offsetBy: 4)
                return String(hex[start ..< end])
            }
            .joined(separator: "-")
    }
}

/// 自分の鍵。秘密鍵を持つのはこれだけ。
public struct PairingKey {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    /// 新しい鍵を作る。
    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// 保存してあった鍵を読み直す。
    public init(rawPrivateKey: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    /// **保存する側が鍵束へ入れる。** ここでは置き場所を決めない。
    public var rawPrivateKey: Data { privateKey.rawRepresentation }

    /// 相手へ渡す側。
    public var identity: PeerIdentity {
        // 32バイトであることは Curve25519 が保証するので、ここで落ちることはない。
        // それでも `!` を書かないのは、落ちたときに何も分からなくなるためである。
        guard let identity = PeerIdentity(publicKey: privateKey.publicKey.rawRepresentation) else {
            preconditionFailure("Curve25519 の公開鍵が 32 バイトではない")
        }
        return identity
    }
}

/// 16進の文字列化。
///
/// **`String(format:)` を使わない。** `%02X` は unsigned int を期待するので、
/// `UInt8` を可変長引数で渡すと昇格の規則に寄りかかることになる。
/// 表に引くだけで済むところで、その依存を作る理由が無い。
enum Hex {
    private static let digits = Array("0123456789ABCDEF")

    static func string<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out = ""
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }
}
