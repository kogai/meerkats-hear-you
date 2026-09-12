import AppKit
import CoreAudio
import Foundation
import MeerkatsCore

/// Core Audio が持っているプロセスの一覧を `MeerkatsCore` の形に写す(ADR-0008)。
///
/// このファイルは実機でしか動かせない。**判断は一切持たない。** どれを録るかは
/// `ConferencingApps.select` が決め、ここはその入力を作るだけにしてある。
///
/// 写し取る値は3つに絞ってある。バンドルID、pid、出力中かどうか。名前は表示のためだけで、
/// 照合には使わない。利用者が変えられるうえ、同名のものが混ざりうるため。
public enum AudioProcessList {
    public enum ListError: Error {
        /// プロパティの読み出しに失敗した。`status` は Core Audio の OSStatus。
        case propertyFailed(selector: AudioObjectPropertySelector, status: OSStatus)
    }

    /// 1回ぶんの読み取り結果。
    public struct Snapshot {
        public var processes: [AudioProcess]

        /// 値を読めずに捨てたプロセスの数。
        ///
        /// **捨てた事実を落とさない。** 落とすと「1つも読めなかった」と「会議アプリが
        /// 鳴っていない」が同じ空の一覧になる。ADR-0008 がいちばん避けたい混同を、
        /// この層が作ることになる。判断は上でするので、ここでは数だけ持って返す。
        public var unreadable: Int
    }

    /// いま Core Audio が知っているプロセスすべて。会議アプリかどうかの選別はしない。
    public static func current() throws -> Snapshot {
        let ids = try processObjectIDs()
        let processes = ids.compactMap(describe)
        return Snapshot(processes: processes, unreadable: ids.count - processes.count)
    }

    // MARK: - Core Audio からの読み出し

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// システムオブジェクトが持つプロセスオブジェクトの一覧。
    ///
    /// 大きさを問い合わせてから確保するが、**2回の呼び出しの間に増えたぶんは取りこぼす。**
    /// `ioDataSize` は入口では確保した長さの上限として効くので、古い値を渡した2回目は
    /// そこで頭打ちになる。取りこぼしたぶんは次の呼び出しで拾う。
    ///
    /// 減った場合は、返ってきた大きさまで詰め直す。詰めないと末尾に
    /// `kAudioObjectUnknown` が残り、存在しないプロセスを読みにいくことになる。
    private static func processObjectIDs() throws -> [AudioObjectID] {
        let selector = kAudioHardwarePropertyProcessObjectList
        var propertyAddress = address(selector)
        var dataSize: UInt32 = 0

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr else {
            throw ListError.propertyFailed(selector: selector, status: status)
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &ids
        )
        guard status == noErr else {
            throw ListError.propertyFailed(selector: selector, status: status)
        }
        return Array(ids.prefix(Int(dataSize) / MemoryLayout<AudioObjectID>.size))
    }

    /// 1プロセスぶんの値を読む。
    ///
    /// **読めなかったプロセスは捨てる。** 一覧には自分自身や、音声を扱わない常駐プロセスも
    /// 並ぶ。そこで失敗するたびに全体を投げ返すと、会議アプリが1つも取れなくなる。
    private static func describe(_ object: AudioObjectID) -> AudioProcess? {
        guard let pid = integer(of: object, kAudioProcessPropertyPID, as: pid_t.self) else {
            return nil
        }
        // 空文字は「取れなかった」と同じに倒す。倒さないと name のフォールバックで
        // 「値がある」扱いになり、名前が空のまま記録に残る。
        let rawBundleId = string(of: object, kAudioProcessPropertyBundleID)
        let bundleId: String? = (rawBundleId?.isEmpty ?? true) ? nil : rawBundleId
        // 読めなければ false に倒す。鳴っているか分からないものを録るより、録らないほうが安い。
        let isRunningOutput =
            integer(of: object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0

        return AudioProcess(
            pid: pid,
            bundleId: bundleId,
            name: displayName(pid: pid) ?? bundleId ?? "pid \(pid)",
            isRunningOutput: isRunningOutput != 0
        )
    }

    private static func integer<T: FixedWidthInteger>(
        of object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type
    ) -> T? {
        var propertyAddress = address(selector)
        var dataSize = UInt32(MemoryLayout<T>.size)
        var value = T.zero

        let status = AudioObjectGetPropertyData(
            object, &propertyAddress, 0, nil, &dataSize, &value
        )
        return status == noErr ? value : nil
    }

    /// CFString を返すプロパティ。
    ///
    /// 返る参照は +1 で、解放する義務は呼び出し側にある。**`value` を nil で始めるのが要点で、**
    /// 上書きで失われる参照が無いため、ARC がスコープ終端でその +1 をちょうど1回消費する。
    /// 初期値を入れると、その参照が解放されないまま捨てられる。
    private static func string(
        of object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var propertyAddress = address(selector)
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?

        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &dataSize, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// 表示用の名前。取れなくても記録は成立するので、失敗を投げない。
    private static func displayName(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
