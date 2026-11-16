// 离线真实 SwiftUI 渲染：使用临时数据，不读取账号，不发送请求。
// swiftc -parse-as-library Sources/NiceWatch/{除 main.swift 外的文件} tools/render_ui_preview.swift -o /tmp/nicewatch-preview
import AppKit
import SwiftUI

@main
struct UIPreview {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/nicewatch-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        let model = AppModel(store: store, restore: false, notifiers: [])
        model.account = AccountInfo(mid: 1, uname: "NiceWatch 演示账号", face: "", level: 5)
        model.isLoggedIn = true
        model.status = .ok
        model.lastCheckAt = Date()
        model.isLoggingIn = true
        // 登录页展示加载态，预览不申请真实登录二维码。
        model.qrImage = nil
        let names = ["科技观察室", "日常放映厅", "设计灵感集"]
        store.data.ups = names.enumerated().map { index, name in
            var up = MonitoredUP(mid: Int64(index + 1), name: name, face: "", enabled: index != 2)
            up.lastNotifiedAt = Date().addingTimeInterval(-1800)
            return up
        }
        model.followings = [UPBrief(mid: 1, uname: names[0], face: nil, sign: "分享科技与生活"),
                            UPBrief(mid: 4, uname: "影像笔记", face: nil, sign: "记录每一个好故事")]
        model.followingsTotal = 2
        for (i, state) in [SeenVideo.State.notified, .pending, .failed].enumerated() {
            let v = VideoItem(bvid: "BVpreview\(i)", title: ["本周科技观察：那些值得关注的新变化", "周末放映：生活里的每一帧", "从留白开始，做一个清晰的界面"][i],
                              author: names[i], mid: Int64(i + 1), pubdate: Int(Date().timeIntervalSince1970) - i * 3600, cover: "")
            _ = store.markSeen(v, state: state)
        }
        for scheme in [ColorScheme.light, .dark] {
            for page in ["monitor", "timeline", "settings", "settings-window", "login", "add", "confirm-remove", "confirm-clear"] {
                let content: AnyView
                switch page {
                case "login": content = AnyView(LoginView())
                case "add": content = AnyView(AddUPView())
                case "confirm-remove":
                    content = AnyView(SpectrumConfirmation(action: .removeUP(store.data.ups[0]), onCancel: {}, onConfirm: {}))
                case "confirm-clear":
                    content = AnyView(SpectrumConfirmation(action: .clearAllRecords, onCancel: {}, onConfirm: {}))
                default:
                    let tab: MainTab = page == "timeline" ? .timeline : page.hasPrefix("settings") ? .settings : .monitor
                    content = AnyView(MainView(tab: tab))
                }
                let size = NSSize(width: page.hasPrefix("confirm-") ? 520 : page == "add" ? 580 : 820,
                                  height: page.hasPrefix("confirm-") ? 420 : page == "settings" ? 1250 : page == "add" ? 500 : 640)
                let root = ZStack { SpectrumBackground(); content.padding(24) }
                    .environmentObject(model).environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height)
                let hosting = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = hosting
                window.setContentSize(size)
                hosting.layoutSubtreeIfNeeded()
                window.display()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("Render failed") }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let name = "\(page)-\(scheme == .dark ? "dark" : "light").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
                window.orderOut(nil)
            }
        }
        print("Rendered 16 previews to \(output.path)")
    }
}
