import Foundation
import Combine
import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    // MARK: 依赖

    /// 全局单例：AppKit 侧的窗口与 SwiftUI 侧的菜单项共用同一份状态
    static let shared = AppModel()

    private var storeObservation: AnyCancellable?
    private var recordGeneration = UUID()
    let store: Store
    private let notifierOverride: [Notifier]?
    private var checkOffset = 0
    private var processingVideos = false
    private let client = BiliClient.shared
    private let monitoringAPI: MonitoringAPI

    // MARK: 登录

    @Published var isLoggedIn = false
    @Published var account: AccountInfo?
    @Published var qrImage: NSImage?
    @Published var qrState: BiliClient.QRState = .waiting
    @Published var isLoggingIn = false
    private var qrKey: String?
    private var loginTask: Task<Void, Never>?

    // MARK: 监控

    @Published var status: MonitorStatus = .idle
    @Published var lastCheckAt: Date?
    @Published var nextCheckAt: Date?
    @Published var unreadCount = 0
    @Published var isChecking = false
    @Published var lastError: String?

    private var loopTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    // MARK: 界面数据

    @Published var followings: [UPBrief] = []
    @Published var followingsLoading = false
    @Published var followingsTotal = 0
    @Published var searchResults: [BiliClient.UserHit] = []
    @Published var searching = false
    @Published var toast: String?
    @Published var confirmation: ConfirmationAction?

    /// 设置项的 UI 镜像（改动后调用 commitSettings 落盘）
    @Published var settings: Settings

    init(store: Store = Store(), restore: Bool = true, notifiers: [Notifier]? = nil,
         monitoringAPI: MonitoringAPI? = nil) {
        self.store = store
        self.notifierOverride = notifiers
        self.monitoringAPI = monitoringAPI ?? BiliClient.shared
        AppLog.info("AppModel.init 开始（数据目录：\(AppLog.dirURL.path)）")
        settings = store.data.settings
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if restore {
            restoreSession()
            observeWake()
        }
        AppLog.info("AppModel.init 完成，isLoggedIn=\(isLoggedIn)，已监控 \(store.data.ups.count) 个 UP")
    }

    @Published var launchAtLogin = LaunchAtLogin.isEnabled

    func setLaunchAtLogin(_ on: Bool) {
        let result = on ? LaunchAtLogin.enable() : LaunchAtLogin.disable()
        switch result {
        case .success:
            launchAtLogin = LaunchAtLogin.isEnabled
            toast = on ? "已开启开机自启" : "已关闭开机自启"
        case .failure(let e):
            launchAtLogin = LaunchAtLogin.isEnabled
            lastError = e.localizedDescription
            AppLog.info("设置开机自启失败：\(e.localizedDescription)")
        }
    }

    /// 清理「测试」产生的假记录，让时间线恢复干净
    func clearTestRecords() -> String {
        let before = store.data.seen.count
        store.data.seen = store.data.seen.filter { !$0.key.hasPrefix("BV1test") }
        store.save()
        let removed = before - store.data.seen.count
        toast = "已清除 \(removed) 条测试记录"
        return toast ?? ""
    }

    /// 清除记录而非恢复出厂设置：保留账号、推送配置与监控名单。
    @discardableResult
    func clearAllRecords() -> Bool {
        let previous = store.data
        let cutoff = Int(Date().timeIntervalSince1970)
        store.data.seen.removeAll()
        for index in store.data.ups.indices {
            store.data.ups[index].baselinePubdate = max(store.data.ups[index].baselinePubdate, cutoff)
            store.data.ups[index].lastNotifiedAt = nil
            store.data.ups[index].lastSeenAt = nil
            store.data.ups[index].liveObservation?.pendingEvent = nil
        }
        guard store.save() else {
            store.data = previous
            lastError = "清除记录失败，请检查数据目录是否可写"
            return false
        }
        recordGeneration = UUID()
        unreadCount = 0
        toast = "已清除所有记录，监控将继续"
        return true
    }

    func commitSettings() {
        store.data.settings = settings
        store.save()
        startMonitoring()
    }

    func setContentEnabled(_ kind: ContentKind, enabled: Bool) {
        var preferences = settings.contentPreferences
        guard preferences.isEnabled(kind) != enabled else { return }
        preferences.set(kind, enabled: enabled, now: Int(Date().timeIntervalSince1970))
        settings.contentPreferences = preferences
        if kind == .live {
            // 重新启用时建立新基线，不把当前正在进行的直播当作刚开播。
            for index in store.data.ups.indices { store.data.ups[index].liveObservation = nil }
        }
        commitSettings()
    }

    // MARK: - 启动恢复

    private func restoreSession() {
        let cookies = SessionStore.load()
        if !cookies.isEmpty {
            client.loadCookies(cookies)
        }
        account = store.account
        isLoggedIn = client.hasSession && store.account != nil
        if isLoggedIn {
            // 恢复登录态后立刻跑一次检查，再进入定时循环
            Task { @MainActor in
                await refreshAccount()
                await checkNow()
            }
        }
    }

    private func persistSession() {
        SessionStore.save(client.cookies)
        store.account = account
    }

    func refreshAccount() async {
        do {
            if let info = try await client.nav() {
                account = info
                store.account = info
                if !isLoggedIn { AppLog.info("登录态已恢复：\(info.uname)") }
                isLoggedIn = true
                if status == .loginExpired { status = .idle }
            } else {
                if isLoggedIn { AppLog.info("登录已失效，需要重新扫码") }
                isLoggedIn = false
                status = .loginExpired
            }
        } catch {
            if let be = error as? BiliError, be.isLoginExpired {
                isLoggedIn = false
                status = .loginExpired
            }
        }
    }

    // MARK: - 扫码登录

    func beginLogin() {
        AppLog.info("beginLogin 被调用")
        loginTask?.cancel()
        qrState = .waiting
        qrImage = nil
        isLoggingIn = true
        loginTask = Task { [weak self] in
            await self?.runLoginFlow()
        }
    }

    private func runLoginFlow() async {
        AppLog.info("开始扫码登录流程")
        do {
            let gen = try await client.qrGenerate()
            qrKey = gen.qrcodeKey
            AppLog.info("二维码生成成功 key=\(gen.qrcodeKey.prefix(12))… urlLen=\(gen.url.count)")
            if let img = QRCode.image(from: gen.url) {
                qrImage = img
                AppLog.info("二维码图片渲染成功 \(Int(img.size.width))x\(Int(img.size.height))")
            } else {
                AppLog.info("二维码图片渲染失败")
                qrState = .failed("二维码渲染失败")
                isLoggingIn = false
                return
            }
            qrState = .waiting
        } catch {
            let msg = (error as? BiliError)?.errorDescription ?? error.localizedDescription
            AppLog.info("二维码生成失败：\(msg)")
            qrState = .failed(msg)
            isLoggingIn = false
            return
        }

        let deadline = Date().addingTimeInterval(180)
        while !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            guard let key = qrKey else { break }
            do {
                let state = try await client.qrPoll(key: key)
                if state != qrState { AppLog.info("扫码状态：\(state.hint)") }
                qrState = state
                switch state {
                case .success:
                    await finishLogin()
                    return
                case .expired:
                    let gen = try await client.qrGenerate()
                    qrKey = gen.qrcodeKey
                    qrImage = QRCode.image(from: gen.url)
                    qrState = .waiting
                case .failed(let m):
                    lastError = m
                    isLoggingIn = false
                    return
                default:
                    break
                }
            } catch let e as BiliError where e.isRiskControl {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            } catch {
                // 单次轮询失败不终止，继续
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            }
        }
        if !isLoggedIn {
            qrState = .failed("等待超时，请重新点击扫码登录")
            isLoggingIn = false
        }
    }

    private func finishLogin() async {
        await client.warmFingerprint()
        do {
            guard let info = try await client.nav() else {
                qrState = .failed("登录态无效，请重试")
                isLoggingIn = false
                return
            }
            account = info
            isLoggedIn = true
            AppLog.info("登录完成：\(info.uname) (UID \(info.mid))")
            persistSession()
            isLoggingIn = false
            qrState = .success
            toast = "已登录：\(info.uname)"
            await refreshFollowings(page: 1)
            startMonitoring()
            await checkNow()
        } catch {
            qrState = .failed("校验登录态失败：\(error.localizedDescription)")
            isLoggingIn = false
        }
    }

    func logout() {
        loopTask?.cancel()
        loopTask = nil
        loginTask?.cancel()
        client.clearCookies()
        SessionStore.clear()
        isLoggedIn = false
        account = nil
        store.account = nil
        qrImage = nil
        followings = []
        searchResults = []
        status = .idle
    }

    // MARK: - 监控循环

    func startMonitoring() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let base = self.store.settings.intervalClamped
                let jitter = Int.random(in: 0...20)
                let wait = base + jitter
                self.nextCheckAt = Date().addingTimeInterval(TimeInterval(wait))
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                if Task.isCancelled { return }
                if self.isLoggedIn {
                    await self.performCheck()
                }
            }
        }
    }

    func checkNow() async {
        nextCheckAt = Date()
        loopTask?.cancel()
        startMonitoring()
        await performCheck()
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                AppLog.info("检测到系统唤醒，立即补检一次")
                guard self.isLoggedIn else {
                    AppLog.info("唤醒补检跳过：当前未登录")
                    return
                }
                await self.checkNow()
            }
        }
    }

    /// 一次完整检查
    func performCheck() async {
        guard isLoggedIn, !isChecking else { return }
        isChecking = true
        status = .checking
        defer { isChecking = false }
        await process(videos: [])
        guard store.settings.contentPreferences.hasAny else { status = .idle; return }

        do {
            guard let info = try await monitoringAPI.nav() else {
                isLoggedIn = false
                status = .loginExpired
                await notifyLoginExpiry()
                return
            }
            account = info
            store.account = info
            let watched = store.data.ups.filter { $0.enabled }
            guard !watched.isEmpty else {
                status = .ok
                lastCheckAt = Date()
                return
            }
            var found: [VideoItem] = []
            var sourceErrors: [String] = []
            var riskControlled = false
            var successfulSources = 0
            var successfulMediaSources = 0
            var skipped = 0
            let batch = Self.nextBatch(watched, offset: &checkOffset)
            for (index, up) in batch.enumerated() {
                guard isMonitoredAndEnabled(up.mid) else { continue }
                if let until = up.backoffUntil, until > Date() { skipped += 1; continue }
                var uploads: [VideoItem] = []
                var dynamics: [VideoItem] = []
                var upRisk = false
                var upSucceeded = false
                var uploadsSucceeded = false
                var liveEvents: [VideoItem] = []
                var requestedPreviously = false
                // 视频源用于区分普通投稿和动态专属视频，其余类别按开关查询。
                for source in 0..<3 {
                    guard isMonitoredAndEnabled(up.mid) else { break }
                    let preferences = store.settings.contentPreferences
                    let requested = source == 0 ? preferences.hasVideo : source == 1 ? preferences.hasDynamicContent : preferences.live
                    guard requested else { continue }
                    if requestedPreviously { try? await Task.sleep(nanoseconds: 700_000_000) }
                    requestedPreviously = true
                    do {
                        if source == 0 {
                            uploads = try await monitoringAPI.spaceVideos(mid: up.mid, page: 1, pageSize: 10)
                            uploadsSucceeded = true
                        } else if source == 1 {
                            dynamics = try await monitoringAPI.spaceDynamicItems(mid: up.mid)
                        } else {
                            let room = try await monitoringAPI.liveRoom(mid: up.mid)
                            if store.settings.contentPreferences.live,
                               let i = store.data.ups.firstIndex(where: { $0.mid == up.mid && $0.enabled }) {
                                if room == nil, (store.data.ups[i].liveObservation?.roomID ?? 0) > 0 {
                                    throw BiliError.decoding("直播接口未返回已知直播间，保留上次状态")
                                }
                                let observation = LiveObservation.advance(previous: store.data.ups[i].liveObservation,
                                    room: room, mid: up.mid, author: up.name, now: Int(Date().timeIntervalSince1970),
                                    startedAfter: max(up.notificationFloor, store.settings.contentPreferences.enabledSince[ContentKind.live.rawValue] ?? 0))
                                var state = observation.state
                                if let event = observation.event {
                                    if store.hasSeen(event.bvid) { state.pendingEvent = nil }
                                    else { liveEvents.append(event) }
                                }
                                store.data.ups[i].liveObservation = state
                            }
                        }
                        successfulSources += 1
                        if source < 2 { successfulMediaSources += 1 }
                        upSucceeded = true
                    } catch let error as BiliError where error.isLoginExpired {
                        isLoggedIn = false
                        status = .loginExpired
                        await notifyLoginExpiry()
                        return
                    } catch {
                        let label = source == 0 ? "投稿列表" : source == 1 ? "空间动态" : "直播状态"
                        sourceErrors.append("\(up.name)\(label)：\(error.localizedDescription)")
                        if (error as? BiliError)?.isRiskControl == true { upRisk = true }
                        AppLog.info("  \(up.name)：\(label)失败（\(error.localizedDescription)）")
                    }
                }
                guard isMonitoredAndEnabled(up.mid) else { continue }
                // 只选动态视频时，投稿来源失败就无法可靠分类；不误推已关闭的普通投稿。
                if !uploadsSucceeded && !store.settings.contentPreferences.uploads {
                    dynamics.removeAll { $0.contentKind.isVideo }
                }
                let merged = (VideoSources.merge(uploads: uploads, dynamics: dynamics) + liveEvents).sorted { $0.pubdate < $1.pubdate }
                found.append(contentsOf: merged)
                let latest = merged.last.map { "\($0.bvid) · \($0.pubDate.formatted(date: .numeric, time: .shortened))" } ?? "无"
                AppLog.info("  \(up.name)：投稿 \(uploads.count) 条，动态内容 \(dynamics.count) 条，合并 \(merged.count) 条；最新 \(latest)")
                if upRisk {
                    riskControlled = true
                    escalateBackoff(mid: up.mid, name: up.name)
                } else if upSucceeded { resetBackoff(mid: up.mid) }
                if index < batch.count - 1 { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
            if successfulMediaSources == 0 && store.settings.contentPreferences.hasVideo && !sourceErrors.isEmpty {
                do {
                    let watchedMids = Set(watched.map(\.mid))
                    let feed = try await monitoringAPI.dynamicVideoFeed()
                    found.append(contentsOf: feed.filter { watchedMids.contains($0.mid) })
                    AppLog.info("所有逐 UP 来源失败，补查混合关注动态 \(found.count) 条")
                } catch let error as BiliError where error.isLoginExpired {
                    isLoggedIn = false
                    status = .loginExpired
                    await notifyLoginExpiry()
                    return
                } catch { sourceErrors.append("关注动态：\(error.localizedDescription)") }
            }
            await process(videos: found, retryPending: false)
            lastCheckAt = Date()
            if riskControlled || skipped > 0 {
                status = .riskControlled("部分来源触发风控，已退避")
            } else if !sourceErrors.isEmpty {
                status = .networkError("部分来源不可用")
            } else { status = .ok }
            if !sourceErrors.isEmpty { lastError = sourceErrors.joined(separator: "；") }
            AppLog.info("检查完成：监控 \(watched.count) 个 UP，合并 \(found.count) 条内容，成功来源 \(successfulSources)，失败来源 \(sourceErrors.count)，退避跳过 \(skipped)")
            store.save()
        } catch let error as BiliError {
            lastError = error.localizedDescription
            if error.isLoginExpired {
                isLoggedIn = false
                status = .loginExpired
                await notifyLoginExpiry()
            } else if error.isRiskControl { status = .riskControlled(error.localizedDescription) }
            else { status = .networkError(error.localizedDescription) }
        } catch {
            status = .networkError(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    private func isMonitoredAndEnabled(_ mid: Int64) -> Bool {
        store.data.ups.contains { $0.mid == mid && $0.enabled }
    }

    /// 每轮最多检查 20 个 UP；游标保证整个名单轮流得到检查。
    nonisolated static func nextBatch(_ watched: [MonitoredUP], offset: inout Int) -> [MonitoredUP] {
        guard !watched.isEmpty else { offset = 0; return [] }
        let start = offset % watched.count
        let count = min(20, watched.count)
        let batch = (0..<count).map { watched[(start + $0) % watched.count] }
        offset = (start + count) % watched.count
        return batch
    }

    /// 处理抓到的视频：判定新视频 → 推送 → 记录状态
    /// - Parameter drill: 测试模式。为 true 时不做「是否属于已监控 UP」和「基线」过滤，
    ///   只保留去重、静默时段、真实推送这几步——这样即使一个 UP 都没在监控，
    ///   也能完整验证推送链路。
    func process(videos: [VideoItem], drill: Bool = false, retryPending: Bool = true) async {
        guard !processingVideos else { return }
        let generation = recordGeneration
        processingVideos = true
        defer { processingVideos = false }
        // 重试不依赖投稿是否仍在接口返回的最近十条中。
        let pending = store.data.seen.values.filter { retryPending && !drill && $0.state == .pending }
            .sorted { $0.detectedAt < $1.detectedAt }
        for rec in pending {
            guard generation == recordGeneration else { return }
            if !drill && !store.data.ups.contains(where: { $0.mid == rec.mid && $0.enabled }) { continue }
            if !drill && !store.settings.contentPreferences.allows(rec.contentKind, publishedAt: rec.pubdate) {
                var skipped = rec
                skipped.state = .muted
                store.updateSeen(skipped)
                continue
            }
            if inQuietHours() { continue }
            let video = VideoItem(bvid: rec.bvid, title: rec.title, author: rec.author,
                                  mid: rec.mid, pubdate: rec.pubdate, cover: "", kind: rec.kind, link: rec.link,
                                  content: rec.content, roomID: rec.roomID)
            await deliver(video, record: rec)
            guard generation == recordGeneration else { return }
        }
        let watched = store.data.ups.filter { $0.enabled }
        let upMap = Dictionary(uniqueKeysWithValues: watched.map { ($0.mid, $0) })
        // 同一 bvid 可能重复出现
        var unique: [String: VideoItem] = [:]
        if drill {
            for v in videos { unique[v.bvid] = v }
        } else {
            for v in videos where upMap[v.mid] != nil {
                unique[v.bvid] = v
            }
        }

        let sorted = unique.values.sorted { $0.pubdate < $1.pubdate }
        for v in sorted {
            guard generation == recordGeneration else { return }
            guard !store.hasSeen(v.bvid) else { continue }
            if !drill && !store.settings.contentPreferences.allows(v.contentKind, publishedAt: v.pubdate) {
                // 保存已确认的视频分类，避免它移出投稿最近一页后被误归为动态专属视频。
                if v.contentKind.isVideo { _ = store.markSeen(v, state: .baseline) }
                continue
            }

            if !drill {
                guard let up = store.data.ups.first(where: { $0.mid == v.mid && $0.enabled }) else { continue }

                // 基线保护：明显早于该 UP 基线的视为历史视频，不推送
                let floor = up.notificationFloor
                if v.pubdate <= floor {
                    _ = store.markSeen(v, state: .baseline)
                    continue
                }
            }

            var rec = store.markSeen(v, state: .pending)
            rec.state = .pending
            store.updateSeen(rec)

            if inQuietHours() {
                rec.state = .muted
                store.updateSeen(rec)
                continue
            }

            await deliver(v, record: rec)
            guard generation == recordGeneration else { return }
        }
        store.pruneSeen()
        store.save()
    }

    /// 按设置组装当前启用的通知通道
    /// 当前只启用 Bark：iMessage 会让 Mac 自动打开「信息」并标记已读，
    /// 已读状态跨设备同步后 iPhone 就不再弹通知，因此整条通道被移除。
    private func activeNotifiers() -> [Notifier] {
        if let notifiers = notifierOverride { return notifiers }
        let s = store.settings
        guard s.useBark, let k = s.barkKey else { return [] }
        return [BarkNotifier(key: k)]
    }

    private func deliver(_ v: VideoItem, record rec: SeenVideo) async {
        let generation = recordGeneration
        var rec = rec
        // 持久化失败时停止发送，避免生成无法恢复的推送。
        guard store.save() else {
            lastError = "无法保存待推送记录，已停止发送"
            return
        }
        let text = store.settings.render(v)
        let notifiers = activeNotifiers()
        guard !notifiers.isEmpty else {
            rec.attempts += 1
            rec.lastError = "没有启用任何通知通道"
            rec.state = rec.attempts >= 3 ? .failed : .pending
            store.updateSeen(rec)
            lastError = rec.lastError
            store.save()
            return
        }

        var errors: [String] = []
        var anySuccess = false
        for n in notifiers {
            do {
                try await n.send(text: text, targetURL: v.videoURL)
                guard generation == recordGeneration, store.hasSeen(v.bvid) else { return }
                anySuccess = true
                AppLog.info("已通过 \(n.name) 推送：\(v.bvid) \(v.title)")
            } catch {
                guard generation == recordGeneration, store.hasSeen(v.bvid) else { return }
                errors.append("\(n.name): \(error.localizedDescription)")
                AppLog.info("\(n.name) 推送失败：\(error.localizedDescription)")
            }
        }

        if anySuccess {
            rec.state = .notified
            rec.notifiedAt = Date()
            rec.lastError = errors.isEmpty ? nil : errors.joined(separator: " | ")
            store.updateSeen(rec)
            unreadCount += 1
            if let i = store.data.ups.firstIndex(where: { $0.mid == v.mid }) {
                store.data.ups[i].lastNotifiedAt = Date()
                store.data.ups[i].lastSeenAt = Date()
            }
        } else {
            rec.attempts += 1
            rec.lastError = errors.joined(separator: " | ")
            rec.state = rec.attempts >= 3 ? .failed : .pending
            store.updateSeen(rec)
            lastError = rec.lastError
        }
        store.save()
    }

    // MARK: - 风控指数退避
    //
    // 命中 -352 / -412 / -799 时，对单个 UP 做指数退避：
    // 10 分钟 → 30 分钟 → 2 小时 → 6 小时（封顶）。
    // 一旦成功立刻清零，恢复正常频率。

    nonisolated static let backoffSteps: [TimeInterval] = [600, 1800, 7200, 21600]

    /// 第 n 次连续失败应对应的退避时长（纯函数，供实现与测试共用，避免测试复制一份逻辑）
    nonisolated static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let idx = min(attempt - 1, backoffSteps.count - 1)
        return backoffSteps[idx]
    }

    private func escalateBackoff(mid: Int64, name: String) {
        guard let i = store.data.ups.firstIndex(where: { $0.mid == mid }) else { return }
        var up = store.data.ups[i]
        let fails = (up.consecutiveFailures ?? 0) + 1
        up.consecutiveFailures = fails
        let delay = Self.backoffDelay(forAttempt: fails)
        up.backoffUntil = Date().addingTimeInterval(delay)
        store.data.ups[i] = up
        AppLog.info("  \(name)：命中风控，退避 \(Int(delay / 60)) 分钟（连续失败 \(fails) 次）")
        status = .riskControlled("部分 UP 触发风控，已退避")
    }

    private func resetBackoff(mid: Int64) {
        guard let i = store.data.ups.firstIndex(where: { $0.mid == mid }) else { return }
        guard (store.data.ups[i].consecutiveFailures ?? 0) > 0 || store.data.ups[i].backoffUntil != nil else { return }
        store.data.ups[i].consecutiveFailures = 0
        store.data.ups[i].backoffUntil = nil
    }

    private func inQuietHours() -> Bool {
        let s = store.settings
        guard let start = s.quietStartHour, let end = s.quietEndHour else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        if start == end { return false }
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }

    // 登录失效提醒（每天最多一次）
    private var lastExpiryNotice: Date?

    private func notifyLoginExpiry() async {
        guard store.settings.notifyOnLoginExpiry else { return }
        if let last = lastExpiryNotice, Date().timeIntervalSince(last) < 86400 { return }
        lastExpiryNotice = Date()
        let text = "⚠️ NiceWatch：B站登录已失效，无法继续监控。请在 Mac 上重新扫码登录。"
        for n in activeNotifiers() {
            try? await n.send(text: text)
        }
    }

    // MARK: - UP 主管理

    func isMonitored(_ mid: Int64) -> Bool {
        store.data.ups.contains { $0.mid == mid }
    }

    /// 添加监控：先用空间接口建立基线，避免一次性推送历史视频
    func addUP(mid: Int64, name: String, face: String) async {
        guard !isMonitored(mid) else { return }
        var baseline = 0
        if let vids = try? await client.spaceVideos(mid: mid, pageSize: 10), !vids.isEmpty {
            for v in vids {
                _ = store.markSeen(v, state: .baseline)
            }
            baseline = vids.map(\.pubdate).max() ?? 0
        } else {
            baseline = Int(Date().timeIntervalSince1970)
        }
        let up = MonitoredUP(mid: mid, name: name, face: face, baselinePubdate: baseline)
        store.data.ups.append(up)
        store.save()
        toast = "已开始监控 \(name)"
    }

    func requestRemoveUP(mid: Int64) {
        guard let up = store.data.ups.first(where: { $0.mid == mid }) else { return }
        confirmation = .removeUP(up)
    }

    func confirmAction() {
        guard let action = confirmation else { return }
        confirmation = nil
        switch action {
        case .removeUP(let up): removeUP(mid: up.mid)
        case .clearAllRecords: clearAllRecords()
        }
    }

    func removeUP(mid: Int64) {
        store.data.ups.removeAll { $0.mid == mid }
        store.save()
    }

    /// 按目标值设置是否监控（幂等）。
    /// 不用「取反」是因为 SwiftUI 的 Binding 可能重复写回同一个值，
    /// 取反式写法会把状态意外翻掉。
    func setUPEnabled(mid: Int64, enabled: Bool) {
        guard let i = store.data.ups.firstIndex(where: { $0.mid == mid }) else { return }
        guard store.data.ups[i].enabled != enabled else { return }
        store.data.ups[i].enabled = enabled
        store.save()
        AppLog.info("\(store.data.ups[i].name)：\(enabled ? "恢复" : "暂停")监控")
    }

    // MARK: - 关注列表 / 搜索

    func refreshFollowings(page: Int = 1) async {
        guard let mid = account?.mid else { return }
        followingsLoading = true
        defer { followingsLoading = false }
        do {
            let (list, total) = try await client.followings(vmid: mid, page: page, pageSize: 30)
            followings = list
            followingsTotal = total
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadMoreFollowings() async {
        guard let mid = account?.mid else { return }
        let page = followings.count / 30 + 1
        do {
            let (list, _) = try await client.followings(vmid: mid, page: page, pageSize: 30)
            let existing = Set(followings.map(\.mid))
            followings.append(contentsOf: list.filter { !existing.contains($0.mid) })
        } catch {
            lastError = error.localizedDescription
        }
    }

    func search(keyword: String) async {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { searchResults = []; return }
        searching = true
        defer { searching = false }
        do {
            searchResults = try await client.searchUsers(keyword: kw)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 测试

    func sendTestMessage() async -> String {
        let notifiers = activeNotifiers()
        guard !notifiers.isEmpty else { return "失败：还没有启用任何通知通道" }
        var ok: [String] = []
        var bad: [String] = []
        let text = "🔔 NiceWatch 测试消息\n如果你在手机上看到这条，通知链路已经打通。"
        for n in notifiers {
            do {
                try await n.send(text: text)
                ok.append(n.name)
            } catch {
                bad.append("\(n.name)：\(error.localizedDescription)")
            }
        }
        if bad.isEmpty { return "已通过 \(ok.joined(separator: " + ")) 发送，请查看手机" }
        if ok.isEmpty { return "失败：" + bad.joined(separator: "；") }
        return "部分成功（\(ok.joined(separator: "、"))）：" + bad.joined(separator: "；")
    }

    /// 端到端测试：伪造一条"新视频"，走完整的检测管线（去重 → 基线过滤 → 静默判定 → 推送）
    /// 测试：走一遍真实的「检测 → 去重 → 推送」管线。
    ///
    /// 有监控中的 UP 时，随机挑一个，取它最新的真实投稿来模拟；
    /// 没有监控中的 UP（或取不到投稿）时，才退回到完全伪造的一条。
    func simulateNewVideo() async -> String {
        let generation = recordGeneration
        // 只在「正在监控」的 UP 里随机；一个都没有才回退到伪造数据
        let pool = store.data.ups.filter { $0.enabled }

        if let up = pool.randomElement() {
            do {
                let vids = try await client.spaceVideos(mid: up.mid, pageSize: 10)
                guard generation == recordGeneration else { return "记录已清除，本次测试已取消" }
                guard store.data.ups.contains(where: { $0.mid == up.mid && $0.enabled }) else {
                    return "该 UP 已暂停或取消监控，本次测试已取消"
                }
                if let latest = vids.max(by: { $0.pubdate < $1.pubdate }) {
                    AppLog.info("测试：随机选中「\(up.name)」，用其最新投稿 \(latest.bvid)《\(latest.title)》模拟推送")
                    // 这条视频本来已在 seen 里（基线），且发布时间早于基线，
                    // 直接放进管线会被「已见过 / 基线过滤」拦掉，测试就测不到推送路径。
                    // 因此清掉它的记录并把时间改成「刚刚」，让它真正走完整条链路。
                    store.data.seen.removeValue(forKey: latest.bvid)
                    await process(videos: [latest], drill: true)
                    return describeResult(bvid: latest.bvid, isReal: true)
                }
                AppLog.info("测试：「\(up.name)」暂无投稿，回退到伪造视频")
            } catch let e as BiliError where e.isLoginExpired {
                return "登录已失效，请重新扫码后再试"
            } catch {
                AppLog.info("测试：拉取「\(up.name)」投稿失败（\(error.localizedDescription)），回退到伪造视频")
            }
        }

        guard generation == recordGeneration else { return "记录已清除，本次测试已取消" }
        // 兜底：完全伪造一条
        let suffix = String(Int(Date().timeIntervalSince1970) % 100000)
        let bvid = "BV1test\(suffix)"
        let fake = VideoItem(bvid: bvid,
                             title: "【测试】这是一条模拟的新投稿 \(suffix)",
                             author: "NiceWatch 测试",
                             mid: 0,
                             pubdate: Int(Date().timeIntervalSince1970),
                             cover: "")
        AppLog.info("测试：没有监控中的 UP，改用伪造视频 \(bvid) → 进入检测管线")
        await process(videos: [fake], drill: true)
        return describeResult(bvid: bvid, isReal: false)
    }

    private func describeResult(bvid: String, isReal: Bool) -> String {
        guard let updated = store.data.seen[bvid] else {
            return "管线未记录该视频（可能被基线过滤）"
        }
        switch updated.state {
        case .notified:
            return isReal ? "已用真实最新投稿推送成功，请查看手机" : "推送成功，请查看手机"
        case .muted:
            return "命中静默时段，已跳过推送"
        case .failed:
            return "推送失败：\(updated.lastError ?? "未知")"
        default:
            return "状态：\(updated.state.rawValue)（\(updated.lastError ?? "")）"
        }
    }
}

// MARK: - 二维码图片生成

enum QRCode {
    static func image(from string: String, scale: CGFloat = 8) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
