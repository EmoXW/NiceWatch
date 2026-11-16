import XCTest
import SwiftUI
import AppKit
@testable import NiceWatch

final class MainWindowTests: XCTestCase {
    @MainActor
    func testReopensSameWindowAfterClosing() {
        _ = NSApplication.shared
        var activations = 0
        var contentCreations = 0
        let controller = MainWindowController(makeContent: {
            contentCreations += 1
            return AnyView(Text("Offline window regression test"))
        }, activate: { activations += 1 })
        controller.present()
        guard let window = controller.window else { return XCTFail("Window was not created") }
        defer { window.close() }
        XCTAssertTrue(window.isVisible)
        window.close()
        XCTAssertFalse(window.isVisible)
        controller.present()
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(contentCreations, 1)
        XCTAssertEqual(activations, 2)
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        controller.present()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(activations, 3)
    }
}
