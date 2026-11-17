import XCTest
@testable import NiceWatch

final class ContentIntegrationTests: XCTestCase {
    @MainActor
    private func fixture(preferences: PushContentPreferences, api: StubMonitoringAPI? = nil,
                         notifier: ProbeNotifier = ProbeNotifier()) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        store.data.ups = [MonitoredUP(mid: 1, name: "示例UP", face: "", addedAt: Date(timeIntervalSince1970: 1), baselinePubdate: 1)]
        store.data.settings.contentPreferences = preferences
        notifier.fail = false
        let model = AppModel(store: store, restore: false, notifiers: [notifier], monitoringAPI: api ?? StubMonitoringAPI())
        model.isLoggedIn = true
        return model
    }

    private func event(_ kind: ContentKind, time: Int = 10) -> VideoItem {
        VideoItem(bvid: "test-\(kind.rawValue)", title: "新内容", author: "示例UP", mid: 1,
                  pubdate: time, cover: "", kind: kind,
                  link: kind.isVideo ? nil : "https://t.bilibili.com/123", content: "正文")
    }
    private func only(_ kind: ContentKind) -> PushContentPreferences {
        var p = PushContentPreferences()
        p.uploads = kind == .upload
        p.dynamicVideos = kind == .dynamicVideo
        p.textDynamics = kind == .textDynamic
        p.reposts = kind == .repost
        p.live = kind == .live
        return p
    }

    @MainActor
    func testEachSwitchOnlyAllowsItsSelectedKind() async throws {
        for kind in ContentKind.allCases {
            let notifier = ProbeNotifier()
            let model = try fixture(preferences: only(kind), notifier: notifier)
            await model.process(videos: ContentKind.allCases.map { event($0) })
            XCTAssertEqual(notifier.calls, 1, kind.rawValue)
            XCTAssertEqual(model.store.timeline.map(\.contentKind), [kind])
        }
    }

    @MainActor
    func testDisabledUploadDoesNotBecomeDynamicWhenItLeavesUploadPage() async throws {
        let notifier = ProbeNotifier()
        let model = try fixture(preferences: only(.dynamicVideo), notifier: notifier)
        let upload = VideoItem(bvid: "BVregular", title: "regular", author: "UP", mid: 1, pubdate: 10, cover: "", kind: .upload)
        await model.process(videos: [upload])
        var laterDynamic = upload
        laterDynamic.kind = .dynamicVideo
        await model.process(videos: [laterDynamic])
        XCTAssertEqual(notifier.calls, 0)
        XCTAssertEqual(model.store.data.seen["BVregular"]?.contentKind, .upload)
    }

    @MainActor
    func testTextAndRepostSelectionDoesNotFetchUploads() async throws {
        var preferences = only(.textDynamic)
        preferences.reposts = true
        let api = StubMonitoringAPI()
        api.dynamics = [event(.textDynamic), event(.repost), event(.dynamicVideo)]
        let notifier = ProbeNotifier()
        let model = try fixture(preferences: preferences, api: api, notifier: notifier)
        await model.performCheck()
        XCTAssertEqual(api.uploadCalls, 0)
        XCTAssertEqual(api.dynamicCalls, 1)
        XCTAssertEqual(api.liveCalls, 0)
        XCTAssertEqual(notifier.calls, 2)
        XCTAssertEqual(Set(model.store.timeline.map(\.contentKind)), [.textDynamic, .repost])
    }

    @MainActor
    func testDisabledPendingContentIsNotRetried() async throws {
        let notifier = ProbeNotifier()
        let model = try fixture(preferences: only(.upload), notifier: notifier)
        _ = model.store.markSeen(event(.repost), state: .pending)
        await model.process(videos: [])
        XCTAssertEqual(notifier.calls, 0)
        XCTAssertEqual(model.store.data.seen["test-repost"]?.state, .muted)
    }

    @MainActor
    func testPendingTextRetryPreservesTypeContentAndLinkAfterRestart() async throws {
        let notifier = ProbeNotifier()
        let model = try fixture(preferences: only(.textDynamic), notifier: notifier)
        notifier.fail = true
        await model.process(videos: [event(.textDynamic)])
        XCTAssertEqual(model.store.timeline.first?.state, .pending)
        let store = Store(directory: model.store.directoryURL)
        notifier.fail = false
        var delivered = ""
        let capturing = CapturingNotifier { delivered = $0 }
        let restarted = AppModel(store: store, restore: false, notifiers: [capturing], monitoringAPI: StubMonitoringAPI())
        await restarted.process(videos: [])
        XCTAssertTrue(delivered.contains("图文动态"))
        XCTAssertTrue(delivered.contains("正文"))
        XCTAssertTrue(delivered.contains("https://t.bilibili.com/123"))
        XCTAssertEqual(store.timeline.first?.state, .notified)
    }

    @MainActor
    func testClearingRecordsKeepsCurrentLiveBaseline() async throws {
        let api = StubMonitoringAPI()
        let notifier = ProbeNotifier()
        let model = try fixture(preferences: only(.live), api: api, notifier: notifier)
        api.room = try room(0, 0)
        await model.performCheck()
        api.room = try room(1, 100)
        await model.performCheck()
        XCTAssertEqual(notifier.calls, 1)
        XCTAssertTrue(model.clearAllRecords())
        XCTAssertTrue(model.store.data.ups[0].liveObservation?.isLive == true)
        XCTAssertNil(model.store.data.ups[0].liveObservation?.pendingEvent)
        await model.performCheck()
        XCTAssertEqual(notifier.calls, 1)
        XCTAssertTrue(model.store.timeline.isEmpty)
    }

    private func room(_ status: Int, _ time: Int) throws -> LiveRoom {
        try JSONDecoder().decode(LiveRoom.self, from: Data("{\"room_id\":123,\"live_status\":\(status),\"live_time\":\(time),\"title\":\"一起聊天\"}".utf8))
    }

    @MainActor
    func testLiveNotifiesOpeningOnceAndPreservesBaselineOnRestart() async throws {
        let api = StubMonitoringAPI()
        let notifier = ProbeNotifier()
        var preferences = only(.live)
        preferences.enabledSince[ContentKind.live.rawValue] = 50
        let model = try fixture(preferences: preferences, api: api, notifier: notifier)
        model.store.data.settings.liveTemplate = "{author}开播啦！{title} 房间{room_id}\n{url}"
        api.room = try room(1, 10)
        await model.performCheck() // enable while already live: baseline only
        XCTAssertEqual(notifier.calls, 0)
        api.room = try room(0, 0)
        await model.performCheck()
        api.room = try room(1, 100)
        await model.performCheck()
        XCTAssertEqual(notifier.calls, 1)
        XCTAssertEqual(model.store.timeline.first?.contentKind, .live)
        XCTAssertEqual(model.store.timeline.first?.videoURL?.absoluteString, "https://live.bilibili.com/123")
        XCTAssertEqual(api.uploadCalls, 0)
        XCTAssertEqual(api.dynamicCalls, 0)
        let restored = Store(directory: model.store.directoryURL)
        let restarted = AppModel(store: restored, restore: false, notifiers: [notifier], monitoringAPI: api)
        restarted.isLoggedIn = true
        await restarted.performCheck()
        XCTAssertEqual(notifier.calls, 1)
        api.failLive = true
        await restarted.performCheck()
        api.failLive = false
        await restarted.performCheck()
        XCTAssertEqual(notifier.calls, 1) // network failure is not an offline transition
        api.room = nil
        await restarted.performCheck()
        XCTAssertTrue(restored.data.ups[0].liveObservation?.isLive == true)
        api.room = try room(1, 100)
        await restarted.performCheck()
        XCTAssertEqual(notifier.calls, 1) // an omitted room is not a real offline transition either
        api.room = try room(0, 0)
        await restarted.performCheck()
        api.room = try room(1, 200)
        await restarted.performCheck()
        XCTAssertEqual(notifier.calls, 2)
    }
}

@MainActor
final class CapturingNotifier: Notifier {
    nonisolated let name = "capture"
    let capture: @MainActor (String) -> Void
    init(_ capture: @escaping @MainActor (String) -> Void) { self.capture = capture }
    func send(text: String) async throws { capture(text) }
}
