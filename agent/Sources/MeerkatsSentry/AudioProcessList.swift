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

    /// いま Core Audio が知っているプロセスすべて。会議アプリかどうかの選別はしない。
    public static func current() throws -> [AudioProcess] {
        try processObjectIDs().compactMap(describe)
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
    /// 個数は呼び出しのたびに変わるので、大きさを問い合わせてから確保する。
    /// 固定長の配列を置くと、会議中にアプリが増えた瞬間に取りこぼす。
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
        return ids
    }

    /// 1プロセスぶんの値を読む。
    ///
    /// **読めなかったプロセスは捨てる。** 一覧には自分自身や、音声を扱わない常駐プロセスも
    /// 並ぶ。そこで失敗するたびに全体を投げ返すと、会議アプリが1つも取れなくなる。
    private static func describe(_ object: AudioObjectID) -> AudioProcess? {
        guard let pid = integer(of: object, kAudioProcessPropertyPID, as: pid_t.self) else {
            return nil
        }
        let bundleId = string(of: object, kAudioProcessPropertyBundleID)
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

    /// CFString を返すプロパティ。所有権が呼び出し側に移るので、Swift の String に写して手放す。
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
