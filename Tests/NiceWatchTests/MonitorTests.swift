import XCTest
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
