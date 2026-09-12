import XCTest
@testable import MeerkatsCore

final class ConferencingAppsTests: XCTestCase {
    private func process(
        _ bundleId: String?, pid: Int32 = 100, sounding: Bool = true, name: String = "アプリ"
    ) -> AudioProcess {
        AudioProcess(pid: pid, bundleId: bundleId, name: name, isRunningOutput: sounding)
    }

    private func appName(for bundleId: String) -> String? {
        ConferencingApps.appIndex(of: process(bundleId))
            .map { ConferencingApps.known[$0].name }
    }

    // MARK: - 絞り込み

    func testNothingSoundingIsIdle() {
        XCTAssertEqual(ConferencingApps.select(from: []), .idle)
    }

    /// 起動しているだけでは録らない。会議アプリは会議をしていなくても常駐している。
    func testRunningButSilentConferencingAppIsIdle() {
        XCTAssertEqual(
            ConferencingApps.select(from: [process("us.zoom.xos", sounding: false)]), .idle)
    }

    /// 会議アプリ以外が鳴っていても録らない。ここを緩めると、通知音や音楽が
    /// 「相手の声」として記録に残る。
    func testNonConferencingAppIsNotTapped() {
        let noise = [process("com.apple.Music"), process("com.google.Chrome")]
        XCTAssertEqual(ConferencingApps.select(from: noise), .idle)
    }

    func testSingleSoundingConferencingAppIsTapped() {
        let zoom = process("us.zoom.xos")
        XCTAssertEqual(ConferencingApps.select(from: [process("com.apple.Music"), zoom]), .tap(zoom))
    }

    /// バンドルIDが引けないプロセスは対象にしない。名前での照合はしない。
    /// 名前は利用者が変えられるうえ、同名のものが混ざりうる。
    func testProcessWithoutBundleIdIsNotTapped() {
        XCTAssertEqual(ConferencingApps.select(from: [process(nil, name: "zoom.us")]), .idle)
    }

    // MARK: - 照合

    /// 実在するバンドルIDが、意図したアプリに当たること。
    ///
    /// **入力を一覧から作らない。** 作ると `prefix.hasPrefix(prefix)` を確かめるだけになり、
    /// 項目を消しても誤ったIDを足しても通る恒真のテストになる。
    func testRealBundleIdsMapToTheIntendedApp() {
        let cases: [(bundleId: String, app: String)] = [
            ("us.zoom.xos", "Zoom"),
            ("us.zoom.xos.helper", "Zoom"),
            ("com.microsoft.teams", "Microsoft Teams"),
            ("com.microsoft.teams2", "Microsoft Teams"),
            ("Cisco-Systems.Spark", "Webex"),
            ("com.cisco.webexmeetingsapp", "Webex"),
            ("com.webex.meetingmanager", "Webex"),
            ("com.tinyspeck.slackmacgap", "Slack"),
            ("com.hnc.Discord", "Discord"),
            ("com.apple.FaceTime", "FaceTime"),
        ]
        for (bundleId, app) in cases {
            XCTAssertEqual(appName(for: bundleId), app, "\(bundleId) が \(app) に当たらない")
        }
    }

    /// 会議アプリでないものを拾わないこと。前方一致は広いので、隣接するIDで確かめる。
    func testUnrelatedBundleIdsAreNotMatched() {
        for bundleId in [
            "com.microsoft.Word", "com.apple.Music", "com.apple.Safari",
            "com.google.Chrome", "org.mozilla.firefox", "com.cisco.Jabber", "",
        ] {
            XCTAssertNil(appName(for: bundleId), "\(bundleId) が会議アプリとして拾われている")
        }
    }

    /// バンドルIDは識別子であって表示名ではない。大文字小文字を区別する。
    func testMatchingIsCaseSensitive() {
        XCTAssertNil(appName(for: "US.ZOOM.XOS"))
        XCTAssertNil(appName(for: "cisco-systems.spark"))
        XCTAssertEqual(appName(for: "Cisco-Systems.Spark"), "Webex",
                       "Webexアプリは com.cisco. では始まらない")
    }

    /// **どの接頭辞も、他の接頭辞の前置になっていないこと。**
    /// なっていると firstIndex が先に当たったほうを返し、別々のアプリが同じものとして畳まれて
    /// 片方が表示から消える。
    func testPrefixesDoNotShadowEachOther() {
        let prefixes = ConferencingApps.allPrefixes
        for (index, prefix) in prefixes.enumerated() {
            for (otherIndex, other) in prefixes.enumerated() where index != otherIndex {
                XCTAssertFalse(other.hasPrefix(prefix), "\(prefix) が \(other) の前置になっている")
            }
        }
    }

    // MARK: - アプリ単位への畳み込み

    /// **同じアプリの補助プロセスは「別の会議アプリ」ではない。**
    /// 畳まないと、Zoom本体とヘルパーが鳴っているだけで「他の会議アプリも鳴っています」と
    /// 表示する。補助プロセスを拾うために前方一致にした以上、常にその嘘が出る。
    func testHelperOfTheSameAppIsNotReportedAsAnotherApp() {
        let zoom = process("us.zoom.xos", pid: 100)
        let helper = process("us.zoom.xos.helper", pid: 101, name: "zoom.us Helper")
        XCTAssertEqual(ConferencingApps.select(from: [zoom, helper]), .tap(zoom))
    }

    /// **接頭辞をまたいでも畳めること。** Webex は製品が1つなのにバンドルIDが3系統ある。
    /// 接頭辞を同一性として使うと、同じ Webex どうしを別のアプリとして報告する。
    func testOneAppWithSeveralBundleIdsFoldsIntoOne() {
        let spark = process("Cisco-Systems.Spark", pid: 100)
        let meetings = process("com.cisco.webexmeetingsapp", pid: 101)
        let legacy = process("com.webex.meetingmanager", pid: 102)
        XCTAssertEqual(ConferencingApps.select(from: [spark, meetings, legacy]), .tap(spark))
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

    // MARK: - 優先順位

    /// 仕事の会議に使われるものを先に録る。
    func testWorkMeetingAppWinsOverChatAndPersonalCalls() {
        let slack = process("com.tinyspeck.slackmacgap", pid: 10)
        let facetime = process("com.apple.FaceTime", pid: 11)
        let zoom = process("us.zoom.xos", pid: 20)
        XCTAssertEqual(
            ConferencingApps.select(from: [facetime, slack, zoom]),
            .tapWithOthersSounding(zoom, others: [slack, facetime]),
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

    func testIdleSelectionHasNoTarget() {
        XCTAssertNil(TapSelection.idle.target)
    }
}
