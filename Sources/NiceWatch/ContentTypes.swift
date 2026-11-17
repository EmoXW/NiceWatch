import Foundation

enum ContentKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case upload, dynamicVideo, textDynamic, repost, live
    var id: String { rawValue }
    var title: String {
        switch self {
        case .upload: return "投稿视频"
        case .dynamicVideo: return "动态视频"
        case .textDynamic: return "图文动态"
        case .repost: return "转发动态"
        case .live: return "直播开播"
        }
    }
    var detail: String {
        switch self {
        case .upload: return "出现在 UP 投稿列表中的视频"
        case .dynamicVideo: return "只出现在空间动态中的视频；与投稿按 BVID 去重"
        case .textDynamic: return "原创文字、图片和专栏动态；通知展示正文摘要"
        case .repost: return "UP 转发其他内容的动态"
        case .live: return "从未开播变为直播中时提醒一次"
        }
    }
    var isVideo: Bool { self == .upload || self == .dynamicVideo }
}

struct PushContentPreferences: Codable {
    // 新设置整体通过 Settings 的可选字段兼容旧数据。
    var uploads = true
    var dynamicVideos = true
    var textDynamics = false
    var reposts = false
    var live = false
    var enabledSince: [String: Int] = [:]

    func isEnabled(_ kind: ContentKind) -> Bool {
        switch kind {
        case .upload: return uploads
        case .dynamicVideo: return dynamicVideos
        case .textDynamic: return textDynamics
        case .repost: return reposts
        case .live: return live
        }
    }
    var hasDynamicContent: Bool { dynamicVideos || textDynamics || reposts }
    var hasVideo: Bool { uploads || dynamicVideos }
    var hasAny: Bool { ContentKind.allCases.contains(where: isEnabled) }

    mutating func set(_ kind: ContentKind, enabled: Bool, now: Int) {
        guard enabled != isEnabled(kind) else { return }
        switch kind {
        case .upload: uploads = enabled
        case .dynamicVideo: dynamicVideos = enabled
        case .textDynamic: textDynamics = enabled
        case .repost: reposts = enabled
        case .live: live = enabled
        }
        if enabled { enabledSince[kind.rawValue] = now }
    }
    func allows(_ kind: ContentKind, publishedAt: Int) -> Bool {
        isEnabled(kind) && publishedAt > (enabledSince[kind.rawValue] ?? 0)
    }
}

struct LiveRoom: Decodable {
    let roomID: FlexibleInt?
    let liveStatus: FlexibleInt?
    let liveTime: FlexibleInt?
    let title: String?
    let uname: String?
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", liveStatus = "live_status", liveTime = "live_time", title, uname
    }
    var isLive: Bool { liveStatus?.value == 1 && (roomID?.value ?? 0) > 0 }
}

struct LiveStatusData: Decodable {
    let rooms: [String: LiveRoom]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([String: LiveRoom].self) { rooms = values; return }
        // 没有直播间时，接口可能用空数组代替空对象。
        if let values = try? container.decode([JSONValue].self), values.isEmpty { rooms = [:]; return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "直播状态格式异常")
    }
}

/// 与监控名单一起落盘，重启不会把持续中的直播再次当作新开播。
struct LiveObservation: Codable, Hashable {
    let isLive: Bool
    let roomID: Int
    let startedAt: Int
    let session: Int
    var pendingEvent: VideoItem? = nil

    static func advance(previous: LiveObservation?, room: LiveRoom?, mid: Int64, author: String,
                        now: Int, startedAfter: Int? = nil) -> (state: LiveObservation, event: VideoItem?) {
        let online = room?.isLive == true
        let roomID = room?.roomID?.value ?? 0
        let startedAt = online ? (room?.liveTime?.value ?? 0) : 0
        let previousStart = previous?.startedAt ?? 0
        let restarted = previous?.isLive == true && online &&
            ((startedAt > 0 && previousStart > 0 && startedAt > previousStart) || roomID != previous?.roomID)
        let firstNewOpening = previous == nil && online && startedAt > 0 &&
            startedAfter.map { startedAt > $0 } == true
        let opened = firstNewOpening || (previous != nil && online && (previous?.isLive == false || restarted))
        let session = (previous?.session ?? 0) + (opened ? 1 : 0)
        var state = LiveObservation(isLive: online, roomID: roomID,
                                    startedAt: startedAt, session: session)
        state.pendingEvent = previous?.pendingEvent
        // 只有可确认是启用之后的新开播才提醒；其余首次观察只建立基线。
        guard opened else { return (state, state.pendingEvent) }
        let suffix = startedAt > 0 ? String(startedAt) : "session-\(session)"
        let event = VideoItem(bvid: "live:\(mid):\(roomID):\(suffix)",
                              title: room?.title ?? "直播中", author: author, mid: mid,
                              pubdate: startedAt > 0 ? startedAt : now, cover: "",
                              kind: .live, link: "https://live.bilibili.com/\(roomID)",
                              content: room?.title, roomID: roomID)
        state.pendingEvent = event
        return (state, event)
    }
}
