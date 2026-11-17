import Foundation
import CryptoKit

// MARK: - 错误

enum BiliError: LocalizedError {
    case http(Int)
    case api(code: Int, message: String)
    case decoding(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .http(let s): return "HTTP \(s)"
        case .api(let c, let m): return "[\(c)] \(m)"
        case .decoding(let d): return "解析失败：\(d)"
        case .network(let m): return m
        }
    }

    /// 是否属于"登录态失效"
    var isLoginExpired: Bool {
        if case .api(let code, _) = self { return code == -101 || code == -111 }
        return false
    }

    /// 是否属于"风控/限流"
    var isRiskControl: Bool {
        if case .api(let code, _) = self { return code == -352 || code == -412 || code == -799 }
        if case .http(let s) = self { return s == 412 || s == 429 }
        return false
    }
}

// MARK: - 响应信封

private struct Envelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
}

private struct EmptyData: Decodable {}

// MARK: - 各接口的 data 结构

struct WbiImg: Decodable {
    let imgUrl: String
    let subUrl: String

    enum CodingKeys: String, CodingKey {
        case imgUrl = "img_url"
        case subUrl = "sub_url"
    }
}

struct NavData: Decodable {
    let isLogin: Bool?
    let uname: String?
    let mid: Int64?
    let face: String?
    let wbiImg: WbiImg?

    enum CodingKeys: String, CodingKey {
        case isLogin, uname, mid, face
        case wbiImg = "wbi_img"
    }
}

struct QRGenData: Decodable {
    let url: String
    let qrcodeKey: String

    enum CodingKeys: String, CodingKey {
        case url
        case qrcodeKey = "qrcode_key"
    }
}

struct QRPollData: Decodable {
    let url: String?
    let code: Int?
    let message: String?
}

struct FollowingsData: Decodable {
    let list: [UPBrief]?
    let total: Int?
}

struct UPBrief: Decodable {
    let mid: Int64
    let uname: String?
    let face: String?
    let sign: String?
}

struct ArcSearchData: Decodable {
    let list: ArcList?
    let page: ArcPage?
}

struct ArcList: Decodable { let vlist: [ArcVideo]? }
struct ArcPage: Decodable { let count: Int? }

struct ArcVideo: Decodable {
    let bvid: String
    let title: String?
    let created: Int?
    let author: String?
    let mid: Int64?
    let pic: String?
    let length: String?
}

/// B站部分字段类型不固定（"123" 或 123），统一兼容
enum FlexibleInt: Decodable {
    case number(Int)
    case text(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .number(i); return }
        if let s = try? c.decode(String.self) { self = .text(s); return }
        self = .number(0)
    }

    var value: Int {
        switch self {
        case .number(let i): return i
        case .text(let s): return Int(s) ?? 0
        }
    }
}

struct DynFeedData: Decodable { let items: [DynItem]? }

struct DynItem: Decodable {
    let type: String?
    let idStr: String?
    let modules: DynModules?
    let orig: DynOriginal?
    enum CodingKeys: String, CodingKey { case type, modules, orig; case idStr = "id_str" }
}
struct DynOriginal: Decodable { let modules: DynModules? }
struct DynDescription: Decodable { let text: String? }
struct DynOpus: Decodable { let summary: DynDescription?; let title: String? }
struct DynArticle: Decodable { let title: String?; let desc: String? }

struct DynModules: Decodable {
    let moduleAuthor: DynAuthor?
    let moduleDynamic: DynDynamic?

    enum CodingKeys: String, CodingKey {
        case moduleAuthor = "module_author"
        case moduleDynamic = "module_dynamic"
    }
}

struct DynAuthor: Decodable {
    let mid: Int64?
    let name: String?
    let face: String?
    let pubTs: FlexibleInt?

    enum CodingKeys: String, CodingKey {
        case mid, name, face
        case pubTs = "pub_ts"
    }
}

struct DynDynamic: Decodable { let major: DynMajor?; let desc: DynDescription? }
struct DynMajor: Decodable { let archive: DynArchive?; let opus: DynOpus?; let article: DynArticle? }

struct DynArchive: Decodable {
    let bvid: String?
    let title: String?
    let cover: String?
    let durationText: String?

    enum CodingKeys: String, CodingKey {
        case bvid, title, cover
        case durationText = "duration_text"
    }
}

struct FingerData: Decodable {
    let b3: String?
    let b4: String?
    enum CodingKeys: String, CodingKey {
        case b3 = "b_3"
        case b4 = "b_4"
    }
}

// MARK: - 客户端

/// B站 API 客户端：手动管理 Cookie，避免与系统 cookie 存储互相污染。
final class BiliClient {

    static let shared = BiliClient()

    /// 当前会话 cookie
    private(set) var cookies: [String: String] = [:]

    private var imgKey: String?
    private var subKey: String?
    private var wbiFetchedAt: Date?
    private var cachedMid: Int64?

    private let session: URLSession

    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static let mixinTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
    ]

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    // MARK: Cookie 管理

    func loadCookies(_ c: [String: String]) {
        cookies = c
    }

    func clearCookies() {
        cookies = [:]
        imgKey = nil
        subKey = nil
        wbiFetchedAt = nil
        cachedMid = nil
    }

    var hasSession: Bool { !(cookies["SESSDATA"] ?? "").isEmpty }
    var csrf: String { cookies["bili_jct"] ?? "" }

    private var cookieHeader: String {
        cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    private func absorbCookies(from response: HTTPURLResponse) {
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie") else { return }
        // 简单切分：按逗号后紧跟 name= 的边界拆成多段
        let parts = raw.components(separatedBy: ", ")
        for part in parts {
            let first = part.components(separatedBy: ";").first ?? part
            let kv = first.components(separatedBy: "=")
            guard kv.count >= 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv.dropFirst().joined(separator: "=")
            if !k.isEmpty, !v.isEmpty { cookies[k] = v }
        }
    }

    // MARK: 底层请求

    private func rawRequest(_ url: URL,
                            referer: String,
                            apiHost: Bool = true) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if apiHost { req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin") }
        if !cookies.isEmpty { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }

        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                absorbCookies(from: http)
                if !(200..<300).contains(http.statusCode) {
                    throw BiliError.http(http.statusCode)
                }
            }
            return data
        } catch let e as BiliError {
            throw e
        } catch {
            throw BiliError.network(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw BiliError.decoding("\(error.localizedDescription) | \(preview)")
        }
    }

    /// 发起请求并检查业务 code
    private func call<T: Decodable>(_ url: URL, referer: String, as type: T.Type) async throws -> T? {
        let data = try await rawRequest(url, referer: referer)
        let env = try decode(Envelope<T>.self, from: data)
        guard env.code == 0 else {
            throw BiliError.api(code: env.code, message: env.message ?? "未知错误")
        }
        return env.data
    }

    // MARK: 工具

    private static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static func queryString(_ params: [(String, String)]) -> String {
        params.map { "\(q($0.0))=\(q($0.1))" }.joined(separator: "&")
    }

    private static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: WBI 签名

    /// 拉取（并缓存）wbi 密钥，算出 mixin key
    private func mixinKey(forceRefresh: Bool = false) async throws -> String {
        let stale = wbiFetchedAt.map { Date().timeIntervalSince($0) > 1800 } ?? true
        if !forceRefresh, !stale, let ik = imgKey, let sk = subKey {
            return Self.buildMixin(ik, sk)
        }
        let data = try await rawRequest(URL(string: "https://api.bilibili.com/x/web-interface/nav")!,
                                        referer: "https://www.bilibili.com/")
        let env = try decode(Envelope<NavData>.self, from: data)
        guard let wi = env.data?.wbiImg else {
            throw BiliError.api(code: env.code, message: env.message ?? "拿不到 WBI 密钥")
        }
        let ik = wi.imgUrl.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
        let sk = wi.subUrl.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? ""
        guard ik.count == 32, sk.count == 32 else {
            throw BiliError.decoding("WBI 密钥格式异常")
        }
        imgKey = ik; subKey = sk; wbiFetchedAt = Date()
        return Self.buildMixin(ik, sk)
    }

    private static func buildMixin(_ imgKey: String, _ subKey: String) -> String {
        let orig = Array(imgKey + subKey)
        var out = ""
        for idx in mixinTab where idx < orig.count {
            out.append(orig[idx])
        }
        return String(out.prefix(32))
    }

    /// 给参数加 wts + w_rid，返回完整 query string
    private func signedQuery(_ params: [(String, String)], mixin: String) -> String {
        var p = params
        p.append(("wts", String(Int(Date().timeIntervalSince1970))))
        let sorted = p.sorted { $0.0 < $1.0 }
        let cleaned: [(String, String)] = sorted.map { k, v in
            let f = v.filter { !"!'()*".contains($0) }
            return (k, f)
        }
        let query = Self.queryString(cleaned)
        let rid = Self.md5Hex(query + mixin)
        return query + "&w_rid=" + rid
    }

    // MARK: - 登录

    /// 生成二维码
    func qrGenerate() async throws -> QRGenData {
        let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!
        guard let d = try await call(url, referer: "https://passport.bilibili.com/", as: QRGenData.self) else {
            throw BiliError.decoding("二维码数据为空")
        }
        return d
    }

    enum QRState: Equatable {
        case waiting          // 未扫码
        case scanned          // 已扫码待确认
        case success          // 已确认
        case expired          // 已过期
        case failed(String)

        var hint: String {
            switch self {
            case .waiting: return "请用手机 B站 App 扫码"
            case .scanned: return "已扫码，请在手机上点击「确认登录」"
            case .success: return "登录成功"
            case .expired: return "二维码已过期，正在刷新…"
            case .failed(let m): return "登录失败：\(m)"
            }
        }
    }

    /// 轮询扫码状态；成功时把 cookie 写进 self.cookies
    func qrPoll(key: String) async throws -> QRState {
        var comps = URLComponents(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll")!
        comps.queryItems = [
            URLQueryItem(name: "qrcode_key", value: key),
            URLQueryItem(name: "source", value: "main-fe-header"),
        ]
        let data = try await rawRequest(comps.url!, referer: "https://www.bilibili.com/")
        let env = try decode(Envelope<QRPollData>.self, from: data)
        guard env.code == 0, let d = env.data else {
            throw BiliError.api(code: env.code, message: env.message ?? "轮询失败")
        }
        switch d.code {
        case 0:
            // 从 crossDomain url 里解析 cookie
            if let u = d.url, let qs = URLComponents(string: u)?.queryItems {
                for item in qs where ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"].contains(item.name) {
                    if let v = item.value, !v.isEmpty { cookies[item.name] = v }
                }
            }
            return hasSession ? .success : .failed("未拿到 SESSDATA")
        case 86101:
            return .waiting
        case 86090:
            return .scanned
        case 86038:
            return .expired
        default:
            return .failed(d.message ?? "状态码 \(d.code ?? -1)")
        }
    }

    /// 补齐设备指纹 cookie（空间接口需要）
    func warmFingerprint() async {
        do {
            let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi")!
            let data = try await rawRequest(url, referer: "https://www.bilibili.com/")
            let env = try decode(Envelope<FingerData>.self, from: data)
            if let b3 = env.data?.b3, !b3.isEmpty { cookies["buvid3"] = b3 }
            if let b4 = env.data?.b4, !b4.isEmpty { cookies["buvid4"] = b4 }
            if cookies["b_nut"] == nil {
                cookies["b_nut"] = String(Int(Date().timeIntervalSince1970))
            }
        } catch {
            // 指纹失败不致命，继续
        }
    }

    // MARK: - 账号

    func nav() async throws -> AccountInfo? {
        let url = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
        let data = try await rawRequest(url, referer: "https://www.bilibili.com/")
        let env = try decode(Envelope<NavData>.self, from: data)
        guard env.code == 0, let d = env.data else {
            throw BiliError.api(code: env.code, message: env.message ?? "nav 失败")
        }
        if let wi = d.wbiImg {
            imgKey = wi.imgUrl.components(separatedBy: "/").last?.components(separatedBy: ".").first
            subKey = wi.subUrl.components(separatedBy: "/").last?.components(separatedBy: ".").first
            wbiFetchedAt = Date()
        }
        guard d.isLogin == true, let mid = d.mid else { return nil }
        cachedMid = mid
        return AccountInfo(mid: mid,
                           uname: d.uname ?? "未知",
                           face: d.face ?? "",
                           level: 0)
    }

    /// cookie 是否需要刷新（服务端判定）
    func cookieNeedsRefresh() async -> Bool {
        do {
            let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/cookie/info")!
            let data = try await rawRequest(url, referer: "https://www.bilibili.com/")
            let env = try decode(Envelope<[String: JSONValue]>.self, from: data)
            return env.data?["refresh"]?.boolValue ?? false
        } catch {
            return false
        }
    }

    // MARK: - 关注列表

    func followings(vmid: Int64, page: Int = 1, pageSize: Int = 20) async throws -> (list: [UPBrief], total: Int) {
        var comps = URLComponents(string: "https://api.bilibili.com/x/relation/followings")!
        comps.queryItems = [
            URLQueryItem(name: "vmid", value: String(vmid)),
            URLQueryItem(name: "pn", value: String(page)),
            URLQueryItem(name: "ps", value: String(pageSize)),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "order_type", value: "attention"),
        ]
        let data = try await rawRequest(comps.url!,
                                        referer: "https://space.bilibili.com/\(vmid)/relation/followings")
        let env = try decode(Envelope<FollowingsData>.self, from: data)
        guard env.code == 0 else {
            throw BiliError.api(code: env.code, message: env.message ?? "关注列表失败")
        }
        return (env.data?.list ?? [], env.data?.total ?? 0)
    }

    // MARK: - 搜索 UP 主

    struct UserHit: Identifiable, Hashable {
        let mid: Int64
        let name: String
        let face: String
        let fans: Int
        var id: Int64 { mid }
        var faceURL: URL? { URL(string: face.hasPrefix("//") ? "https:" + face : face) }
    }

    private struct SearchData: Decodable {
        let result: [SearchUser]?
    }
    private struct SearchUser: Decodable {
        let mid: Int64?
        let uname: String?
        let upic: String?
        let fans: Int?
    }

    func searchUsers(keyword: String) async throws -> [UserHit] {
        let mixin = try await mixinKey()
        let params: [(String, String)] = [
            ("keyword", keyword),
            ("search_type", "bili_user"),
            ("page", "1"),
            ("page_size", "20"),
        ]
        var comps = URLComponents(string: "https://api.bilibili.com/x/web-interface/wbi/search/type")!
        comps.percentEncodedQuery = signedQuery(params, mixin: mixin)
        let data = try await rawRequest(comps.url!, referer: "https://search.bilibili.com/")
        let env = try decode(Envelope<SearchData>.self, from: data)
        guard env.code == 0 else {
            throw BiliError.api(code: env.code, message: env.message ?? "搜索失败")
        }
        return (env.data?.result ?? []).compactMap { u in
            guard let mid = u.mid else { return nil }
            return UserHit(mid: mid,
                           name: u.uname ?? "未知",
                           face: u.upic ?? "",
                           fans: u.fans ?? 0)
        }
    }

    // MARK: - 逐 UP 投稿列表与空间动态

    func spaceVideos(mid: Int64, page: Int = 1, pageSize: Int = 10) async throws -> [VideoItem] {
        let mixin = try await mixinKey()
        let params: [(String, String)] = [
            ("mid", String(mid)),
            ("ps", String(pageSize)),
            ("pn", String(page)),
            ("order", "pubdate"),
            ("platform", "web"),
            ("web_location", "1550101"),
            ("order_avoided", "true"),
        ]
        var comps = URLComponents(string: "https://api.bilibili.com/x/space/wbi/arc/search")!
        comps.percentEncodedQuery = signedQuery(params, mixin: mixin)
        let data = try await rawRequest(comps.url!,
                                        referer: "https://space.bilibili.com/\(mid)/video")
        let env = try decode(Envelope<ArcSearchData>.self, from: data)
        if env.code != 0 { throw BiliError.api(code: env.code, message: env.message ?? "投稿列表失败") }
        guard let vlist = env.data?.list?.vlist else {
            throw BiliError.decoding("投稿接口缺少 list.vlist，不能视为没有更新")
        }
        return vlist.compactMap { v in
            guard let created = v.created else { return nil }
            return VideoItem(bvid: v.bvid,
                             title: v.title ?? "",
                             author: v.author ?? "",
                             mid: v.mid ?? mid,
                             pubdate: created,
                             cover: v.pic ?? "")
        }
    }

    /// 动态视频不一定出现在投稿列表中；独立查询每位 UP，不依赖混合关注流的窗口。
    func spaceDynamicVideos(mid: Int64) async throws -> [VideoItem] {
        try await spaceDynamicItems(mid: mid).filter { $0.contentKind.isVideo }
    }

    func spaceDynamicItems(mid: Int64) async throws -> [VideoItem] {
        var comps = URLComponents(string: "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space")!
        comps.queryItems = [
            URLQueryItem(name: "host_mid", value: String(mid)),
            URLQueryItem(name: "timezone_offset", value: "-480"),
        ]
        let bytes = try await rawRequest(comps.url!, referer: "https://space.bilibili.com/\(mid)/dynamic")
        let envelope = try decode(Envelope<DynFeedData>.self, from: bytes)
        guard envelope.code == 0 else {
            throw BiliError.api(code: envelope.code, message: envelope.message ?? "空间动态失败")
        }
        guard envelope.data?.items != nil else {
            throw BiliError.decoding("空间动态缺少 items，不能视为没有更新")
        }
        return Self.parseDynamicItems(envelope.data).filter { $0.mid == mid }
    }

    /// 公开直播状态接口，live_status=1 为直播中，2 为轮播，不作为开播。
    func liveRoom(mid: Int64) async throws -> LiveRoom? {
        var comps = URLComponents(string: "https://api.live.bilibili.com/room/v1/Room/get_status_info_by_uids")!
        comps.queryItems = [URLQueryItem(name: "uids[]", value: String(mid))]
        let bytes = try await rawRequest(comps.url!, referer: "https://live.bilibili.com/", apiHost: false)
        let env = try decode(Envelope<LiveStatusData>.self, from: bytes)
        guard env.code == 0 else { throw BiliError.api(code: env.code, message: env.message ?? "直播状态失败") }
        guard let rooms = env.data else { throw BiliError.decoding("直播状态缺少 data") }
        return rooms.rooms[String(mid)]
    }

    // MARK: - 混合关注动态（所有逐 UP 来源都失败时的最后兜底）

    /// 一次请求返回所有关注 UP 的最新动态；只保留视频投稿
    func dynamicVideoFeed() async throws -> [VideoItem] {
        let params: [(String, String)] = [
            ("type", "video"),
            ("page", "1"),
            ("timezone_offset", "-480"),
            ("features", "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote"),
        ]
        var comps = URLComponents(string: "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all")!
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }

        var data: Data
        do {
            data = try await rawRequest(comps.url!, referer: "https://t.bilibili.com/")
            let env = try decode(Envelope<DynFeedData>.self, from: data)
            if env.code != 0 {
                // 失败则补签名重试
                throw BiliError.api(code: env.code, message: env.message ?? "")
            }
            return Self.parseFeed(env.data)
        } catch let e as BiliError where !e.isLoginExpired {
            // 签名重试
            let mixin = try await mixinKey(forceRefresh: true)
            comps.percentEncodedQuery = signedQuery(params, mixin: mixin)
            let retry = try await rawRequest(comps.url!, referer: "https://t.bilibili.com/")
            let env = try decode(Envelope<DynFeedData>.self, from: retry)
            if env.code != 0 { throw BiliError.api(code: env.code, message: env.message ?? "") }
            return Self.parseFeed(env.data)
        } catch {
            throw error
        }
    }

    static func parseFeed(_ data: DynFeedData?) -> [VideoItem] {
        parseDynamicItems(data).filter { $0.contentKind.isVideo }
    }

    static func parseDynamicItems(_ data: DynFeedData?) -> [VideoItem] {
        guard let items = data?.items else { return [] }
        return items.compactMap { item in
            guard let author = item.modules?.moduleAuthor, let mid = author.mid,
                  let published = author.pubTs?.value, published > 0 else { return nil }
            let dynamic = item.modules?.moduleDynamic
            if item.type == "DYNAMIC_TYPE_AV" {
                guard let archive = dynamic?.major?.archive,
                      let bvid = archive.bvid, !bvid.isEmpty else { return nil }
                return VideoItem(bvid: bvid, title: archive.title ?? "视频更新", author: author.name ?? "",
                                 mid: mid, pubdate: published, cover: archive.cover ?? "", kind: .dynamicVideo)
            }
            let kind: ContentKind
            switch item.type {
            case "DYNAMIC_TYPE_WORD", "DYNAMIC_TYPE_DRAW", "DYNAMIC_TYPE_ARTICLE", "DYNAMIC_TYPE_OPUS": kind = .textDynamic
            case "DYNAMIC_TYPE_FORWARD": kind = .repost
            default: return nil
            }
            guard let id = item.idStr, !id.isEmpty else { return nil }
            var text = dynamic?.desc?.text ?? dynamic?.major?.opus?.summary?.text ?? dynamic?.major?.article?.desc ?? ""
            if kind == .repost {
                let original = item.orig?.modules?.moduleDynamic
                let summary = original?.desc?.text ?? original?.major?.opus?.summary?.text ?? original?.major?.archive?.title ?? ""
                if !summary.isEmpty { text += "\n转发内容：" + summary }
            }
            text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            let title = dynamic?.major?.opus?.title ?? dynamic?.major?.article?.title ??
                (text.isEmpty ? kind.title : String(text.prefix(80)))
            return VideoItem(bvid: "dynamic:\(id)", title: title, author: author.name ?? "",
                             mid: mid, pubdate: published, cover: "", kind: kind,
                             link: "https://t.bilibili.com/\(id)", content: text)
        }
    }

}

// MARK: - 极简 JSON 值（用于只读个别字段）

enum JSONValue: Decodable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .null
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
