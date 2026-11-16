import SwiftUI
import AppKit

/// 菜单栏常驻应用入口（无 Dock 图标，靠 Info.plist 的 LSUIElement 控制）
struct NiceWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(openMainWindow: { appDelegate.showMainWindow() })
                .environmentObject(model)
        } label: {
            Image(nsImage: IconArtwork.menuBarImage(unread: model.unreadCount > 0))
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 主窗口由 AppKit 直接管理：
/// 纯 MenuBarExtra 应用里 SwiftUI 的 Window scene 不会在启动时自动创建，
/// 导致视图 onAppear 不触发、扫码流程永远不启动。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let mainWindow = MainWindowController()

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
        mainWindow.present()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MenuContent: View {
    let openMainWindow: () -> Void
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
            openMainWindow()
        }

        Divider()

        Button("退出 NiceWatch") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
