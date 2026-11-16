import SwiftUI
import AppKit

/// 菜单栏常驻应用入口（无 Dock 图标，靠 Info.plist 的 LSUIElement 控制）
struct NiceWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.unreadCount > 0 ? "bell.badge.fill" : "bell")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 主窗口由 AppKit 直接管理：
/// 纯 MenuBarExtra 应用里 SwiftUI 的 Window scene 不会在启动时自动创建，
/// 导致视图 onAppear 不触发、扫码流程永远不启动。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("applicationDidFinishLaunching")

        // 单实例保护：launchd 拉起 / 用户再次打开时，避免出现两个监控进程
        let bundleID = Bundle.main.bundleIdentifier ?? "com.wyh.nicewatch"
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            AppLog.info("已有实例在运行（pid \(others.map(\.processIdentifier))），本实例退出")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { self.showMainWindow() }
    }

    func showMainWindow() {
        AppLog.info("showMainWindow 调用")
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: RootView().environmentObject(AppModel.shared))
        let w = NSWindow(contentViewController: hosting)
        w.title = "NiceWatch"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.setContentSize(NSSize(width: 820, height: 640))
        w.center()
        w.isReleasedWhenClosed = false
        // 让新拟态底色一直铺到标题栏下面，避免顶部出现一条白色
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = NSColor.windowBackgroundColor
        w.isMovableByWindowBackground = true
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppLog.info("主窗口已创建并显示")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text(model.isLoggedIn ? "监控 \(model.store.data.ups.filter(\.enabled).count) 个 UP 主" : "未登录")
        Text(model.status.text)

        if let last = model.lastCheckAt {
            Text("上次检查：" + last.formatted(date: .omitted, time: .shortened))
        }
        if let next = model.nextCheckAt, model.isLoggedIn {
            Text("下次检查：" + next.formatted(date: .omitted, time: .shortened))
        }

        Divider()

        Button("立即检查") {
            Task { await model.checkNow() }
        }
        .disabled(!model.isLoggedIn || model.isChecking)

        Button("打开主窗口") {
            (NSApp.delegate as? AppDelegate)?.showMainWindow()
        }

        Divider()

        Button("退出 NiceWatch") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
