import Foundation

/// 监控接口单独抽象，离线测试无需登录或发送真实通知。
protocol MonitoringAPI {
    func nav() async throws -> AccountInfo?
    func spaceVideos(mid: Int64, page: Int, pageSize: Int) async throws -> [VideoItem]
    func spaceDynamicVideos(mid: Int64) async throws -> [VideoItem]
    func spaceDynamicItems(mid: Int64) async throws -> [VideoItem]
    func liveRoom(mid: Int64) async throws -> LiveRoom?
    func dynamicVideoFeed() async throws -> [VideoItem]
}

extension BiliClient: MonitoringAPI {}

extension MonitoringAPI {
    func spaceDynamicItems(mid: Int64) async throws -> [VideoItem] { try await spaceDynamicVideos(mid: mid) }
    func liveRoom(mid: Int64) async throws -> LiveRoom? { nil }
}

enum VideoSources {
    /// 同一 BVID 以投稿接口的正式发布时间为准，避免动态创建时间的几秒偏差。
    static func merge(uploads: [VideoItem], dynamics: [VideoItem]) -> [VideoItem] {
        let dynamicItems = dynamics.map { value -> VideoItem in
            var item = value
            if item.kind == nil { item.kind = .dynamicVideo }
            return item
        }
        var result = Dictionary(dynamicItems.map { ($0.bvid, $0) }, uniquingKeysWith: { first, _ in first })
        for var video in uploads {
            video.kind = .upload
            result[video.bvid] = video
        }
        return result.values.sorted { $0.pubdate < $1.pubdate }
    }
}
