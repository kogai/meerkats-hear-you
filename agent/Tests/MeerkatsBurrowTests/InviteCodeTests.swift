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
}
