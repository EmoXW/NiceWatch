import Foundation
import AppKit

// MARK: - 通知通道协议（
// 说明：iMessage 通道已移除——发给自己的 iMessage 会让 Mac 上的「信息」自动打开
// 并标记已读，已读状态跨设备同步后 iPhone 就不再弹通知，达不到通知的目的。
// 现在唯一通道是 Bark。

protocol Notifier {
    var name: String { get }
    func send(text: String) async throws
}

enum NotifierError: LocalizedError {
    case notConfigured
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有填写 Bark 推送 key（在 Bark App 里复制）"
        case .http(let code, let body):
            return "Bark 返回 HTTP \(code)：\(body)"
        }
    }
}

/// Bark：一条 HTTPS 请求直接推送到 iPhone 通知中心。
/// 不存在「已读同步」问题，是 iMessage 的可靠备选。
/// 服务地址形如 https://api.day.app/<key>/<title>/<body>
final class BarkNotifier: Notifier {

    let name = "Bark"

    private let key: String
    private let server: String

    /// 路径段允许的字符（保留 - . _ ~ 与字母数字，其余全部百分号编码）
    private static let pathSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    init(key: String, server: String = "https://api.day.app") {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        self.server = s.isEmpty ? "https://api.day.app" : s
    }

    /// Bark 的 key 可能包含设备 key，也可能用户直接粘贴了完整 URL
    private static func parse(_ raw: String) -> (server: String, key: String)? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("http"), let url = URL(string: t) {
            let parts = url.path.split(separator: "/").map(String.init)
            guard let last = parts.last, !last.isEmpty else { return nil }
            var comps = URLComponents()
            comps.scheme = url.scheme
            comps.host = url.host
            if let port = url.port { comps.port = port }
            let server = comps.string ?? "https://api.day.app"
            return (server, last)
        }
        return ("https://api.day.app", t)
    }

    func send(text: String) async throws {
        guard let parsed = Self.parse(key) else { throw NotifierError.notConfigured }

        let allLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let title = allLines.first ?? "NiceWatch"
        let link = allLines.first { $0.hasPrefix("https://www.bilibili.com/video/") } ?? ""

        // 链接只通过 url 参数提供（点击通知即打开），
        // 正文里要把这条裸链接剔除，否则通知里会显示两行一模一样的链接。
        let bodyLines = allLines.dropFirst().filter { $0 != link }
        var body = bodyLines.joined(separator: "\n")
        if body.isEmpty { body = title }

        // 注意：路径段必须在 query 之前拼好。
        // 若先取带 query 的 URL 再往后追加，路径段会被塞进 query，Bark 端会显示 empty message。
        var pathComps = URLComponents()
        pathComps.scheme = URL(string: parsed.server)?.scheme
        pathComps.host = URL(string: parsed.server)?.host
        if let port = URL(string: parsed.server)?.port { pathComps.port = port }
        let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: Self.pathSafe) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: Self.pathSafe) ?? ""
        pathComps.path = "/\(parsed.key)/\(encodedTitle)/\(encodedBody)"
        pathComps.percentEncodedPath = "/\(parsed.key)/\(encodedTitle)/\(encodedBody)"

        var items = [
            URLQueryItem(name: "group", value: "NiceWatch"),
            URLQueryItem(name: "sound", value: "minuet"),
            URLQueryItem(name: "level", value: "timeSensitive"),
            URLQueryItem(name: "autoCopy", value: "1"),
        ]
        if !link.isEmpty { items.append(URLQueryItem(name: "url", value: link)) }
        pathComps.queryItems = items

        guard let final = pathComps.url else { throw NotifierError.notConfigured }

        var req = URLRequest(url: final)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let bodyText = String(data: data.prefix(200), encoding: .utf8) ?? ""
        guard code == 200 else { throw NotifierError.http(code, bodyText) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let c = obj["code"] as? Int, c != 200 {
            throw NotifierError.http(c, bodyText)
        }
    }
}
