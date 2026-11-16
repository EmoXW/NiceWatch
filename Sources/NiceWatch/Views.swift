import SwiftUI
import AppKit

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            NeuBackground()
            Group {
                if model.isLoggedIn {
                    MainView()
                } else {
                    LoginView()
                }
            }
            .padding(18)
        }
        .frame(minWidth: 780, minHeight: 580)
    }
}

// MARK: - 登录

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = NeuPalette.of(scheme)
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            VStack(spacing: 5) {
                Text("NiceWatch")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(p.text)
                Text("B站 UP 主更新监控 · Bark 推送到手机")
                    .font(.system(size: 12))
                    .foregroundStyle(p.subtext)
            }

            // 二维码放在凹陷的软垫里
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(p.base)
                    .frame(width: 268, height: 268)
                    .neuInset(radius: 24)

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
                            .font(.system(size: 11.5))
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
                .buttonStyle(.neuProminent)
                .frame(width: 200)
                .keyboardShortcut(.defaultAction)

                if case .success = model.qrState {
                    NeuTag(text: "已登录", icon: "checkmark.seal.fill", tint: p.success)
                }
            }

            Text("登录态仅以加密文件保存在本机应用目录（~/Library/Application Support/NiceWatch），不使用系统钥匙串。")
                .font(.system(size: 10.5))
                .foregroundStyle(p.subtext.opacity(0.8))
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
    @State private var tab: MainTab = MainTab.initial

    var body: some View {
        let p = NeuPalette.of(scheme)
        VStack(spacing: 14) {
            header(p)

            NeuSegmented(
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
    private func header(_ p: NeuPalette) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(p.base)
                        .frame(width: 30, height: 30)
                        .neuRaised(radius: 10, distance: 3)
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("NiceWatch")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(p.text)
                    Text(model.account?.uname ?? "未登录")
                        .font(.system(size: 10.5))
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
            .buttonStyle(.neuCompact())
            .disabled(model.isChecking)
        }
        .padding(.horizontal, 4)
    }
}

struct StatusStrip: View {
    let status: MonitorStatus
    let lastCheck: Date?
    @Environment(\.colorScheme) private var scheme

    private func color(_ p: NeuPalette) -> Color {
        switch status {
        case .ok: return p.success
        case .idle: return p.subtext
        case .checking: return p.accent
        case .loginExpired, .riskControlled, .networkError: return p.warning
        }
    }

    var body: some View {
        let p = NeuPalette.of(scheme)
        HStack(spacing: 6) {
            Circle()
                .fill(color(p))
                .frame(width: 7, height: 7)
                .shadow(color: color(p).opacity(0.6), radius: 3)
            Text(status.text)
                .font(.system(size: 11))
                .foregroundStyle(p.subtext)
            if let lastCheck {
                Text("· " + lastCheck.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.subtext.opacity(0.75))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .neuInset(radius: 10)
    }
}

// MARK: - 监控列表

struct MonitoredListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showPicker = false

    var body: some View {
        let p = NeuPalette.of(scheme)
        VStack(spacing: 12) {
            HStack {
                NeuSectionTitle(title: "监控中",
                                subtitle: "共 \(model.store.data.ups.count) 个 UP 主")
                Spacer()
                Button {
                    showPicker = true
                } label: {
                    Label("添加 UP 主", systemImage: "plus")
                }
                .buttonStyle(.neuCompact(.prominent))
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

    private func emptyState(_ p: NeuPalette) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(p.base).frame(width: 76, height: 76)
                    .neuRaised(radius: 38, distance: 6, strong: true)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(p.accent)
            }
            Text("还没有监控任何 UP 主")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(p.text)
            Text("从你的关注列表里挑一个，或者直接搜索名字添加。")
                .font(.system(size: 12))
                .foregroundStyle(p.subtext)
            Button("添加 UP 主") { showPicker = true }
                .buttonStyle(.neuProminent)
                .frame(width: 170)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ up: MonitoredUP, _ p: NeuPalette) -> some View {
        HStack(spacing: 12) {
            AvatarView(url: up.faceURL, name: up.name, size: 38)
                .neuRaised(radius: 19, distance: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(up.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(p.text)
                HStack(spacing: 6) {
                    NeuTag(text: up.enabled ? "监控中" : "已暂停",
                           icon: up.enabled ? "dot.radiowaves.left.and.right" : "pause.fill",
                           tint: up.enabled ? p.success : p.warning)
                    if let t = up.lastNotifiedAt {
                        Text("上次推送 " + t.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.subtext)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { up.enabled },
                set: { model.setUPEnabled(mid: up.mid, enabled: $0) }
            ))
            .toggleStyle(NeuToggleStyle())
            .labelsHidden()

            Button {
                model.removeUP(mid: up.mid)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.neuCompact(.danger))
            .help("取消监控")
        }
        .padding(14)
        .neuRaised(radius: 16, strong: true)
    }
}

// MARK: - 添加 UP 主

struct AddUPView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var keyword = ""

    var body: some View {
        let p = NeuPalette.of(scheme)
        ZStack {
            NeuBackground()
            VStack(spacing: 12) {
                HStack {
                    Text("添加 UP 主")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.text)
                    Spacer()
                    Button("完成") { dismiss() }
                        .buttonStyle(.neuCompact())
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(p.subtext)
                    NeuField {
                        TextField("搜索 UP 主名字，或从下方关注列表选择", text: $keyword)
                            .font(.system(size: 12.5))
                            .onSubmit { Task { await model.search(keyword: keyword) } }
                    }
                    if model.searching { ProgressView().controlSize(.small) }
                    Button("搜索") {
                        Task { await model.search(keyword: keyword) }
                    }
                    .buttonStyle(.neuCompact(.prominent))
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
                                        .buttonStyle(.neuCompact())
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
                                .buttonStyle(.neuCompact())
                            }
                        }
                    }
                    .padding(4)
                }
            }
            .padding(18)
        }
        .task {
            if model.followings.isEmpty {
                await model.refreshFollowings(page: 1)
            }
        }
    }

    private func sectionHeader(_ title: String,
                               p: NeuPalette,
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
        .background(NeuPalette.of(scheme).base.opacity(0.98))
    }

    @ViewBuilder
    private func row(mid: Int64, name: String, face: String,
                     subtitle: String, p: NeuPalette) -> some View {
        let monitored = model.isMonitored(mid)
        HStack(spacing: 10) {
            AvatarView(url: URL(string: face.hasPrefix("//") ? "https:" + face : face),
                       name: name, size: 30)
                .neuRaised(radius: 15, distance: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(p.text)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.subtext)
                        .lineLimit(1)
                }
            }
            Spacer()
            if monitored {
                NeuTag(text: "已监测", icon: "checkmark.circle.fill", tint: p.success)
                Button("取消") { model.removeUP(mid: mid) }
                    .buttonStyle(.neuCompact())
            } else {
                Button("监测") {
                    Task { await model.addUP(mid: mid, name: name, face: face) }
                }
                .buttonStyle(.neuCompact(.prominent))
            }
        }
        .padding(11)
        .neuRaised(radius: 13)
    }
}

// MARK: - 时间线

struct TimelineView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = NeuPalette.of(scheme)
        let items = model.store.timeline

        VStack(spacing: 12) {
            HStack {
                NeuSectionTitle(title: "时间线", subtitle: "最近 \(items.count) 条检测记录")
                Spacer()
            }

            if items.isEmpty {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(p.base).frame(width: 70, height: 70)
                            .neuRaised(radius: 35, distance: 5, strong: true)
                        Image(systemName: "clock")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(p.accent)
                    }
                    Text("还没有检测到更新")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(p.text)
                    Text("每 \(Settings.intervalLabel(model.settings.intervalClamped))检查一次，发现新视频会立刻推送。")
                        .font(.system(size: 11.5))
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

    private func row(_ item: SeenVideo, _ p: NeuPalette) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.author)
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.subtext)
                    Text("·")
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.subtext.opacity(0.6))
                    Text(item.pubDate.formatted(date: .numeric, time: .shortened))
                        .font(.system(size: 10.5))
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
            .buttonStyle(.neuCompact())
        }
        .padding(12)
        .neuRaised(radius: 14)
    }

    @ViewBuilder
    private func stateTag(_ s: SeenVideo.State, _ p: NeuPalette) -> some View {
        switch s {
        case .notified:
            NeuTag(text: "已推送", icon: "checkmark.circle", tint: p.success)
        case .pending:
            NeuTag(text: "待推送", icon: "clock", tint: p.warning)
        case .failed:
            NeuTag(text: "失败", icon: "exclamationmark.triangle", tint: p.danger)
        case .muted:
            NeuTag(text: "静默", icon: "moon.zzz")
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
        let p = NeuPalette.of(scheme)
        ScrollView {
            VStack(spacing: 14) {
                accountCard(p)
                channelCard(p)
                contentCard(p)
                monitorCard(p)
                dataCard(p)
                if let err = model.lastError {
                    NeuCard {
                        VStack(alignment: .leading, spacing: 6) {
                            NeuSectionTitle(title: "最近错误")
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
    private func accountCard(_ p: NeuPalette) -> some View {
        NeuCard {
            VStack(alignment: .leading, spacing: 12) {
                NeuSectionTitle(title: "账号")
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isLoggedIn ? p.success : p.warning)
                        .frame(width: 8, height: 8)
                        .shadow(color: (model.isLoggedIn ? p.success : p.warning).opacity(0.6), radius: 3)
                    Text(model.isLoggedIn ? "已登录 \(model.account?.uname ?? "")" : "未登录")
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.text)
                    Spacer()
                    Button("重新登录") { model.beginLogin() }
                        .buttonStyle(.neuCompact())
                    Button("退出登录") { model.logout() }
                        .buttonStyle(.neuCompact(.danger))
                }
            }
        }
    }

    // 通知通道
    private func channelCard(_ p: NeuPalette) -> some View {
        NeuCard {
            VStack(alignment: .leading, spacing: 10) {
                NeuSectionTitle(title: "通知通道", subtitle: "Bark · 推送到 iPhone 通知中心")

                NeuField {
                    TextField("", text: Binding(
                        get: { model.settings.barkKey ?? "" },
                        set: { model.settings.barkKey = $0; model.commitSettings() }
                    ), prompt: Text("粘贴 Bark App 里的 key").foregroundColor(p.subtext))
                    .font(.system(size: 12, design: .monospaced))
                }

                Text("Bark App 首页那条 https://api.day.app/xxx 地址里，最后一段就是 key。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.subtext)
            }
        }
    }

    // 通知内容
    private func contentCard(_ p: NeuPalette) -> some View {
        NeuCard {
            VStack(alignment: .leading, spacing: 10) {
                NeuSectionTitle(title: "通知内容", subtitle: "变量：{author} {title} {bvid} {url}")

                TextField("", text: Binding(
                    get: { model.settings.template },
                    set: { model.settings.template = $0; model.commitSettings() }
                ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(p.text)
                .lineLimit(3...4)
                .padding(10)
                .neuInset(radius: 12)

                HStack(spacing: 10) {
                    Button("发送测试消息") {
                        busy = true
                        Task {
                            testResult = await model.sendTestMessage()
                            busy = false
                        }
                    }
                    .buttonStyle(.neuCompact())
                    .disabled(busy)

                    Button("用最新投稿演练") {
                        busy = true
                        Task {
                            testResult = await model.simulateNewVideo()
                            busy = false
                        }
                    }
                    .buttonStyle(.neuCompact(.prominent))
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
    private func monitorCard(_ p: NeuPalette) -> some View {
        NeuCard {
            VStack(alignment: .leading, spacing: 14) {
                NeuSectionTitle(title: "监控")

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("检查间隔")
                            .font(.system(size: 12.5))
                            .foregroundStyle(p.text)
                        Spacer()
                        NeuTag(text: Settings.intervalLabel(model.settings.intervalClamped),
                               icon: "timer", tint: p.accent)
                    }
                    NeuSlider(
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

                Divider().opacity(0.35)

                HStack {
                    Text("静默时段")
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.text)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.settings.quietStartHour ?? -1 },
                        set: { model.settings.quietStartHour = $0 < 0 ? nil : $0; model.commitSettings() }
                    )) {
                        Text("关闭").tag(-1)
                        ForEach(0..<24, id: \.self) { h in Text("\(h) 点").tag(h) }
                    }
                    .labelsHidden()
                    .frame(width: 84)

                    Text("→").foregroundStyle(p.subtext)

                    Picker("", selection: Binding(
                        get: { model.settings.quietEndHour ?? -1 },
                        set: { model.settings.quietEndHour = $0 < 0 ? nil : $0; model.commitSettings() }
                    )) {
                        Text("关闭").tag(-1)
                        ForEach(0..<24, id: \.self) { h in Text("\(h) 点").tag(h) }
                    }
                    .labelsHidden()
                    .frame(width: 84)
                }

                Divider().opacity(0.35)

                Toggle("登录失效时也发通知提醒",
                       isOn: Binding(
                        get: { model.settings.notifyOnLoginExpiry },
                        set: { model.settings.notifyOnLoginExpiry = $0; model.commitSettings() }
                       ))
                .toggleStyle(NeuToggleStyle())

                Toggle("开机自动启动",
                       isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                       ))
                .toggleStyle(NeuToggleStyle())
            }
        }
    }

    // 数据
    private func dataCard(_ p: NeuPalette) -> some View {
        NeuCard {
            VStack(alignment: .leading, spacing: 10) {
                NeuSectionTitle(title: "数据")
                HStack(spacing: 10) {
                    Button("清除演练记录") {
                        _ = model.clearDrillRecords()
                    }
                    .buttonStyle(.neuCompact())

                    Text("只删除 BV1test 开头的假记录")
                        .font(.system(size: 10.5))
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
