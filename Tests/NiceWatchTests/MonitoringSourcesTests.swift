import XCTest
@testable import NiceWatch

@MainActor
final class StubMonitoringAPI: MonitoringAPI {
    var uploads: [VideoItem] = []
    var dynamics: [VideoItem] = []
    var room: LiveRoom?
    var failLive = false
    var liveCalls = 0
    var uploadCalls = 0
    var failUploads = false
    var failDynamics = false
    var dynamicCalls = 0
    var fallbackCalls = 0
    func nav() async throws -> AccountInfo? { AccountInfo(mid: 8, uname: "offline", face: "", level: 1) }
    func spaceVideos(mid: Int64, page: Int, pageSize: Int) async throws -> [VideoItem] {
        uploadCalls += 1
        if failUploads { throw URLError(.notConnectedToInternet) }
        return uploads
    }
    func spaceDynamicVideos(mid: Int64) async throws -> [VideoItem] {
        dynamicCalls += 1
        if failDynamics { throw URLError(.notConnectedToInternet) }
        return dynamics
    }
    func liveRoom(mid: Int64) async throws -> LiveRoom? {
        liveCalls += 1
        if failLive { throw URLError(.notConnectedToInternet) }
        return room
    }
    func dynamicVideoFeed() async throws -> [VideoItem] { fallbackCalls += 1; return [] }
}

final class MonitoringSourcesTests: XCTestCase {
    private func video(_ bvid: String, mid: Int64 = 1, date: Int) -> VideoItem {
        VideoItem(bvid: bvid, title: bvid, author: "UP", mid: mid, pubdate: date, cover: "")
    }
    @MainActor
    private func makeModel(api: StubMonitoringAPI, notifier: ProbeNotifier, mid: Int64 = 1,
                           addedAt: Int = 1, baseline: Int = 2) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        store.data.ups = [MonitoredUP(mid: mid, name: "UP", face: "", addedAt: Date(timeIntervalSince1970: TimeInterval(addedAt)), baselinePubdate: baseline)]
        let model = AppModel(store: store, restore: false, notifiers: [notifier], monitoringAPI: api)
        model.isLoggedIn = true
        notifier.fail = false
        return model
    }

    @MainActor
    func testReportedTimDynamicVideoIsDetectedWithEmptyUploads() async throws {
        let api = StubMonitoringAPI()
        let mid: Int64 = 3707054489340601
        api.dynamics = [video("BV1hUsg62Ej6", mid: mid, date: 1794895202),
                        video("BV1BJsV6PEek", mid: mid, date: 1794711610)]
        let notifier = ProbeNotifier()
        let model = try makeModel(api: api, notifier: notifier, mid: mid, addedAt: 1794848967, baseline: 1794848985)
        await model.performCheck()
        XCTAssertEqual(api.dynamicCalls, 1)
        XCTAssertEqual(notifier.calls, 1)
        XCTAssertEqual(model.store.data.seen["BV1hUsg62Ej6"]?.state, .notified)
        XCTAssertEqual(model.store.data.seen["BV1BJsV6PEek"]?.state, .baseline)
    }

    @MainActor
    func testBothSourcesCheckedAndDuplicatesDeliveredOnlyOnce() async throws {
        let api = StubMonitoringAPI()
        api.uploads = [video("BVshared", date: 10)]
        api.dynamics = [video("BVshared", date: 11), video("BVdynamic", date: 12)]
        let notifier = ProbeNotifier()
        let model = try makeModel(api: api, notifier: notifier)
        await model.performCheck()
        XCTAssertEqual(api.dynamicCalls, 1)
        XCTAssertEqual(notifier.calls, 2)
        XCTAssertEqual(model.store.data.seen["BVshared"]?.pubdate, 10)
        await model.performCheck()
        XCTAssertEqual(notifier.calls, 2)
    }

    @MainActor
    func testUploadFailureStillDeliversDynamicVideos() async throws {
        let api = StubMonitoringAPI()
        api.failUploads = true
        api.dynamics = [video("BVdynamic", date: 10)]
        let notifier = ProbeNotifier()
        let model = try makeModel(api: api, notifier: notifier)
        await model.performCheck()
        XCTAssertEqual(notifier.calls, 1)
        XCTAssertEqual(api.fallbackCalls, 0)
        XCTAssertEqual(model.status, .networkError("部分来源不可用"))
    }

    @MainActor
    func testDynamicFailureStillDeliversUploads() async throws {
        let api = StubMonitoringAPI()
        api.failDynamics = true
        api.uploads = [video("BVupload", date: 10)]
        let notifier = ProbeNotifier()
        let model = try makeModel(api: api, notifier: notifier)
        await model.performCheck()
        XCTAssertEqual(notifier.calls, 1)
        XCTAssertEqual(model.status, .networkError("部分来源不可用"))
    }

    @MainActor
    func testAllSourcesFailDoesNotReportHealthy() async throws {
        let api = StubMonitoringAPI()
        api.failUploads = true
        api.failDynamics = true
        let notifier = ProbeNotifier()
        let model = try makeModel(api: api, notifier: notifier)
        await model.performCheck()
        XCTAssertEqual(notifier.calls, 0)
        XCTAssertEqual(api.fallbackCalls, 1)
        XCTAssertEqual(model.status, .networkError("部分来源不可用"))
    }

    @MainActor
    func testNewSourceDoesNotPushHistoryBeforeMonitoringStarted() async throws {
        let api = StubMonitoringAPI()
        api.dynamics = [video("BVhistory", date: 50)]
        let notifier = ProbeNotifier()
        let model = try makeModel(api: api, notifier: notifier, addedAt: 100)
        await model.performCheck()
        XCTAssertEqual(notifier.calls, 0)
        XCTAssertEqual(model.store.data.seen["BVhistory"]?.state, .baseline)
    }

    func testParserIgnoresForwardsAndUnknownPublicationTimes() throws {
        let json = #"{"items":[{"type":"DYNAMIC_TYPE_AV","modules":{"module_author":{"mid":1,"pub_ts":"123"},"module_dynamic":{"major":{"archive":{"bvid":"BVvalid"}}}}},{"type":"DYNAMIC_TYPE_FORWARD","modules":{"module_author":{"mid":1,"pub_ts":124},"module_dynamic":{"major":{"archive":{"bvid":"BVforward"}}}}},{"type":"DYNAMIC_TYPE_AV","modules":{"module_author":{"mid":1},"module_dynamic":{"major":{"archive":{"bvid":"BVmissingTime"}}}}}]}"#
        let data = try JSONDecoder().decode(DynFeedData.self, from: Data(json.utf8))
        let videos = BiliClient.parseFeed(data)
        XCTAssertEqual(videos.map(\.bvid), ["BVvalid"])
        XCTAssertEqual(videos.first?.pubdate, 123)
    }
}
