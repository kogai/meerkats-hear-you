import Foundation
import XCTest
@testable import MeerkatsBurrow

final class PeerIdentityTests: XCTestCase {
    func testRejectsWrongKeyLength() {
        XCTAssertNil(PeerIdentity(publicKey: Data()))
        XCTAssertNil(PeerIdentity(publicKey: Data(repeating: 0, count: 31)))
        XCTAssertNil(PeerIdentity(publicKey: Data(repeating: 0, count: 33)))
    }

    /// **同じ鍵が2つの身元として現れてはいけない。**
    ///
    /// 最上位ビットを立てたバイト列は、RFC 7748 §5 がマスクするので
    /// **鍵合意では同じ相手になる。** しかし SHA-256 は別の値を出すので、
    /// 通すと識別子が食い違って名刺が永久に見つからない。しかも鍵合意は通る形なので
    /// 「鍵が違う」とも出ない。
    func testRejectsNonCanonicalHighBit() {
        let valid = PairingKey().identity
        var altered = [UInt8](valid.publicKey)
        XCTAssertEqual(altered[31] & 0x80, 0, "正しい鍵の最上位ビットは必ず 0")
        altered[31] |= 0x80

        XCTAssertNil(PeerIdentity(publicKey: Data(altered)))
    }

    /// p 以上の値も同じ理由で弾く。剰余を取れば同じ点になるが、ハッシュは別物になる。
    func testRejectsValuesAtOrAboveThePrime() {
        // p = 2^255 - 19 をリトルエンディアンに置いたもの。
        var prime = [UInt8](repeating: 0xFF, count: 32)
        prime[0] = 0xED
        prime[31] = 0x7F
        XCTAssertNil(PeerIdentity(publicKey: Data(prime)), "p そのもの")

        var above = prime
        above[0] = 0xEE
        XCTAssertNil(PeerIdentity(publicKey: Data(above)), "p + 1")

        var below = prime
        below[0] = 0xEC
        XCTAssertNil(PeerIdentity(publicKey: Data(below)), "p - 1 は位数2の点")
    }

    /// **繋がらないと分かっている鍵を、対にできる形で通さない。**
    ///
    /// 位数の小さい点は共有秘密が全ゼロになり、鍵合意が必ず失敗する。
    /// 通すと、指紋も出るし対も作れるのに絶対に繋がらない招待コードができる。
    func testRejectsLowOrderPoints() {
        XCTAssertNil(PeerIdentity(publicKey: Data(repeating: 0, count: 32)), "全ゼロ")

        var one = [UInt8](repeating: 0, count: 32)
        one[0] = 0x01
        XCTAssertNil(PeerIdentity(publicKey: Data(one)))

        let orderEight = Data([
            0xE0, 0xEB, 0x7A, 0x7C, 0x3B, 0x41, 0xB8, 0xAE,
            0x16, 0x56, 0xE3, 0xFA, 0xF1, 0x9F, 0xC4, 0x6A,
            0xDA, 0x09, 0x8D, 0xEB, 0x9C, 0x32, 0xB1, 0xFD,
            0x86, 0x62, 0x05, 0x16, 0x5F, 0x49, 0xB8, 0x00,
        ])
        XCTAssertNil(PeerIdentity(publicKey: orderEight))
    }

    /// 本物の鍵は通る。上の3つの検査が広すぎないことを見る。
    func testAcceptsGeneratedKeys() {
        for _ in 0 ..< 50 {
            // `identity` の中で `init?` を通っているので、弾かれればここで落ちる。
            let identity = PairingKey().identity
            XCTAssertNotNil(PeerIdentity(publicKey: identity.publicKey))
        }
    }

    func testIdentifierIsStable() {
        let identity = PairingKey().identity
        XCTAssertEqual(identity.identifier, identity.identifier)
        XCTAssertNotEqual(identity.identifier, PairingKey().identity.identifier)
    }

    /// **識別子から鍵を復元できない**(ADR-0017 決定3)。
    ///
    /// ランデブーが預かるのはこちらで、公開鍵ではない。鍵をそのまま置いていないことを、
    /// 「識別子の中に鍵の16進が現れない」という形で確かめる。
    func testIdentifierDoesNotCarryTheKey() {
        let identity = PairingKey().identity
        let keyHex = Hex.string(identity.publicKey)
        XCTAssertEqual(identity.identifier.count, 64, "SHA-256 の16進")

        // **`contains` だけでは足りない。** 識別子も鍵の16進も64文字なので、
        // 「含む」は実質「一致する」しか見ていない。並べ替えただけの実装
        // (鍵をそのまま逆順にするなど)が緑のまま通ってしまう。
        // 鍵が復元できないことを見たいので、**文字の多重集合が違う**ことまで見る。
        XCTAssertNotEqual(identity.identifier.sorted(), keyHex.sorted())
    }

    /// 一覧に並べるための形。4文字ずつ4組。
    func testFingerprintShape() {
        let fingerprint = PairingKey().identity.fingerprint
        let groups = fingerprint.split(separator: "-")
        XCTAssertEqual(groups.count, 4)
        XCTAssertTrue(groups.allSatisfy { $0.count == 4 })
        XCTAssertTrue(fingerprint.allSatisfy { "0123456789ABCDEF-".contains($0) })
    }

    /// 指紋と識別子が別々のものから作られていないことを確かめる。
    /// **別々だと、一覧の指紋とランデブーの識別子が食い違っても誰も気づけない。**
    func testFingerprintIsThePrefixOfTheIdentifier() {
        let identity = PairingKey().identity
        let flattened = identity.fingerprint.replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(flattened, String(identity.identifier.prefix(16)))
    }

    func testPrivateKeyRoundTrip() throws {
        let key = PairingKey()
        let reloaded = try PairingKey(rawPrivateKey: key.rawPrivateKey)
        XCTAssertEqual(reloaded.identity, key.identity)
    }

    func testRejectsBrokenPrivateKey() {
        XCTAssertThrowsError(try PairingKey(rawPrivateKey: Data(repeating: 0, count: 8)))
    }
}
