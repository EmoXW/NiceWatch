import Foundation

/// 简单的运行日志：同时写 stderr、NSLog 与本地文件，便于外部排查
/// 文件位置：~/Library/Application Support/NiceWatch/app.log
enum AppLog {

    static let dirURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("NiceWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var fileURL: URL { dirURL.appendingPathComponent("app.log") }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let queue = DispatchQueue(label: "nicewatch.log")

    static func info(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        NSLog("NiceWatch: %@", message)
        // 便于从终端直接运行二进制时观察
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let url = fileURL
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url)
                }
            } catch {
                NSLog("NiceWatch: 写日志失败 %@", String(describing: error))
            }
        }
    }

    /// 清空日志（自检时调用）
    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
