import Foundation

// MARK: - B站数据模型

/// 统一通知内容，保留原视频字段以兼容历史数据。
struct VideoItem: Codable, Identifiable, Hashable {
    let bvid: String
    let title: String
    let author: String
    let mid: Int64
    let pubdate: Int          // Unix 秒级时间戳，展示时按本地时区转换
    let cover: String
    var kind: ContentKind? = nil
    var link: String? = nil
    var content: String? = nil
    var roomID: Int? = nil
    var contentKind: ContentKind { kind ?? .upload }
    var coverURL: URL? { URL(string: cover.hasPrefix("//") ? "https:" + cover : cover) }

    var id: String { bvid }
    var videoURL: URL? { URL(string: targetURL) }
    var targetURL: String { link ?? "https://www.bilibili.com/video/\(bvid)" }
    var pubDate: Date { Date(timeIntervalSince1970: TimeInterval(pubdate)) }
}

/// 被监控的 UP 主
struct MonitoredUP: Codable, Identifiable, Hashable {
    var mid: Int64
    var name: String
    var face: String
    var enabled: Bool = true
    var addedAt: Date = Date()
    /// 建立基线时已知的最新发布时间，用于判定"新"
    var baselinePubdate: Int = 0
    /// 最近一次成功检查到的时间
    var lastSeenAt: Date?
    /// 最近一次推送的时间
    var lastNotifiedAt: Date?
    /// 连续失败次数（用于指数退避）。
    /// 必须是可选类型：Swift 合成的 Decodable 不会使用属性默认值，
    /// 旧数据文件缺少该键时会导致整份数据解码失败。
    var consecutiveFailures: Int?
    /// 在此时间之前不再请求该 UP（风控退避）
    var backoffUntil: Date?
    var liveObservation: LiveObservation?

    /// 新增来源也只推送开始监控之后的视频，避免把旧动态当成新投稿。
    var notificationFloor: Int {
        max(baselinePubdate, Int(addedAt.timeIntervalSince1970))
    }

    var id: Int64 { mid }
    var faceURL: URL? { URL(string: face.hasPrefix("//") ? "https:" + face : face) }
}

/// 已发现内容的记录（去重 + 推送状态）
struct SeenVideo: Codable, Identifiable, Hashable {
    enum State: String, Codable {
        case baseline        // 建立基线时已存在，不推送
        case pending         // 已发现，待推送
        case notified        // 已成功推送
        case failed          // 推送失败且重试用尽
        case muted           // 命中静默规则，不推送
    }

    var bvid: String
    var mid: Int64
    var author: String
    var title: String
    var pubdate: Int
    var detectedAt: Date
    var state: State = .pending
    var notifiedAt: Date?
    var attempts: Int = 0
    var lastError: String?
    var kind: ContentKind? = nil
    var link: String? = nil
    var content: String? = nil
    var roomID: Int? = nil
    var contentKind: ContentKind { kind ?? .upload }

    var id: String { bvid }
    var videoURL: URL? { URL(string: link ?? "https://www.bilibili.com/video/\(bvid)") }
    var pubDate: Date { Date(timeIntervalSince1970: TimeInterval(pubdate)) }
}

/// 账号信息
struct AccountInfo: Codable, Equatable {
    var mid: Int64
    var uname: String
    var face: String
    var level: Int
}

/// 用户设置
struct Settings: Codable {
    /// 已弃用：iMessage 通道因「Mac 自动标记已读导致手机不通知」被移除，
    /// 字段保留只为兼容旧数据文件的解码。
    var imessageHandle: String = ""
    var channel: String? = nil
    /// Bark 推送 key（https://api.day.app/<key>）
    var barkKey: String? = nil
    /// 检查间隔（秒）。滑块步进 30 秒，下限 30 秒（不允许 0），上限 30 分钟。
    var intervalSeconds: Int = 300

    static let intervalMin = 30
    static let intervalMax = 1800
    static let intervalStep = 30

    /// 智能显示：整分钟显示「N 分钟」，否则显示「N 秒」
    static func intervalLabel(_ seconds: Int) -> String {
        if seconds % 60 == 0 { return "\(seconds / 60) 分钟" }
        return "\(seconds) 秒"
    }

    var intervalClamped: Int {
        min(Self.intervalMax, max(Self.intervalMin, intervalSeconds))
    }
    var quietStartHour: Int? = nil
    var quietEndHour: Int? = nil
    var notifyOnLoginExpiry: Bool = true
    var pushContent: PushContentPreferences? = nil
    var liveTemplate: String? = nil
    var contentPreferences: PushContentPreferences {
        get { pushContent ?? PushContentPreferences() }
        set { pushContent = newValue }
    }
    static let defaultLiveTemplate = "🔴 {author} 开播了\n{title}\n{url}"
    var liveTemplateValue: String { liveTemplate ?? Self.defaultLiveTemplate }
    var template: String = "🎬 {author} 更新了\n《{title}》\n{url}"

    /// 当前唯一的通知通道：Bark
    var useBark: Bool {
        !(barkKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func render(_ v: VideoItem) -> String {
        let format: String
        if v.contentKind == .live {
            format = liveTemplateValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultLiveTemplate : liveTemplateValue
        }
        else if !v.contentKind.isVideo && template == Settings().template {
            format = "{author} 发布了{type}\n{content}\n{url}"
        } else { format = template }
        return format
            .replacingOccurrences(of: "{author}", with: v.author)
            .replacingOccurrences(of: "{title}", with: v.title)
            .replacingOccurrences(of: "{type}", with: v.contentKind.title)
            .replacingOccurrences(of: "{content}", with: v.content ?? v.title)
            .replacingOccurrences(of: "{room_id}", with: v.roomID.map(String.init) ?? "")
            .replacingOccurrences(of: "{bvid}", with: v.contentKind.isVideo ? v.bvid : "")
            .replacingOccurrences(of: "{url}", with: v.targetURL)
    }
}

/// 一次检查的结果状态，用于 UI 展示
enum MonitorStatus: Equatable {
    case idle
    case checking
    case ok
    case loginExpired
    case riskControlled(String)
    case networkError(String)

    var text: String {
        switch self {
        case .idle: return "待机"
        case .checking: return "检查中…"
        case .ok: return "正常"
        case .loginExpired: return "登录已失效"
        case .riskControlled(let m): return "风控：\(m)"
        case .networkError(let m): return "网络错误：\(m)"
        }
    }

    var isHealthy: Bool {
        if case .ok = self { return true }
        if case .idle = self { return true }
        return false
    }
}

/// 应用持久化数据（cookie 单独存 Keychain）
struct PersistedData: Codable {
    var ups: [MonitoredUP] = []
    var seen: [String: SeenVideo] = [:]
    var settings: Settings = Settings()
    var account: AccountInfo?
}
