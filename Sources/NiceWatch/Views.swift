import SwiftUI
import AppKit

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            SpectrumBackground()
            Group {
                if model.isLoggedIn {
                    MainView()
                } else {
                    LoginView()
                }
            }
            .padding(24)
        }
        .frame(minWidth: 780, minHeight: 580)
    }
}

// MARK: - 登录

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            VStack(spacing: 5) {
                Text("NiceWatch")
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(p.text)
                Text("B站 UP 主更新监控 · Bark 推送到手机")
                    .font(.system(size: 12))
                    .foregroundStyle(p.subtext)
            }

            // 白色二维码卡片与浅色画布分层，确保扫码区域清晰。
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(p.surface)
                    .frame(width: 268, height: 268)
                    .spectrumSurface(radius: 24)

                if let img = model.qrImage {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 212, height: 212)
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white)
                        }
                } else if model.isLoggingIn {
                    ProgressView()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(p.subtext)
                        Text("点击下方按钮开始扫码登录")
                            .font(.system(size: 12))
                            .foregroundStyle(p.subtext)
                    }
                }
            }

            Text(model.qrState.hint)
                .font(.system(size: 12.5))
                .foregroundStyle(model.qrState.isErrorState ? p.danger : p.subtext)

            HStack(spacing: 12) {
                Button(model.isLoggingIn ? "重新生成二维码" : "扫码登录 B站") {
                    model.beginLogin()
                }
                .buttonStyle(.spectrumProminent)
                .frame(width: 200)
                .keyboardShortcut(.defaultAction)

                if case .success = model.qrState {
                    SpectrumTag(text: "已登录", icon: "checkmark.seal.fill", tint: p.success)
                }
            }

            Text("使用哔哩哔哩 App 扫码并确认。登录信息加密保存在这台 Mac。")
                .font(.system(size: 12))
                .foregroundStyle(p.subtext)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !model.isLoggingIn && model.qrImage == nil {
                model.beginLogin()
            }
        }
    }
}

// MARK: - 主界面

enum MainTab: Hashable {
    case monitor, timeline, settings

    /// 调试用：可用 NICEWATCH_TAB=timeline/settings 指定启动时的页签
    static var initial: MainTab {
        switch ProcessInfo.processInfo.environment["NICEWATCH_TAB"] {
        case "timeline": return .timeline
        case "settings": return .settings
        default: return .monitor
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var tab: MainTab

    init(tab: MainTab = MainTab.initial) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        VStack(spacing: 20) {
            header(p)

            SpectrumSegmented(
                options: [
                    (MainTab.monitor, "监控", "dot.radiowaves.left.and.right"),
                    (MainTab.timeline, "时间线", "clock.arrow.circlepath"),
                    (MainTab.settings, "设置", "slider.horizontal.3"),
                ],
                selection: $tab
            )

            Group {
                switch tab {
                case .monitor: MonitoredListView()
                case .timeline: TimelineView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func header(_ p: SpectrumPalette) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(p.accentSoft)
                        .frame(width: 40, height: 40)
                    Image(nsImage: IconArtwork.menuBarImage(unread: false))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("NiceWatch")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(p.text)
                    Text(model.account?.uname ?? "未登录")
                        .font(.system(size: 12))
                        .foregroundStyle(p.subtext)
                }
            }

            Spacer()

            StatusStrip(status: model.status, lastCheck: model.lastCheckAt)

            Button {
                Task { await model.checkNow() }
            } label: {
                Label("立即检查", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.spectrumCompact())
            .disabled(model.isChecking)
        }
        .padding(.horizontal, 4)
    }
}

struct StatusStrip: View {
    let status: MonitorStatus
    let lastCheck: Date?
    @Environment(\.colorScheme) private var scheme

    private func color(_ p: SpectrumPalette) -> Color {
        switch status {
        case .ok: return p.success
        case .idle: return p.subtext
        case .checking: return p.accent
        case .loginExpired, .riskControlled, .networkError: return p.warning
        }
    }

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        HStack(spacing: 6) {
            Circle()
                .fill(color(p))
                .frame(width: 7, height: 7)
            Text(status.text)
                .font(.system(size: 11))
                .foregroundStyle(p.subtext)
            if let lastCheck {
                Text("· " + lastCheck.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(p.subtext)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(p.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 监控列表

struct MonitoredListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showPicker = false

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                overviewTile(title: "正在监控", value: "\(model.store.data.ups.filter { $0.enabled }.count)",
                             icon: "dot.radiowaves.left.and.right", tint: p.accentText, p: p)
                overviewTile(title: "已推送记录", value: "\(model.store.data.seen.values.filter { $0.state == .notified }.count)",
                             icon: "checkmark.circle", tint: p.success, p: p)
                overviewTile(title: "待推送", value: "\(model.store.data.seen.values.filter { $0.state == .pending }.count)",
                             icon: "clock", tint: p.warning, p: p)
            }
            HStack {
                SpectrumSectionTitle(title: "监控列表",
                                subtitle: "共 \(model.store.data.ups.count) 个 UP 主")
                Spacer()
                Button {
                    showPicker = true
                } label: {
                    Label("添加 UP 主", systemImage: "plus")
                }
                .buttonStyle(.spectrumCompact(.prominent))
            }

            if model.store.data.ups.isEmpty {
                emptyState(p)
            } else {
                ScrollView {
                    LazyVStack(spacing: 11) {
                        ForEach(model.store.data.ups) { up in
                            row(up, p)
                        }
                    }
                    .padding(4)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            AddUPView()
                .environmentObject(model)
                .frame(width: 580, height: 500)
        }
    }

    private func overviewTile(title: String, value: String, icon: String,
                              tint: Color, p: SpectrumPalette) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.system(size: 25, weight: .heavy)).foregroundStyle(p.text)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(p.subtext)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectrumSurface()
        .accessibilityElement(children: .combine)
    }

    private func emptyState(_ p: SpectrumPalette) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(p.accentSoft).frame(width: 76, height: 76)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(p.accentText)
            }
            Text("还没有监控任何 UP 主")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(p.text)
            Text("从你的关注列表里挑一个，或者直接搜索名字添加。")
                .font(.system(size: 12))
                .foregroundStyle(p.subtext)
            Button("添加 UP 主") { showPicker = true }
                .buttonStyle(.spectrumProminent)
                .frame(width: 170)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ up: MonitoredUP, _ p: SpectrumPalette) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: up.faceURL, name: up.name, size: 38)
                .spectrumSurface(radius: 19)

            VStack(alignment: .leading, spacing: 3) {
                Text(up.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(p.text)
                HStack(spacing: 6) {
                    SpectrumTag(text: up.enabled ? "监控中" : "已暂停",
                           icon: up.enabled ? "dot.radiowaves.left.and.right" : "pause.fill",
                           tint: up.enabled ? p.success : p.warning)
                    if let t = up.lastNotifiedAt {
                        Text("上次推送 " + t.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundStyle(p.subtext)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { up.enabled },
                set: { model.setUPEnabled(mid: up.mid, enabled: $0) }
            ))
            .toggleStyle(SpectrumToggleStyle())
            .labelsHidden()
            .accessibilityLabel("监控 \(up.name)")

            Button {
                model.removeUP(mid: up.mid)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.spectrumCompact(.danger))
            .help("取消监控")
            .accessibilityLabel("取消监控 \(up.name)")
        }
        .padding(14)
        .spectrumSurface(radius: 16)
    }
}

// MARK: - 添加 UP 主

struct AddUPView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var keyword = ""

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        ZStack {
            SpectrumBackground()
            VStack(spacing: 12) {
                HStack {
                    Text("添加 UP 主")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.text)
                    Spacer()
                    Button("完成") { dismiss() }
                        .buttonStyle(.spectrumCompact())
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(p.subtext)
                    SpectrumField {
                        TextField("搜索 UP 主名字，或从下方关注列表选择", text: $keyword)
                            .font(.system(size: 12.5))
                            .onSubmit { Task { await model.search(keyword: keyword) } }
                    }
                    if model.searching { ProgressView().controlSize(.small) }
                    Button("搜索") {
                        Task { await model.search(keyword: keyword) }
                    }
                    .buttonStyle(.spectrumCompact(.prominent))
                }

                ScrollView {
                    LazyVStack(spacing: 9, pinnedViews: [.sectionHeaders]) {
                        if !model.searchResults.isEmpty {
                            Section {
                                ForEach(model.searchResults) { hit in
                                    row(mid: hit.mid, name: hit.name, face: hit.face,
                                        subtitle: "\(hit.fans) 粉丝", p: p)
                                }
                            } header: {
                                sectionHeader("搜索结果", p: p) {
                                    Button("清除") { model.searchResults = [] }
                                        .buttonStyle(.spectrumCompact())
                                }
                            }
                        }

                        Section {
                            if model.followingsLoading {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("加载中…")
                                        .font(.system(size: 11))
                                        .foregroundStyle(p.subtext)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                            ForEach(model.followings, id: \.mid) { up in
                                row(mid: up.mid,
                                    name: up.uname ?? "未知",
                                    face: up.face ?? "",
                                    subtitle: (up.sign?.isEmpty == false ? up.sign! : ""),
                                    p: p)
                            }
                        } header: {
                            sectionHeader("我的关注（\(model.followingsTotal)）", p: p) {
                                Button("加载更多") {
                                    Task { await model.loadMoreFollowings() }
                                }
                                .buttonStyle(.spectrumCompact())
                            }
                        }
                    }
                    .padding(4)
                }
            }
            .padding(24)
        }
        .task {
            if model.followings.isEmpty {
                await model.refreshFollowings(page: 1)
            }
        }
    }

    private func sectionHeader(_ title: String,
                               p: SpectrumPalette,
                               @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(p.subtext)
            Spacer()
            trailing()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(SpectrumPalette.of(scheme).base.opacity(0.98))
    }

    @ViewBuilder
    private func row(mid: Int64, name: String, face: String,
                     subtitle: String, p: SpectrumPalette) -> some View {
        let monitored = model.isMonitored(mid)
        HStack(spacing: 10) {
            AvatarView(url: URL(string: face.hasPrefix("//") ? "https:" + face : face),
                       name: name, size: 30)
                .spectrumSurface(radius: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.text)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(p.subtext)
                        .lineLimit(1)
                }
            }
            Spacer()
            if monitored {
                SpectrumTag(text: "已监测", icon: "checkmark.circle.fill", tint: p.success)
                Button("取消") { model.removeUP(mid: mid) }
                    .buttonStyle(.spectrumCompact())
            } else {
                Button("监测") {
                    Task { await model.addUP(mid: mid, name: name, face: face) }
                }
                .buttonStyle(.spectrumCompact(.prominent))
            }
        }
        .padding(11)
        .spectrumSurface(radius: 13)
    }
}

// MARK: - 时间线

struct TimelineView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        let items = model.store.timeline

        VStack(spacing: 12) {
            HStack {
                SpectrumSectionTitle(title: "时间线", subtitle: "最近 \(items.count) 条检测记录")
                Spacer()
            }

            if items.isEmpty {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(p.accentSoft).frame(width: 70, height: 70)
                        Image(systemName: "clock")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(p.accentText)
                    }
                    Text("还没有检测到更新")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(p.text)
                    Text("每 \(Settings.intervalLabel(model.settings.intervalClamped))检查一次，发现新视频会立刻推送。")
                        .font(.system(size: 12))
                        .foregroundStyle(p.subtext)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            row(item, p)
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    private func row(_ item: SeenVideo, _ p: SpectrumPalette) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.author)
                        .font(.system(size: 12))
                        .foregroundStyle(p.subtext)
                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(p.subtext)
                    Text(item.pubDate.formatted(date: .numeric, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(p.subtext)
                }
            }
            Spacer()
            stateTag(item.state, p)
            Button {
                if let u = item.videoURL { NSWorkspace.shared.open(u) }
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.spectrumCompact())
            .accessibilityLabel("打开视频：\(item.title)")
        }
        .padding(16)
        .spectrumSurface(radius: 14)
    }

    @ViewBuilder
    private func stateTag(_ s: SeenVideo.State, _ p: SpectrumPalette) -> some View {
        switch s {
        case .notified:
            SpectrumTag(text: "已推送", icon: "checkmark.circle", tint: p.success)
        case .pending:
            SpectrumTag(text: "待推送", icon: "clock", tint: p.warning)
        case .failed:
            SpectrumTag(text: "失败", icon: "exclamationmark.triangle", tint: p.danger)
        case .muted:
            SpectrumTag(text: "静默", icon: "moon.zzz")
        case .baseline:
            EmptyView()
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var testResult: String?
    @State private var busy = false

    var body: some View {
        let p = SpectrumPalette.of(scheme)
        ScrollView {
            VStack(spacing: 14) {
                accountCard(p)
                channelCard(p)
                contentCard(p)
                monitorCard(p)
                dataCard(p)
                if let err = model.lastError {
                    SpectrumCard {
                        VStack(alignment: .leading, spacing: 6) {
                            SpectrumSectionTitle(title: "最近错误")
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(p.danger)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    // 账号
    private func accountCard(_ p: SpectrumPalette) -> some View {
        SpectrumCard {
            VStack(alignment: .leading, spacing: 12) {
                SpectrumSectionTitle(title: "账号")
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isLoggedIn ? p.success : p.warning)
                        .frame(width: 8, height: 8)
                    Text(model.isLoggedIn ? "已登录 \(model.account?.uname ?? "")" : "未登录")
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.text)
                    Spacer()
                    Button("重新登录") { model.beginLogin() }
                        .buttonStyle(.spectrumCompact())
                    Button("退出登录") { model.logout() }
                        .buttonStyle(.spectrumCompact(.danger))
                }
            }
        }
    }

    // 通知通道
    private func channelCard(_ p: SpectrumPalette) -> some View {
        SpectrumCard {
            VStack(alignment: .leading, spacing: 10) {
                SpectrumSectionTitle(title: "通知通道", subtitle: "Bark · 推送到 iPhone 通知中心")

                SpectrumField {
                    SecureField("Bark 推送 key", text: Binding(
                        get: { model.settings.barkKey ?? "" },
                        set: { model.settings.barkKey = $0; model.commitSettings() }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                }

                Text("Bark App 首页那条 https://api.day.app/xxx 地址里，最后一段就是 key。")
                    .font(.system(size: 12))
                    .foregroundStyle(p.subtext)
            }
        }
    }

    // 通知内容
    private func contentCard(_ p: SpectrumPalette) -> some View {
        SpectrumCard {
            VStack(alignment: .leading, spacing: 10) {
                SpectrumSectionTitle(title: "通知内容", subtitle: "变量：{author} {title} {bvid} {url}")

                TextField("", text: Binding(
                    get: { model.settings.template },
                    set: { model.settings.template = $0; model.commitSettings() }
                ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(p.text)
                .lineLimit(3...4)
                .padding(10)
                .spectrumInput(radius: 12)

                HStack(spacing: 10) {
                    Button("发送测试消息") {
                        busy = true
                        Task {
                            testResult = await model.sendTestMessage()
                            busy = false
                        }
                    }
                    .buttonStyle(.spectrumCompact())
                    .disabled(busy)

                    Button("用最新投稿演练") {
                        busy = true
                        Task {
                            testResult = await model.simulateNewVideo()
                            busy = false
                        }
                    }
                    .buttonStyle(.spectrumCompact(.prominent))
                    .disabled(busy)

                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if let testResult {
                    Text(testResult)
                        .font(.system(size: 11))
                        .foregroundStyle(testResult.contains("失败") ? p.danger : p.success)
                }
            }
        }
    }

    // 监控设置
    private func monitorCard(_ p: SpectrumPalette) -> some View {
        SpectrumCard {
            VStack(alignment: .leading, spacing: 14) {
                SpectrumSectionTitle(title: "监控")

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("检查间隔")
                            .font(.system(size: 12.5))
                            .foregroundStyle(p.text)
                        Spacer()
                        SpectrumTag(text: Settings.intervalLabel(model.settings.intervalClamped),
                               icon: "timer", tint: p.accentText)
                    }
                    SpectrumSlider(
                        value: Binding(
                            get: { model.settings.intervalClamped },
                            set: {
                                model.settings.intervalSeconds = $0
                                model.commitSettings()
                            }
                        ),
                        range: Settings.intervalMin...Settings.intervalMax,
                        step: Settings.intervalStep
                    )
                    HStack {
                        Text("30 秒").font(.system(size: 10)).foregroundStyle(p.subtext)
                        Spacer()
                        Text("30 分钟").font(.system(size: 10)).foregroundStyle(p.subtext)
                    }
                }

                Divider()

                HStack {
                    Text("静默时段")
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.text)
                    Spacer()
                    Picker("静默开始时间", selection: Binding(
                        get: { model.settings.quietStartHour ?? -1 },
                        set: { model.settings.quietStartHour = $0 < 0 ? nil : $0; model.commitSettings() }
                    )) {
                        Text("关闭").tag(-1)
                        ForEach(0..<24, id: \.self) { h in Text("\(h) 点").tag(h) }
                    }
                    .labelsHidden()
                    .frame(width: 92)

                    Text("→").foregroundStyle(p.subtext)

                    Picker("静默结束时间", selection: Binding(
                        get: { model.settings.quietEndHour ?? -1 },
                        set: { model.settings.quietEndHour = $0 < 0 ? nil : $0; model.commitSettings() }
                    )) {
                        Text("关闭").tag(-1)
                        ForEach(0..<24, id: \.self) { h in Text("\(h) 点").tag(h) }
                    }
                    .labelsHidden()
                    .frame(width: 92)
                }

                Divider()

                Toggle("登录失效时也发通知提醒",
                       isOn: Binding(
                        get: { model.settings.notifyOnLoginExpiry },
                        set: { model.settings.notifyOnLoginExpiry = $0; model.commitSettings() }
                       ))
                .toggleStyle(SpectrumToggleStyle())

                Toggle("开机自动启动",
                       isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                       ))
                .toggleStyle(SpectrumToggleStyle())
            }
        }
    }

    // 数据
    private func dataCard(_ p: SpectrumPalette) -> some View {
        SpectrumCard {
            VStack(alignment: .leading, spacing: 10) {
                SpectrumSectionTitle(title: "数据")
                HStack(spacing: 10) {
                    Button("清除演练记录") {
                        _ = model.clearDrillRecords()
                    }
                    .buttonStyle(.spectrumCompact())

                    Text("只删除 BV1test 开头的假记录")
                        .font(.system(size: 12))
                        .foregroundStyle(p.subtext)
                    Spacer()
                }
                Text(AppLog.dirURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(p.subtext)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - 小部件

struct AvatarView: View {
    let url: URL?
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.18))
            Text(String(name.prefix(1)))
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

extension BiliClient.QRState {
    var isErrorState: Bool {
        if case .failed = self { return true }
        return false
    }
}
