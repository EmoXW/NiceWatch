import AppKit

/// 单色模板图标由 macOS 按菜单栏外观着色，避免浅色和深色模式下对比不足。
enum IconArtwork {
    static func menuBarImage(unread: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let tile = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16, height: 16),
                                    xRadius: 4, yRadius: 4)
            tile.fill()

            // 负形播放键：使用透明镂空，随系统模板颜色一起变化。
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            let play = NSBezierPath()
            play.move(to: NSPoint(x: 7, y: 5))
            play.line(to: NSPoint(x: 7, y: 13))
            play.line(to: NSPoint(x: 13, y: 9))
            play.close()
            play.fill()
            if unread {
                NSBezierPath(ovalIn: NSRect(x: 12, y: 11, width: 8, height: 8)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            if unread {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14, y: 13, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = unread ? "NiceWatch，有新投稿" : "NiceWatch"
        return image
    }
}
