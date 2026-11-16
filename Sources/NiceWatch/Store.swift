import Foundation

/// JSON 文件持久化：~/Library/Application Support/NiceWatch/data.json
final class Store {

    var data: PersistedData
    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("NiceWatch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("data.json")

        guard let raw = try? Data(contentsOf: fileURL) else {
            data = PersistedData()
            return
        }
        // 读取必须与写入使用同一套日期策略，否则 Date 字段解码失败会静默清空全部数据
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            data = try dec.decode(PersistedData.self, from: raw)
        } catch {
            // 解码失败：先备份原文件，绝不静默丢弃用户数据
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            AppLog.info("数据文件解析失败，已备份到 \(backup.lastPathComponent)：\(error.localizedDescription)")
            data = PersistedData()
        }
    }

    var directoryURL: URL { fileURL.deletingLastPathComponent() }

    func save() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let raw = try enc.encode(data)
            try raw.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("NiceWatch 保存失败: \(error)")
        }
    }

    // MARK: 便捷访问

    var ups: [MonitoredUP] {
        get { data.ups }
        set { data.ups = newValue; save() }
    }

    var settings: Settings {
        get { data.settings }
        set { data.settings = newValue; save() }
    }

    var account: AccountInfo? {
        get { data.account }
        set { data.account = newValue; save() }
    }

    // MARK: 视频记录

    func markSeen(_ v: VideoItem, state: SeenVideo.State) -> SeenVideo {
        if var existing = data.seen[v.bvid] {
            existing.state = state
            data.seen[v.bvid] = existing
            return existing
        }
        let rec = SeenVideo(bvid: v.bvid,
                            mid: v.mid,
                            author: v.author,
                            title: v.title,
                            pubdate: v.pubdate,
                            detectedAt: Date(),
                            state: state)
        data.seen[v.bvid] = rec
        return rec
    }

    func updateSeen(_ rec: SeenVideo) {
        data.seen[rec.bvid] = rec
    }

    func hasSeen(_ bvid: String) -> Bool {
        data.seen[bvid] != nil
    }

    var timeline: [SeenVideo] {
        data.seen.values
            .filter { $0.state == .notified || $0.state == .pending || $0.state == .failed }
            .sorted { $0.pubdate > $1.pubdate }
    }

    /// 只保留最近 500 条非基线记录，避免文件无限增长
    func pruneSeen(maxCount: Int = 800) {
        let keys = data.seen.values.filter { $0.state == .baseline }
        guard keys.count > maxCount else { return }
        let sorted = keys.sorted { $0.detectedAt < $1.detectedAt }
        for rec in sorted.prefix(keys.count - maxCount) {
            data.seen.removeValue(forKey: rec.bvid)
        }
    }

    func resetAll() {
        data = PersistedData()
        save()
    }
}
