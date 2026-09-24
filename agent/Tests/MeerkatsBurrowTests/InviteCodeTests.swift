import Foundation
import XCTest
@testable import MeerkatsBurrow

final class InviteCodeTests: XCTestCase {
    private func makeIdentity() -> PeerIdentity {
        PairingKey().identity
    }

    func testRoundTrip() throws {
        let identity = makeIdentity()
        let decoded = try InviteCode.decode(InviteCode.encode(identity))
        XCTAssertEqual(decoded, identity)
    }

    /// 貼るときに前後の空白や改行が付く。**それで落ちては使えない。**
    func testTolerantOfSurroundingWhitespace() throws {
        let identity = makeIdentity()
        let code = InviteCode.encode(identity)
        XCTAssertEqual(try InviteCode.decode("  \n\(code)\n  "), identity)
    }

    func testRejectsWrongPrefix() {
        let code = InviteCode.encode(makeIdentity())
        let mangled = String(code.dropFirst(InviteCode.prefix.count))
        XCTAssertThrowsError(try InviteCode.decode(mangled)) { error in
            XCTAssertEqual(error as? InviteCode.DecodeError, .wrongPrefix)
        }
    }

    /// **切れたコードは長さで捕まる。**
    func testRejectsTruncated() {
        let code = InviteCode.encode(makeIdentity())
        XCTAssertThrowsError(try InviteCode.decode(String(code.dropLast(8)))) { error in
            guard let decodeError = error as? InviteCode.DecodeError else {
                XCTFail("別の誤りとして投げられている: \(error)")
                return
            }
            guard case .wrongLength = decodeError else {
                XCTFail("長さの誤りとして捕まっていない: \(decodeError)")
                return
            }
        }
    }

    /// **1文字だけ書き換わったコードは、長さでは捕まらない。**
    ///
    /// 同じ長さの別の鍵になって通ってしまうので、検査値がここで効く。
    /// 通ると、繋がらない対ができて、しかも原因が分からない。
    func testRejectsSingleCharacterSubstitution() {
        let code = InviteCode.encode(makeIdentity())
        // 本体の真ん中を1文字だけ別の base64url 文字に差し替える。
        let bodyStart = code.index(code.startIndex, offsetBy: InviteCode.prefix.count)
        let target = code.index(bodyStart, offsetBy: 10)
        let original = code[target]
        let replacement: Character = original == "A" ? "B" : "A"
        var mangled = code
        mangled.replaceSubrange(target ... target, with: String(replacement))

        XCTAssertThrowsError(try InviteCode.decode(mangled)) { error in
            XCTAssertEqual(error as? InviteCode.DecodeError, .checksumMismatch)
        }
    }

    func testRejectsNonBase64() {
        XCTAssertThrowsError(try InviteCode.decode(InviteCode.prefix + "これは base64 ではない")) {
            error in
            XCTAssertEqual(error as? InviteCode.DecodeError, .notBase64)
        }
    }

    /// 詰めの `=` を含まない。チャットや表計算を経由すると落ちることがあるので、
    /// **最初から出さない。**
    func testCarriesNoPadding() {
        XCTAssertFalse(InviteCode.encode(makeIdentity()).contains("="))
    }

    /// 貼って運ぶ長さであることを確かめる。公開鍵32バイト + 検査値4バイトで、
    /// base64url にすると48文字。目印を足して58文字になる。
    func testLength() {
        XCTAssertEqual(InviteCode.encode(makeIdentity()).count, InviteCode.prefix.count + 48)
    }

    /// 任意のバイト列から、**検査値の揃った**招待コードを組み立てる。
    ///
    /// 検査値は鍵から計算するので、使えない鍵を載せてもそこは揃ってしまう。
    /// 検査値では止まらないことを示すために、`encode` を通さず組み立てる。
    private func invite(carrying key: Data) -> String {
        var payload = key
        payload.append(contentsOf: InviteCode.checksum(for: key))
        let body = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return InviteCode.prefix + body
    }

    /// **同じ人の鍵が、2つめの身元として通らない。**
    ///
    /// 最上位ビットを立てた鍵は鍵合意では同じ相手になるが、識別子は別物になる。
    /// 通すと、名刺を探す先が相手の預けた先と食い違い、**永久に繋がらない。**
    /// しかも鍵合意は通る形なので、「鍵が違う」とは出ない。
    func testRejectsNonCanonicalKeyInAWellFormedCode() throws {
        let identity = makeIdentity()
        var altered = [UInt8](identity.publicKey)
        altered[31] |= 0x80

        XCTAssertThrowsError(try InviteCode.decode(invite(carrying: Data(altered)))) { error in
            XCTAssertEqual(error as? InviteCode.DecodeError, .unusableKey, "検査値では止まらない")
        }
        // 同じ組み立て方で、正規形のほうは通る。
        XCTAssertEqual(try InviteCode.decode(invite(carrying: identity.publicKey)), identity)
    }

    /// **絶対に繋がらない招待コードを、対にできる形で通さない。**
    func testRejectsLowOrderKeyInAWellFormedCode() {
        XCTAssertThrowsError(try InviteCode.decode(invite(carrying: Data(repeating: 0, count: 32)))) { error in
            XCTAssertEqual(error as? InviteCode.DecodeError, .unusableKey)
        }
    }
}
