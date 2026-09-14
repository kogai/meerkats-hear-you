import Foundation
import XCTest
@testable import MeerkatsBurrow

final class PairStoreTests: XCTestCase {
    private func identity() -> PeerIdentity { PairingKey().identity }

    func testAddAndLookUp() {
        var store = PairStore()
        let alice = identity()

        let outcome = store.add(alice, name: "Alice", wallUs: 100)
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(store.pair(for: alice)?.name, "Alice")
        XCTAssertEqual(store.pair(for: alice)?.pairedAtWallUs, 100)
        XCTAssertNil(store.pair(for: alice)?.lastConnectedWallUs, "まだ繋がっていない")
        XCTAssertEqual(store.count, 1)
    }

    /// 招待コードをもう一度貼っただけでは何も変わらない。
    func testAddingTheSameInviteAgainChangesNothing() {
        var store = PairStore()
        let alice = identity()
        store.add(alice, name: "Alice", wallUs: 100)

        let outcome = store.add(alice, name: "Alice", wallUs: 999)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(store.pair(for: alice)?.pairedAtWallUs, 100, "結んだ日は動かない")
        XCTAssertEqual(store.count, 1)
    }

    func testRenaming() {
        var store = PairStore()
        let alice = identity()
        store.add(alice, name: "Alice", wallUs: 100)

        let outcome = store.add(alice, name: "アリス", wallUs: 200)
        XCTAssertEqual(outcome, .renamed(from: "Alice"))
        XCTAssertEqual(store.pair(for: alice)?.name, "アリス")
        XCTAssertEqual(store.pair(for: alice)?.pairedAtWallUs, 100, "結んだ日は動かない")
    }

    /// **同じ名前で鍵が違うときは、何も変えずに返す。**
    ///
    /// 相手が機械を入れ替えた場面と、別人に同じ名前を付けた場面が、ここでは区別できない。
    /// 名前が一致しただけで古い対を消すと、後者で**別人の対が黙って消える。**
    /// どちらなのかを知っているのは利用者だけなので、判断を返す。
    func testNameCollisionChangesNothing() {
        var store = PairStore()
        let old = identity()
        let new = identity()
        store.add(old, name: "Alice", wallUs: 100)

        let outcome = store.add(new, name: "Alice", wallUs: 200)
        guard case let .nameTaken(taken) = outcome else {
            return XCTFail("名前の衝突として返っていない: \(outcome)")
        }
        XCTAssertEqual(taken.identity, old)
        XCTAssertEqual(store.count, 1, "新しい鍵は入っていない")
        XCTAssertNotNil(store.pair(for: old), "古い対も消えていない")
        XCTAssertNil(store.pair(for: new))
    }

    /// 切ってから結び直す、が「作り直す」の形(ADR-0017 決定5)。
    func testRemoveThenAddSucceeds() {
        var store = PairStore()
        let old = identity()
        let new = identity()
        store.add(old, name: "Alice", wallUs: 100)

        let removed = store.remove(old)
        XCTAssertEqual(removed?.identity, old)
        let outcome = store.add(new, name: "Alice", wallUs: 200)
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.pair(for: new)?.pairedAtWallUs, 200)
    }

    func testMarkConnected() {
        var store = PairStore()
        let alice = identity()
        store.add(alice, name: "Alice", wallUs: 100)

        store.markConnected(alice, wallUs: 500)
        XCTAssertEqual(store.pair(for: alice)?.lastConnectedWallUs, 500)
    }

    /// **切った相手が在庫の接続で復活しない。**
    ///
    /// 対を切ったあとに繋がりかけの接続が到着することがある。そこで対が戻っては、
    /// 切った意味が無くなる。
    func testMarkConnectedIgnoresUnknownPeers() {
        var store = PairStore()
        let alice = identity()
        store.add(alice, name: "Alice", wallUs: 100)
        store.remove(alice)

        store.markConnected(alice, wallUs: 500)
        XCTAssertTrue(store.isEmpty)
    }

    /// 並びは結んだ順。辞書の並びをそのまま出すと、起動のたびに変わる。
    func testOrderIsStable() {
        var store = PairStore()
        let first = identity()
        let second = identity()
        let third = identity()
        store.add(second, name: "B", wallUs: 200)
        store.add(third, name: "C", wallUs: 300)
        store.add(first, name: "A", wallUs: 100)

        XCTAssertEqual(store.all.map(\.name), ["A", "B", "C"])
    }

    /// 同じ時刻に結ばれた対でも並びが決まる。決めないと、同じ内容から違う並びが出る。
    func testOrderIsStableForTheSameInstant() {
        let left = identity()
        let right = identity()

        var one = PairStore()
        one.add(left, name: "L", wallUs: 100)
        one.add(right, name: "R", wallUs: 100)

        var other = PairStore()
        other.add(right, name: "R", wallUs: 100)
        other.add(left, name: "L", wallUs: 100)

        XCTAssertEqual(one.all, other.all)
    }

    func testRoundTripsThroughJSON() throws {
        var store = PairStore()
        let alice = identity()
        store.add(alice, name: "Alice", wallUs: 100)
        store.markConnected(alice, wallUs: 500)
        store.add(identity(), name: "Bob", wallUs: 200)

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(PairStore.self, from: data)

        XCTAssertEqual(decoded, store)
        XCTAssertEqual(decoded.all.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(decoded.pair(for: alice)?.lastConnectedWallUs, 500)
    }

    /// **壊れた鍵の入った保存を読み込んだら投げる。**
    ///
    /// 黙って読み飛ばすと、対が1つ減ったまま動き続けて、
    /// 「なぜか相手が一覧から消えた」という形で現れる。
    func testRejectsBrokenStoredKey() throws {
        var store = PairStore()
        store.add(identity(), name: "Alice", wallUs: 100)
        let data = try JSONEncoder().encode(store)

        var text = try XCTUnwrap(String(data: data, encoding: .utf8))
        // 32バイトの base64 を、明らかに短いものへ差し替える。
        let shortKey = Data(repeating: 0, count: 8).base64EncodedString()
        let pattern = #""publicKey":"[^"]+""#
        text = text.replacingOccurrences(
            of: pattern,
            with: "\"publicKey\":\"\(shortKey)\"",
            options: .regularExpression
        )

        let broken = try XCTUnwrap(text.data(using: .utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(PairStore.self, from: broken))
    }
}
