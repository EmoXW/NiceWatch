import Foundation

// 入口：带 --selftest 时走无界面自检，否则启动 SwiftUI 菜单栏应用
if CommandLine.arguments.contains("--selftest") {
    AppLog.reset()
    SelfTest.run()
    exit(0)
} else if CommandLine.arguments.contains("--simulate") {
    // 无界面演练：走与「用最新投稿演练」按钮完全相同的路径
    Task { @MainActor in
        let model = AppModel.shared
        let result = await model.simulateNewVideo()
        print("演练结果：\(result)")
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--backofftest") {
    SelfTest.backoffTest()
    exit(0)
} else if CommandLine.arguments.contains("--storetest") {
    SelfTest.storeRoundtrip()
    exit(0)
} else {
    NiceWatchApp.main()
}
