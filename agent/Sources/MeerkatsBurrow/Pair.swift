import Foundation

/// 結んだ対。
///
/// 記録そのものは持たない。**誰と交換してよいかを覚えているだけ**である。
public struct Pair: Equatable, Codable {
    public let identity: PeerIdentity
    /// 受け取った側が付ける名前。招待コードには入っていない(ADR-0017)。
    public var name: String
    /// 対を結んだ実時刻(UTCエポックのマイクロ秒)。
    public let pairedAtWallUs: Int64
    /// 最後に繋がった実時刻。**一度も繋がっていなければ nil。**
    ///
    /// ADR-0009 が「対になっているか、最後に繋がったのはいつか、を出す」と決めている。
    /// **nil と「古い日時」は表示上まったく違う。** 前者は一度も繋がっていない
    /// (招待コードが相手に届いていないかもしれない)、後者は繋がっていたものが止まった。
    public var lastConnectedWallUs: Int64?

    public init(
        identity: PeerIdentity,
        name: String,
        pairedAtWallUs: Int64,
        lastConnectedWallUs: Int64? = nil
    ) {
        self.identity = identity
        self.name = name
        self.pairedAtWallUs = pairedAtWallUs
        self.lastConnectedWallUs = lastConnectedWallUs
    }
}

extension PeerIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case publicKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(Data.self, forKey: .publicKey)
        guard let identity = PeerIdentity(publicKey: key) else {
            throw DecodingError.dataCorruptedError(
                forKey: .publicKey,
                in: container,
                debugDescription: "公開鍵が \(PeerIdentity.publicKeyBytes) バイトではない"
            )
        }
        self = identity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(publicKey, forKey: .publicKey)
    }
}
