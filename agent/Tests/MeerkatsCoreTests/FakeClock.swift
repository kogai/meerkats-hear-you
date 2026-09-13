import Foundation
@testable import MeerkatsCore

/// テストから進み方を決められる時計。
///
/// **実時間で待たない。** 打ち直しの条件は「途切れたと分かっている事象」なので
/// (ADR-0015 決定2)、確かめたいのは経過時間そのものではなく、
/// 打ち直した瞬間に時計が返した値がどう使われるかである。
final class FakeClock: MonotonicClock {
    var us: Int64

    init(us: Int64 = 0) {
        self.us = us
    }

    func nowUs() -> Int64 { us }
}
