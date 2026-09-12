import XCTest
@testable import MeerkatsCore

final class ConferencingAppsTests: XCTestCase {
    private func process(
        _ bundleId: String?, pid: Int32 = 100, sounding: Bool = true, name: String = "アプリ"
    ) -> AudioProcess {
        AudioProcess(pid: pid, bundleId: bundleId, name: name, isRunningOutput: sounding)
    }

    func testNothingSoundingIsIdle() {
        XCTAssertEqual(ConferencingApps.select(from: []), .idle)
    }

    /// 起動しているだけでは録らない。会議アプリは会議をしていなくても常駐している。
    func testRunningButSilentConferencingAppIsIdle() {
        let zoom = process("us.zoom.xos", sounding: false)
        XCTAssertEqual(ConferencingApps.select(from: [zoom]), .idle)
    }

    /// 会議アプリ以外が鳴っていても録らない。ここを緩めると、通知音や音楽が
    /// 「相手の声」として記録に残る。
    func testNonConferencingAppIsNotTapped() {
        let music = process("com.apple.Music")
        let browser = process("com.google.Chrome")
        XCTAssertEqual(ConferencingApps.select(from: [music, browser]), .idle)
    }

    func testSingleSoundingConferencingAppIsTapped() {
        let zoom = process("us.zoom.xos")
        XCTAssertEqual(ConferencingApps.select(from: [process("com.apple.Music"), zoom]), .tap(zoom))
    }

    /// 音声が補助プロセスに出ている場合(ADR-0008の未検証の前提)。完全一致だと拾えない。
    func testHelperProcessIsMatchedByPrefix() {
        let helper = process("us.zoom.xos.helper", name: "zoom.us Helper")
        XCTAssertEqual(ConferencingApps.select(from: [helper]), .tap(helper))
        XCTAssertEqual(
            ConferencingApps.select(from: [process("com.microsoft.teams2")]).target?.bundleId,
            "com.microsoft.teams2")
    }

    /// バンドルIDが引けないプロセスは対象にしない。名前での照合はしない。
    /// 名前は利用者が変えられるうえ、同名のものが混ざりうる。
    func testProcessWithoutBundleIdIsNotTapped() {
        XCTAssertEqual(ConferencingApps.select(from: [process(nil, name: "zoom.us")]), .idle)
    }

    /// 会議専用アプリを、通話もできるチャットアプリより先に録る。
    func testDedicatedMeetingAppWinsOverChatApp() {
        let slack = process("com.tinyspeck.slackmacgap", pid: 10)
        let zoom = process("us.zoom.xos", pid: 20)
        XCTAssertEqual(
            ConferencingApps.select(from: [slack, zoom]),
            .tapWithOthersSounding(zoom, others: [slack]),
            "pidの若さではなく優先順位で決まること")
    }

    /// 選ばなかったほうを黙って捨てない。表示に出せないと、利用者は
    /// もう一方が録れていないことに気づけない。
    func testOtherSoundingAppsAreReported() {
        let zoom = process("us.zoom.xos", pid: 20)
        let teams = process("com.microsoft.teams", pid: 30)
        let discord = process("com.hnc.Discord", pid: 40)
        guard case .tapWithOthersSounding(let chosen, let others) =
            ConferencingApps.select(from: [discord, teams, zoom]) else {
            return XCTFail("複数鳴っているのに単独として返っている")
        }
        XCTAssertEqual(chosen, zoom)
        XCTAssertEqual(others, [teams, discord], "残りも優先順位の並びで返ること")
    }

    /// 同じアプリのプロセスが複数鳴っているとき、録る対象が実行のたびに変わらないこと。
    func testTieIsBrokenDeterministicallyByPid() {
        let later = process("us.zoom.xos", pid: 900)
        let earlier = process("us.zoom.xos", pid: 200)
        XCTAssertEqual(ConferencingApps.select(from: [later, earlier]), .tap(earlier))
        XCTAssertEqual(ConferencingApps.select(from: [earlier, later]), .tap(earlier),
                       "入力の順序で結果が変わらないこと")
    }

    /// **同じアプリの補助プロセスは「別の会議アプリ」ではない。**
    /// 畳まないと、Zoom本体とヘルパーが鳴っているだけで「他の会議アプリも鳴っています」と
    /// 表示する。補助プロセスを拾うために前方一致にした以上、ヘルパーを持つアプリでは
    /// 常にその嘘が出る。
    func testHelperOfTheSameAppIsNotReportedAsAnotherApp() {
        let zoom = process("us.zoom.xos", pid: 100)
        let helper = process("us.zoom.xos.helper", pid: 101, name: "zoom.us Helper")
        XCTAssertEqual(ConferencingApps.select(from: [zoom, helper]), .tap(zoom))
    }

    /// 畳むのはアプリ単位であって、他のアプリまで消してはいけない。
    func testFoldingKeepsOneEntryPerApp() {
        let zoom = process("us.zoom.xos", pid: 100)
        let helper = process("us.zoom.xos.helper", pid: 101)
        let slack = process("com.tinyspeck.slackmacgap", pid: 200)
        let slackHelper = process("com.tinyspeck.slackmacgap.helper", pid: 201)
        XCTAssertEqual(
            ConferencingApps.select(from: [helper, slackHelper, zoom, slack]),
            .tapWithOthersSounding(zoom, others: [slack]),
            "アプリごとに1つ。ヘルパーは残らない")
    }

    /// 一覧のどの項目も到達可能であること。書いたが一度も当たらない項目を残さない。
    func testEveryPrefixMatchesItself() {
        for prefix in ConferencingApps.bundleIdPrefixes {
            XCTAssertEqual(
                ConferencingApps.select(from: [process(prefix)]).target?.bundleId, prefix,
                "\(prefix) がどのプロセスにも当たらない")
        }
    }

    /// **一覧の中に、他の項目の接頭辞になっているものが無いこと。**
    /// あると firstIndex が先に当たったほうを返し、優先順位が意図とずれる。
    /// さらに、別々のアプリが同じ位置に畳まれて片方が表示から消える。
    func testPrefixesDoNotShadowEachOther() {
        for (index, prefix) in ConferencingApps.bundleIdPrefixes.enumerated() {
            for (otherIndex, other) in ConferencingApps.bundleIdPrefixes.enumerated()
            where index != otherIndex {
                XCTAssertFalse(
                    other.hasPrefix(prefix),
                    "\(prefix) が \(other) の接頭辞になっている")
            }
        }
    }

    /// バンドルIDは識別子であって表示名ではない。大文字小文字を区別する。
    /// 区別をやめると `com.apple.facetimed` のような別物を拾いうる。
    func testMatchingIsCaseSensitive() {
        XCTAssertNil(ConferencingApps.priority(of: process("US.ZOOM.XOS")))
        XCTAssertNil(ConferencingApps.priority(of: process("cisco-systems.spark")))
        XCTAssertNotNil(ConferencingApps.priority(of: process("Cisco-Systems.Spark")),
                        "Webexアプリは com.cisco. では始まらない")
    }

    /// ブラウザを対象にしないのは決定であって、書き忘れではない(ADR-0008)。
    func testBrowsersAreNotInTheList() {
        for browser in ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox"] {
            XCTAssertNil(
                ConferencingApps.priority(of: process(browser)),
                "\(browser) が対象に入っている。タブ単位で分けられない以上、限定が効かない")
        }
    }

    func testIdleSelectionHasNoTarget() {
        XCTAssertNil(TapSelection.idle.target)
    }
}
