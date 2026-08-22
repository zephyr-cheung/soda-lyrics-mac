import AppKit
import SwiftUI
import SodaLyrics

/// 自绘 NSStatusItem 菜单栏：跑马灯由 0.1s 原生 Timer 驱动（避免 TimelineView 饿死 runloop）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = NowPlayingStore()
    private var drawTimer: Timer?
    private var marqueeOffset: CGFloat = 0
    private var lastText = ""
    private var textWidth: CGFloat = 0

    private let maxWidth: CGFloat = 260
    private let height: CGFloat = 20
    private let step: CGFloat = 3    // 每帧 3pt → 30pt/s

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 440)
        popover.contentViewController = NSHostingController(rootView: LyricsPanel(store: store))
        popover.behavior = .transient

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.redraw() }
        }
        RunLoop.main.add(t, forMode: .common)
        drawTimer = t
        redraw()
        NowPlayingStore.log("app-ready")
    }

    private func redraw() {
        let text = store.barText
        let font = NSFont.menuBarFont(ofSize: 13)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let w = (text as NSString).size(withAttributes: attrs).width

        if text != lastText {
            lastText = text
            textWidth = w
            marqueeOffset = 0
        }

        var x: CGFloat = 0
        if textWidth > maxWidth {
            let span = textWidth + 80
            marqueeOffset += step
            if marqueeOffset > span { marqueeOffset = 0 }
            x = maxWidth - marqueeOffset
        } else {
            x = (maxWidth - textWidth) / 2
        }

        let img = NSImage(size: NSSize(width: maxWidth, height: height))
        img.lockFocus()
        (text as NSString).draw(at: NSPoint(x: x, y: (height - font.ascender - font.descender) / 2), withAttributes: attrs)
        img.unlockFocus()

        statusItem.button?.image = img
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = text
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
        }
    }
}

/// 纯 AppKit 入口：不再使用 SwiftUI App 外壳（其 Settings scene 会在应用菜单注册
/// 无内容的「设置…」项，菜单栏工具不需要），直接以 AppDelegate 驱动
@main
enum SodaLyricsMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // 菜单栏工具：不占 Dock、不抢焦点（SwiftUI App 外壳默认 .regular 会显示 Dock 图标）
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}