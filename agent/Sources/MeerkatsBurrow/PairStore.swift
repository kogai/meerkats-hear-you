import Foundation

/// 結んだ対の一覧。
///
/// ADR-0017 決定5 の Trust On First Use をここに置く。ただし ADR-0009 の想定とは
/// **効く場所が違う。**
///
/// ADR-0009 は「ランデブーから届いた鍵が前と変わっていたら警告する」形を想定していた。
/// ADR-0017 で鍵が招待コードだけを通るようになったので、**ランデブーが鍵を取り違えて
/// 配る経路が無くなった。** 識別子は鍵から導くので、鍵が変われば識別子も変わり、
/// 別の相手として現れる。
///
/// **招待コードが通る経路そのものは、信頼している。** ADR-0017 は指紋の突き合わせを
/// 意図的に外した(飛ばされる手順を残さない、という判断であって、差し替えが起きないと
/// いう判断ではない)。検査値は鍵から計算し直せるので、コードを丸ごと差し替えられた場合は
/// 通る。最初に対を結ぶ時点で差し替えられていれば、TOFU には比べる相手が無く検出できない。
///
/// したがって、ここで「変わった」と分かるのは**名前が同じで鍵が違うとき**だけになる。
/// 相手が機械を入れ替えて新しい招待コードを寄こした、という場面である。
public struct PairStore: Equatable, Codable {
    /// 識別子から引く。並びは保存しない(`all` が決める)。
    private var pairs: [String: Pair]

    public init() {
        pairs = [:]
    }

    // MARK: - 保存

    /// **辞書ではなく並びとして保存する。**
    ///
    /// 辞書のまま符号化すると、鍵(識別子)と値の中の `identity` が独立に書ける。
    /// 識別子は公開鍵から導ける値なので、2か所に書くと食い違いうる。食い違った保存を
    /// 読むと、`all` と `count` には出ているのに `pair(for:)` では引けない対が残る。
    /// `remove` も辞書の鍵と一致しないので**利用者が切ろうとしても切れず**、
    /// `markConnected` は黙って捨てるので「最後に繋がったのはいつか」が永久に空になる。
    ///
    /// 導ける値を書かなければ、食い違いようがない。読むときに鍵から組み直す。
    public init(from decoder: Decoder) throws {
        let list = try decoder.singleValueContainer().decode([Pair].self)
        pairs = [:]
        for pair in list {
            guard pairs.updateValue(pair, forKey: pair.identity.identifier) == nil else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "同じ鍵の対が2つある: \(pair.identity.fingerprint)"
                    )
                )
            }
        }
    }

    /// `all` の順で書き出す。**同じ内容なら同じファイルになる。**
    /// 辞書の並びで書くと、中身が変わっていなくても保存のたびに差分が出る。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(all)
    }

    /// `add` で何が起きたか。
    public enum Outcome: Equatable {
        /// 新しい対を結んだ。
        case created
        /// 同じ鍵・同じ名前。招待コードをもう一度貼っただけ。何も変えていない。
        case unchanged
        /// 同じ鍵で名前だけ変えた。
        case renamed(from: String)
        /// **同じ名前が、別の鍵で既にある。何も変えていない。**
        ///
        /// 相手が機械を入れ替えた場面がこれにあたる。古い対は二度と繋がらないので
        /// 切るのが正しい(ADR-0017 決定5)が、**ここでは切らない。**
        ///
        /// 名前は利用者が付けたもので、別人に同じ名前を付けることがある。
        /// 名前が一致しただけで古い対を消すと、**別人の対が黙って消える。**
        /// どちらなのかを知っているのは利用者だけなので、判断を返す。
        /// 切ると決めたら `remove` を呼んでから、もう一度 `add` する。
        case nameTaken(by: Pair)
        /// **名前が空。何も変えていない。**
        ///
        /// 通すと一覧に無名の行が出る。そのあと別の鍵を無名で足すと `nameTaken` が返り、
        /// 利用者には**何と衝突したのかが見えない。**
        case emptyName
    }

    /// 招待コードから取り出した身元で対を結ぶ。
    ///
    /// **`nameTaken` のときは何も変えない。** 呼び出し側が決めるまで、
    /// 古い対も新しい鍵も、どちらも失われない状態で止める。
    @discardableResult
    public mutating func add(
        _ identity: PeerIdentity,
        name: String,
        wallUs: Int64
    ) -> Outcome {
        // **前後の空白を落とす。** チャットから貼った名前には末尾の空白が付くことがあり、
        // 落とさないと "Alice " と "Alice" が別の名前になって、
        // **一覧に見た目の区別が付かない行が2つ並ぶ。**
        // `InviteCode.decode` が貼られたコードに対して同じことをしている。
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .emptyName }

        if let existing = pairs[identity.identifier] {
            guard existing.name != name else { return .unchanged }
            // **改名でも名前の衝突を見る。** ここを素通りさせると、鍵が既にある経路だけが
            // 検査を抜けて、一覧に同じ名前が2つ並ぶ。並んだあとは
            // `nameTaken(by:)` がどちらを指すかが辞書の並び順で決まり、
            // 起動のたびに変わる。
            if let taken = other(named: name, than: identity) { return .nameTaken(by: taken) }
            // **`pairedAtWallUs` は更新しない。** いつ結んだかは、結んだ日のままが正しい。
            pairs[identity.identifier] = Pair(
                identity: existing.identity,
                name: name,
                pairedAtWallUs: existing.pairedAtWallUs,
                lastConnectedWallUs: existing.lastConnectedWallUs
            )
            return .renamed(from: existing.name)
        }

        if let taken = other(named: name, than: identity) { return .nameTaken(by: taken) }

        pairs[identity.identifier] = Pair(
            identity: identity, name: name, pairedAtWallUs: wallUs
        )
        return .created
    }

    /// その名前を使っている**別の**対。
    ///
    /// `all` の順に見る。同じ内容の保存から**毎回同じ対を返す**ようにするため。
    /// 辞書の並び順に頼ると、`String` のハッシュは起動ごとに種が変わるので、
    /// 「その名前は指紋 XXXX-… が使っています」の指紋が回によって変わる。
    private func other(named name: String, than identity: PeerIdentity) -> Pair? {
        all.first { $0.name == name && $0.identity != identity }
    }

    @discardableResult
    public mutating func remove(_ identity: PeerIdentity) -> Pair? {
        pairs.removeValue(forKey: identity.identifier)
    }

    /// 繋がったことを記録する。ADR-0009 の「最後に繋がったのはいつか」の出どころ。
    ///
    /// **知らない相手は黙って捨てる。** 対を切ったあとに在庫の接続が繋がることがあり、
    /// そこで対が復活しては、切った意味が無くなる。
    public mutating func markConnected(_ identity: PeerIdentity, wallUs: Int64) {
        guard var pair = pairs[identity.identifier] else { return }
        pair.lastConnectedWallUs = wallUs
        pairs[identity.identifier] = pair
    }

    public func pair(for identity: PeerIdentity) -> Pair? {
        pairs[identity.identifier]
    }

    /// 表示のための一覧。**結んだ順に返す。**
    ///
    /// 辞書の並びをそのまま出すと、起動のたびに順序が変わって、どれが増えたのかを
    /// 目で追えなくなる。同じ時刻に結ばれた対の並びまで決めておくのは、
    /// 決めないと同じ内容から違う並びが出て、表示もテストも揺れるからである。
    public var all: [Pair] {
        pairs.values.sorted { left, right in
            if left.pairedAtWallUs != right.pairedAtWallUs {
                return left.pairedAtWallUs < right.pairedAtWallUs
            }
            return left.identity.identifier < right.identity.identifier
        }
    }

    public var isEmpty: Bool { pairs.isEmpty }
    public var count: Int { pairs.count }
}
