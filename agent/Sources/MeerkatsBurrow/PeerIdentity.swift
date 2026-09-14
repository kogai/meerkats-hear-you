import CryptoKit
import Foundation

/// 相手の身元。**公開鍵そのもの**である(ADR-0017)。
///
/// 公開鍵は招待コードで手渡しされ、ランデブーを通らない。したがって
/// 「この鍵は本当にこの人のものか」を確かめる手順は要らない。**渡ってきた経路が答えである。**
public struct PeerIdentity: Equatable, Hashable {
    /// Curve25519 の公開鍵。32バイト。
    public let publicKey: Data

    /// **長さだけでは足りない。**
    ///
    /// 32バイトなら何でも通していたが、通してはいけないバイト列が2種類ある。
    /// どちらも `identifier` の一意性、つまりこの型の存在理由そのものを壊す。
    public init?(publicKey: Data) {
        guard publicKey.count == PeerIdentity.publicKeyBytes else { return nil }
        let bytes = [UInt8](publicKey)
        guard PeerIdentity.isCanonical(bytes) else { return nil }
        guard !PeerIdentity.lowOrderPoints.contains(bytes) else { return nil }
        self.publicKey = publicKey
    }

    public static let publicKeyBytes = 32

    /// **同じ鍵を表すバイト列が複数あってはいけない。**
    ///
    /// Curve25519 の公開鍵は p = 2^255 - 19 未満の数をリトルエンディアンに置いたもの。
    /// 最上位ビットを立てたバイト列と、p 以上の値のバイト列は、RFC 7748 §5 が
    /// 演算の前にマスクと剰余を取るので**鍵合意では同じ相手になる。**
    /// しかし SHA-256 は別の値を出す。
    ///
    /// 通すと何が起きるか。相手は自分の正規形から `identifier` を計算して名刺を預ける。
    /// こちらは非正規形から別の `identifier` を計算して、そこを見に行く。**永久に見つからない。**
    /// 鍵合意は通る形なので「鍵が違う」とも出ない。ADR-0009 が最悪と書いた
    /// 「黙って繋がらない」に、検出手段のないまま落ちる。
    ///
    /// 正しい鍵がこの形になることは無い。u < p なので最上位ビットは必ず 0 である。
    /// したがって**弾いてよい。** 正規形へ直して受け入れると、送った側が作っていない
    /// コードを受け入れることになり、壊れたコードが黙って通る。
    private static func isCanonical(_ bytes: [UInt8]) -> Bool {
        guard bytes[31] & 0x80 == 0 else { return false }
        // 最上位ビットが 0 で p 以上になるのは p ... 2^255-1 の19個だけ。
        guard bytes[31] == 0x7F, bytes[1 ... 30].allSatisfy({ $0 == 0xFF }) else { return true }
        return bytes[0] < 0xED
    }

    /// **位数の小さい点は、鍵合意が必ず失敗する。**
    ///
    /// 共有秘密が全ゼロになるため、RFC 7748 §6.1 の検査に引っかかって CryptoKit が投げる。
    /// 通すと、**指紋も出るし対も作れるのに絶対に繋がらない招待コード**ができる。
    /// 繋がらない理由は利用者からは何も見えない。
    ///
    /// 正規形は5つしかないので、そのまま並べる(p, p+1 は `isCanonical` が先に弾く)。
    private static let lowOrderPoints: Set<[UInt8]> = [
        // 0 — 位数1
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        // 1 — 位数4
        [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        // 位数8
        [0xE0, 0xEB, 0x7A, 0x7C, 0x3B, 0x41, 0xB8, 0xAE,
         0x16, 0x56, 0xE3, 0xFA, 0xF1, 0x9F, 0xC4, 0x6A,
         0xDA, 0x09, 0x8D, 0xEB, 0x9C, 0x32, 0xB1, 0xFD,
         0x86, 0x62, 0x05, 0x16, 0x5F, 0x49, 0xB8, 0x00],
        // 位数8
        [0x5F, 0x9C, 0x95, 0xBC, 0xA3, 0x50, 0x8C, 0x24,
         0xB1, 0xD0, 0xB1, 0x55, 0x9C, 0x83, 0xEF, 0x5B,
         0x04, 0x44, 0x5C, 0xC4, 0x58, 0x1C, 0x8E, 0x86,
         0xD8, 0x22, 0x4E, 0xDD, 0xD0, 0x9F, 0x11, 0x57],
        // p-1 — 位数2
        [0xEC, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
         0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
         0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
         0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F],
    ]

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
    public static let fingerprintBytes = 8

    public var fingerprint: String {
        // **文字ではなくバイトで区切る。** 文字で数えて4文字ずつ進めると、
        // `fingerprintBytes` が奇数になった瞬間に最後の `index(_:offsetBy:)` が
        // 範囲を越えて実行時に落ちる。バイトで区切れば端数は短い組になるだけで済む。
        let digest = Array(SHA256.hash(data: publicKey).prefix(PeerIdentity.fingerprintBytes))
        return stride(from: 0, to: digest.count, by: 2)
            .map { Hex.string(digest[$0 ..< min($0 + 2, digest.count)]) }
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
        // Curve25519 が作る鍵は 32 バイトの正規形で、位数の小さい点でもないので、
        // ここで落ちることはない。それでも `!` を書かないのは、
        // 落ちたときに何も分からなくなるためである。
        guard let identity = PeerIdentity(publicKey: privateKey.publicKey.rawRepresentation) else {
            preconditionFailure("Curve25519 の公開鍵が身元として通らない")
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
