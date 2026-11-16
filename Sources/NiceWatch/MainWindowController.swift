import SwiftUI
import AppKit

/// 菜单和应用重开事件共用的窗口控制器，不依赖 SwiftUI 的代理包装对象。
@MainActor
final class MainWindowController {
    private let makeContent: @MainActor () -> AnyView
    private let activate: @MainActor () -> Void
    private(set) var window: NSWindow?

    init(makeContent: @escaping @MainActor () -> AnyView = { AnyView(RootView().environmentObject(AppModel.shared)) },
         activate: @escaping @MainActor () -> Void = {
             NSApp.unhide(nil)
             NSApp.activate(ignoringOtherApps: true)
         }) {
        self.makeContent = makeContent
        self.activate = activate
    }

    func present() {
        AppLog.info("打开主窗口")
        let target: NSWindow
        if let window {
            target = window
        } else {
            let hosting = NSHostingController(rootView: makeContent())
            let created = NSWindow(contentViewController: hosting)
            created.title = "NiceWatch"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.setContentSize(NSSize(width: 820, height: 640))
            created.center()
            created.isReleasedWhenClosed = false
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.backgroundColor = NSColor.windowBackgroundColor
            created.isMovableByWindowBackground = true
            created.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window = created
            target = created
        }
        if target.isMiniaturized { target.deminiaturize(nil) }
        // 外接屏断开后，避免窗口留在当前所有屏幕之外。
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(target.frame) }) {
            target.center()
        }
        activate()
        target.makeKeyAndOrderFront(nil)
        target.orderFrontRegardless()
    }
}
