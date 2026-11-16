import Foundation
import AppKit

/// 开机自启：用 LaunchAgent 实现。
///
/// 为什么不用 SMAppService：
/// 本应用以 ad-hoc 签名放在工作目录里自用，SMAppService 对签名与安装位置更挑剔，
/// 而 LaunchAgent plist 在任何位置都稳定可用，且易于排查/手动删除。
enum LaunchAtLogin {

    static let label = "com.emoxw.nicewatch"

    /// 早期版本使用过的 label，切换时一并清理，避免两个 LaunchAgent 同时拉起应用
    private static let legacyLabel = "com.wyh.nicewatch"

    private static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var legacyURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    /// 卸载并删除旧 label 的注册（幂等）
    private static func removeLegacy() {
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        _ = run("/bin/launchctl", ["unload", legacyURL.path])
        try? FileManager.default.removeItem(at: legacyURL)
        AppLog.info("已清理旧版本开机自启项：\(legacyURL.path)")
    }

    /// 当前可执行文件路径（.app 内部）
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func enable() -> Result<Void, Error> {
        let path = executablePath
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(NSError(domain: "NiceWatch", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "找不到可执行文件：\(path)"]))
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(path)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
            <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
        do {
            let dir = plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 先卸载可能存在的旧注册，避免读到过期路径
            _ = run("/bin/launchctl", ["unload", plistURL.path])
            removeLegacy()
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
            // 注意：这里不调用 launchctl load。
            // 因为 RunAtLoad=true 会在 load 的瞬间立刻再拉起一个实例，
            // 而此刻应用本身正在运行，用户会看到「刚打开开关就又启动一次」。
            // 只写 plist，登录时 launchd 会自动加载并启动。
            AppLog.info("已启用开机自启（下次登录生效）：\(plistURL.path)")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    static func disable() -> Result<Void, Error> {
        _ = run("/bin/launchctl", ["unload", plistURL.path])
        removeLegacy()
        do {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
            AppLog.info("已关闭开机自启")
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "launchctl 执行失败：\(error.localizedDescription)"
        }
    }
}
