import XCTest
@testable import NiceWatch

final class ContentTests: XCTestCase {
    func testOldSettingsAndRecordsRemainDecodable() throws {
        var original = Settings()
        original.barkKey = "offline-test-key"
        let bytes = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "pushContent")
        object.removeValue(forKey: "liveTemplate")
        let migrated = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.barkKey, original.barkKey)
        XCTAssertTrue(migrated.contentPreferences.uploads)
        XCTAssertTrue(migrated.contentPreferences.dynamicVideos)
        XCTAssertFalse(migrated.contentPreferences.textDynamics)
        XCTAssertFalse(migrated.contentPreferences.reposts)
        XCTAssertFalse(migrated.contentPreferences.live)
        XCTAssertEqual(migrated.liveTemplateValue, Settings.defaultLiveTemplate)
    }

    func testEnabledCategoryStartsAtEnableTime() throws {
        var preferences = PushContentPreferences()
        preferences.set(.textDynamic, enabled: true, now: 100)
        XCTAssertFalse(preferences.allows(.textDynamic, publishedAt: 99))
        XCTAssertTrue(preferences.allows(.textDynamic, publishedAt: 101))
        preferences.set(.textDynamic, enabled: false, now: 102)
        XCTAssertFalse(preferences.allows(.textDynamic, publishedAt: 103))
        preferences.set(.textDynamic, enabled: true, now: 200)
        let restored = try JSONDecoder().decode(PushContentPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertFalse(restored.allows(.textDynamic, publishedAt: 150))
        XCTAssertTrue(restored.allows(.textDynamic, publishedAt: 201))
    }

    func testDynamicParserCreatesSeparateTextAndRepostKeys() throws {
        let bytes = Data(#"{"items":[{"id_str":"100","type":"DYNAMIC_TYPE_DRAW","modules":{"module_author":{"mid":1,"name":"UP","pub_ts":100},"module_dynamic":{"desc":{"text":"新图片"}}}},{"id_str":"101","type":"DYNAMIC_TYPE_FORWARD","modules":{"module_author":{"mid":1,"name":"UP","pub_ts":101},"module_dynamic":{"desc":{"text":"转发推荐"}}},"orig":{"modules":{"module_dynamic":{"major":{"archive":{"title":"原视频"}}}}}},{"id_str":"102","type":"DYNAMIC_TYPE_WORD","modules":{"module_author":{"mid":1,"pub_ts":102},"module_dynamic":{"major":{"opus":{"summary":{"text":"新格式正文"}}}}}}]}"#.utf8)
        let parsed = BiliClient.parseDynamicItems(try JSONDecoder().decode(DynFeedData.self, from: bytes))
        XCTAssertEqual(parsed.map(\.contentKind), [.textDynamic, .repost, .textDynamic])
        XCTAssertEqual(parsed[0].bvid, "dynamic:100")
        XCTAssertEqual(parsed[0].targetURL, "https://t.bilibili.com/100")
        XCTAssertTrue(parsed[1].content?.contains("原视频") == true)
        XCTAssertEqual(parsed[2].content, "新格式正文")
    }

    func testVideoClassificationKeepsSharedVideoAsUpload() {
        let upload = VideoItem(bvid: "BVsame", title: "video", author: "UP", mid: 1, pubdate: 100, cover: "")
        let dynamic = VideoItem(bvid: "BVsame", title: "video", author: "UP", mid: 1, pubdate: 101, cover: "", kind: .dynamicVideo)
        let exclusive = VideoItem(bvid: "BVdynamic", title: "short", author: "UP", mid: 1, pubdate: 102, cover: "", kind: .dynamicVideo)
        let merged = VideoSources.merge(uploads: [upload], dynamics: [dynamic, exclusive])
        XCTAssertEqual(merged.map(\.contentKind), [.upload, .dynamicVideo])
        var preferences = PushContentPreferences()
        preferences.uploads = false
        XCTAssertFalse(preferences.allows(merged[0].contentKind, publishedAt: merged[0].pubdate))
        XCTAssertTrue(preferences.allows(merged[1].contentKind, publishedAt: merged[1].pubdate))
    }

    private func room(status: Int, time: Int, title: String = "测试直播") throws -> LiveRoom {
        let json: [String: Any] = ["room_id": 123, "live_status": status, "live_time": time, "title": title]
        return try JSONDecoder().decode(LiveRoom.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testLiveBaselineRestartAndNewSession() throws {
        let alreadyLive = LiveObservation.advance(previous: nil, room: try room(status: 1, time: 100), mid: 1, author: "UP", now: 101)
        XCTAssertNil(alreadyLive.event)
        let offline = LiveObservation.advance(previous: alreadyLive.state, room: try room(status: 0, time: 0), mid: 1, author: "UP", now: 200)
        let started = LiveObservation.advance(previous: offline.state, room: try room(status: 1, time: 300), mid: 1, author: "UP", now: 301)
        XCTAssertEqual(started.event?.contentKind, .live)
        XCTAssertEqual(started.event?.targetURL, "https://live.bilibili.com/123")
        var acknowledged = started.state
        acknowledged.pendingEvent = nil
        let restored = try JSONDecoder().decode(LiveObservation.self, from: JSONEncoder().encode(acknowledged))
        let same = LiveObservation.advance(previous: restored, room: try room(status: 1, time: 300), mid: 1, author: "UP", now: 400)
        XCTAssertNil(same.event)
        let next = LiveObservation.advance(previous: same.state, room: try room(status: 1, time: 500), mid: 1, author: "UP", now: 501)
        XCTAssertNotEqual(started.event?.bvid, next.event?.bvid)
        XCTAssertNotNil(next.event)
        let replay = LiveObservation.advance(previous: next.state, room: try room(status: 2, time: 500), mid: 1, author: "UP", now: 600)
        XCTAssertFalse(replay.state.isLive)
        XCTAssertEqual(replay.event?.bvid, next.event?.bvid) // unacknowledged event stays durable, replay doesn't create one
    }

    func testFirstPollCanDetectOpeningAfterEnableTime() throws {
        let afterEnable = LiveObservation.advance(previous: nil, room: try room(status: 1, time: 100),
            mid: 1, author: "UP", now: 101, startedAfter: 90)
        XCTAssertNotNil(afterEnable.event)
        let alreadyLive = LiveObservation.advance(previous: nil, room: try room(status: 1, time: 100),
            mid: 1, author: "UP", now: 120, startedAfter: 110)
        XCTAssertNil(alreadyLive.event)
    }

    func testLiveTemplateAndNotificationLinks() throws {
        let baseline = LiveObservation.advance(previous: nil, room: try room(status: 0, time: 0), mid: 1, author: "小明", now: 1)
        let event = try XCTUnwrap(LiveObservation.advance(previous: baseline.state, room: try room(status: 1, time: 100), mid: 1, author: "小明", now: 101).event)
        var settings = Settings()
        settings.liveTemplate = "{author}开播啦：{title}！房间{room_id}\\n{url}"
        let rendered = settings.render(event)
        XCTAssertTrue(rendered.contains("小明开播啦：测试直播！房间123"))
        XCTAssertTrue(rendered.contains("https://live.bilibili.com/123"))
        for link in ["https://live.bilibili.com/123", "https://t.bilibili.com/100", "https://www.bilibili.com/video/BVtest"] {
            XCTAssertEqual(BarkNotifier.notificationLink(in: ["title", link]), link)
        }
        XCTAssertNil(BarkNotifier.notificationLink(in: ["https://live.bilibili.com.evil.test/123"]))
    }

    func testCustomTemplateStillOpensLiveRoomWithoutURLPlaceholder() throws {
        let request = try BarkNotifier(key: "offline-test-key").request(text: "小明开始直播啦", targetURL: URL(string: "https://live.bilibili.com/123"))
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "url" })?.value, "https://live.bilibili.com/123")
    }

    func testNoRoomEmptyArrayIsAccepted() throws {
        let data = try JSONDecoder().decode(LiveStatusData.self, from: Data("[]".utf8))
        XCTAssertTrue(data.rooms.isEmpty)
    }
}
