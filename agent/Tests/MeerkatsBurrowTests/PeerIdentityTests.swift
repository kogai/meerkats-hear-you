import Foundation
import XCTest
@testable import MeerkatsBurrow

final class PeerIdentityTests: XCTestCase {
    func testRejectsWrongKeyLength() {
        XCTAssertNil(PeerIdentity(publicKey: Data()))
        XCTAssertNil(PeerIdentity(publicKey: Data(repeating: 0, count: 31)))
        XCTAssertNil(PeerIdentity(publicKey: Data(repeating: 0, count: 33)))
        XCTAssertNotNil(PeerIdentity(publicKey: Data(repeating: 0, count: 32)))
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
        XCTAssertFalse(identity.identifier.contains(Hex.string(identity.publicKey)))
        XCTAssertEqual(identity.identifier.count, 64, "SHA-256 の16進")
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
