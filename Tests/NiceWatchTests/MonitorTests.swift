import XCTest
import Combine
@testable import NiceWatch

final class ProbeNotifier: Notifier {
    let name = "probe"
    var calls = 0
    var fail = true
    var onSend: (() -> Void)?
    func send(text: String) async throws {
        calls += 1
        onSend?()
        if fail { throw URLError(.notConnectedToInternet) }
    }
}

final class MonitorTests: XCTestCase {
    func temporaryStore() throws -> Store {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Store(directory: directory)
    }

    @MainActor
    func testPendingSurvivesRestartAndRetriesWithoutFeed() async throws {
        let store = try temporaryStore()
        store.data.ups = [MonitoredUP(mid: 1, name: "UP", face: "", baselinePubdate: 1)]
        let notifier = ProbeNotifier()
        notifier.onSend = {
            XCTAssertEqual(Store(directory: store.directoryURL).data.seen["BVtest"]?.state, .pending)
        }
        let model = AppModel(store: store, restore: false, notifiers: [notifier])
        let video = VideoItem(bvid: "BVtest", title: "test", author: "UP", mid: 1, pubdate: 2, cover: "")
        await model.process(videos: [video])
        XCTAssertEqual(notifier.calls, 1)
        XCTAssertEqual(store.data.seen[video.bvid]?.attempts, 1)
        let restored = Store(directory: store.directoryURL)
        let restarted = AppModel(store: restored, restore: false, notifiers: [notifier])
        notifier.fail = false
        await restarted.process(videos: [])
        XCTAssertEqual(notifier.calls, 2)
        XCTAssertEqual(restored.data.seen[video.bvid]?.state, .notified)
        await restarted.process(videos: [video])
        XCTAssertEqual(notifier.calls, 2)
    }

    @MainActor
    func testFailuresStopAfterThreeAttempts() async throws {
        let store = try temporaryStore()
        store.data.ups = [MonitoredUP(mid: 1, name: "UP", face: "", baselinePubdate: 1)]
        let notifier = ProbeNotifier()
        let model = AppModel(store: store, restore: false, notifiers: [notifier])
        let video = VideoItem(bvid: "BVtest", title: "test", author: "UP", mid: 1, pubdate: 2, cover: "")
        await model.process(videos: [video])
        for _ in 0..<4 { await model.process(videos: [video]) }
        XCTAssertEqual(notifier.calls, 3)
        XCTAssertEqual(store.data.seen[video.bvid]?.state, .failed)
    }

    @MainActor
    func testSaveFailurePreventsSend() async throws {
        let store = try temporaryStore()
        store.data.ups = [MonitoredUP(mid: 1, name: "UP", face: "", baselinePubdate: 1)]
        try FileManager.default.removeItem(at: store.directoryURL)
        let notifier = ProbeNotifier()
        let model = AppModel(store: store, restore: false, notifiers: [notifier])
        await model.process(videos: [VideoItem(bvid: "BVtest", title: "test", author: "UP", mid: 1, pubdate: 2, cover: "")])
        XCTAssertEqual(notifier.calls, 0)
        XCTAssertEqual(store.data.seen["BVtest"]?.state, .pending)
    }

    func testRotationCoversAllUPs() {
        let ups = (1...45).map { MonitoredUP(mid: Int64($0), name: "UP", face: "") }
        var offset = 0
        var visited = Set<Int64>()
        for _ in 0..<3 {
            let batch = AppModel.nextBatch(ups, offset: &offset)
            XCTAssertEqual(batch.count, 20)
            visited.formUnion(batch.map(\.mid))
        }
        XCTAssertEqual(visited.count, 45)
        XCTAssertTrue(AppModel.nextBatch([], offset: &offset).isEmpty)
    }

    @MainActor
    func testPruningPreservesPendingAndDeduplication() async throws {
        let store = try temporaryStore()
        store.data.ups = [MonitoredUP(mid: 1, name: "UP", face: "", baselinePubdate: 1)]
        for index in 2...12 {
            let video = VideoItem(bvid: "BV\(index)", title: "test", author: "UP", mid: 1, pubdate: index, cover: "")
            _ = store.markSeen(video, state: index == 2 ? .pending : .notified)
        }
        store.pruneSeen(maxCount: 3)
        XCTAssertEqual(store.data.seen.count, 4)
        XCTAssertEqual(store.data.seen["BV2"]?.state, .pending)
        let removed = (3...12).first { store.data.seen["BV\($0)"] == nil }!
        let notifier = ProbeNotifier()
        notifier.fail = false
        let model = AppModel(store: store, restore: false, notifiers: [notifier])
        await model.process(videos: [VideoItem(bvid: "BV\(removed)", title: "test", author: "UP", mid: 1, pubdate: removed, cover: "")])
        XCTAssertEqual(notifier.calls, 1) // only the retained pending item
        XCTAssertEqual(store.data.seen["BV\(removed)"]?.state, .baseline)
    }
}

@MainActor
final class ControlledNotifier: Notifier {
    nonisolated let name = "controlled"
    var calls = 0
    private var sendContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func send(text: String) async throws {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation in
                sendContinuation = continuation
                startedContinuation?.resume()
                startedContinuation = nil
            }
        }
    }

    func waitUntilSending() async {
        if sendContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func finishSend() {
        sendContinuation?.resume()
        sendContinuation = nil
    }
}

extension MonitorTests {
    @MainActor
    func testPauseAndRemovePublishImmediately() throws {
        let store = try temporaryStore()
        store.data.ups = [MonitoredUP(mid: 1, name: "UP", face: "")]
        let model = AppModel(store: store, restore: false, notifiers: [])
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        model.setUPEnabled(mid: 1, enabled: false)
        XCTAssertFalse(store.data.ups[0].enabled)
        XCTAssertGreaterThan(changes, 0)
        changes = 0
        model.removeUP(mid: 1)
        XCTAssertTrue(store.data.ups.isEmpty)
        XCTAssertGreaterThan(changes, 0)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testRemovalRequiresConfirmationAndKeepsRecords() throws {
        let store = try temporaryStore()
        store.data.ups = [MonitoredUP(mid: 1, name: "UP", face: "")]
        _ = store.markSeen(VideoItem(bvid: "BVold", title: "old", author: "UP", mid: 1, pubdate: 1, cover: ""), state: .notified)
        let model = AppModel(store: store, restore: false, notifiers: [])
        model.requestRemoveUP(mid: 1)
        XCTAssertEqual(store.data.ups.count, 1)
        model.confirmation = nil // cancel
        XCTAssertEqual(store.data.ups.count, 1)
        model.requestRemoveUP(mid: 1)
        model.confirmAction()
        XCTAssertTrue(store.data.ups.isEmpty)
        XCTAssertNotNil(store.data.seen["BVold"])
    }

    @MainActor
    func testPauseOrRemoveDuringSendStopsRemainingVideos() async throws {
        for remove in [false, true] {
            let store = try temporaryStore()
            store.data.ups = [MonitoredUP(mid: 1, name: "UP", face: "", baselinePubdate: 1)]
            let notifier = ControlledNotifier()
            let model = AppModel(store: store, restore: false, notifiers: [notifier])
            let videos = (2...3).map { VideoItem(bvid: "BV\($0)", title: "test", author: "UP", mid: 1, pubdate: $0, cover: "") }
            let task = Task { await model.process(videos: videos) }
            await notifier.waitUntilSending()
            if remove { model.removeUP(mid: 1) }
            else { model.setUPEnabled(mid: 1, enabled: false) }
            notifier.finishSend()
            await task.value
            XCTAssertEqual(notifier.calls, 1)
            XCTAssertNil(store.data.seen["BV3"])
        }
    }

    @MainActor
    func testClearRecordsKeepsAccountSettingsMonitorsAndSession() throws {
        let store = try temporaryStore()
        store.data.ups = [MonitoredUP(mid: 1, name: "UP", face: "", baselinePubdate: 1)]
        store.data.settings.barkKey = "test-only-key"
        store.data.settings.intervalSeconds = 600
        store.data.account = AccountInfo(mid: 8, uname: "test", face: "", level: 1)
        let session = store.directoryURL.appendingPathComponent("session.bin")
        let sessionData = Data("test session sentinel".utf8)
        try sessionData.write(to: session)
        _ = store.markSeen(VideoItem(bvid: "BVold", title: "test", author: "UP", mid: 1, pubdate: 2, cover: ""), state: .notified)
        let model = AppModel(store: store, restore: false, notifiers: [])
        model.isLoggedIn = true
        model.account = store.account
        model.unreadCount = 5
        model.confirmation = .clearAllRecords
        XCTAssertEqual(store.data.seen.count, 1)
        model.confirmAction()
        XCTAssertTrue(model.isLoggedIn)
        XCTAssertEqual(model.account?.mid, 8)
        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertTrue(store.data.seen.isEmpty)
        XCTAssertEqual(store.data.ups.count, 1)
        XCTAssertTrue(store.data.ups[0].enabled)
        XCTAssertGreaterThan(store.data.ups[0].baselinePubdate, 1)
        XCTAssertEqual(try Data(contentsOf: session), sessionData)
        let reloaded = Store(directory: store.directoryURL)
        XCTAssertTrue(reloaded.data.seen.isEmpty)
        XCTAssertEqual(reloaded.settings.barkKey, "test-only-key")
        XCTAssertEqual(reloaded.settings.intervalSeconds, 600)
        XCTAssertEqual(reloaded.account?.mid, 8)
    }

    @MainActor
    func testClearedRecordsAreNotRestoredByInFlightSend() async throws {
        let store = try temporaryStore()
        store.data.ups = [MonitoredUP(mid: 1, name: "UP", face: "", baselinePubdate: 1)]
        let notifier = ControlledNotifier()
        let model = AppModel(store: store, restore: false, notifiers: [notifier])
        let video = VideoItem(bvid: "BVtest", title: "test", author: "UP", mid: 1, pubdate: 2, cover: "")
        let task = Task { await model.process(videos: [video]) }
        await notifier.waitUntilSending()
        XCTAssertTrue(model.clearAllRecords())
        notifier.finishSend()
        await task.value
        XCTAssertTrue(store.data.seen.isEmpty)
        XCTAssertEqual(model.unreadCount, 0)
        await model.process(videos: [video])
        XCTAssertEqual(notifier.calls, 1) // cleared historical videos must not notify again
    }
}
