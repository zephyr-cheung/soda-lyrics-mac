import AppKit
import SwiftUI
import SodaLyrics

/// 自绘 NSStatusItem 菜单栏：位图缓存 + CALayer contentsRect 平移（60fps 跑马，零逐帧重绘）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = NowPlayingStore()
    /// 面板帧级进度（30fps）：只驱动当前行逐字与进度条，不触碰歌词列表
    private let ticker = ProgressTicker()
    private var drawTimer: Timer?
    private var marqueeOffset: CGFloat = 0
    private var lastText = ""
    private var textWidth: CGFloat = 0
    /// 换句时渲染一次的位图（滚动文本=span 宽含间隙；短文本=maxWidth 宽居中）
    private var cachedBitmap: NSImage?
    private var bitmapSpan: CGFloat = 1

    private let maxWidth: CGFloat = 260
    private let height: CGFloat = 20
    private let defaultSpeed: CGFloat = 30    // 默认跑马速度 pt/s（句末/间隙）
    private let minSpeed: CGFloat = 12        // 防超长句停滞
    private let maxSpeed: CGFloat = 240       // 防超短句飞滚
    private let dt: CGFloat = 1.0 / 60.0      // 60fps 跑马（contentsRect 平移，成本极低）
    /// 面板 25fps 刷新节流时间戳（LayoutGraph 重算有真实成本，仅 popover 可见时推进 ticker）
    private var lastTickerAt: TimeInterval = 0
    /// 状态栏 layer 视窗是否需要重设（静态短文本时每帧零层写）
    private var layerDirty = false
    /// 当前句的恒定跑马速度（pt/s，换句时按行总时长重算）
    private var marqueeStepPerSec: CGFloat = 30
    private let font = NSFont.menuBarFont(ofSize: 13)

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()

        // 固定长度 = 跑马视窗宽：layer 方案不再设置 button.image，
        // variableLength 无内容时宽度会塌缩成不可见的空白
        statusItem = NSStatusBar.system.statusItem(withLength: 260)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        // layer 化：滚动走 contentsRect（GPU），不再每帧重绘位图
        statusItem.button?.wantsLayer = true
        statusItem.button?.layer?.contentsGravity = .resize

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 440)
        popover.contentViewController = NSHostingController(rootView: LyricsPanel(store: store, ticker: ticker))
        popover.behavior = .transient

        // 自动更新：开关开启时启动后静默检查 GitHub 新版本
        AutoUpdateCheckOnLaunch()

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.redraw()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        drawTimer = t
        redraw()
        NowPlayingStore.log("app-ready")
    }

    private func redraw() {
        let now = Date().timeIntervalSinceReferenceDate
        // ticker 25fps 节流：仅 popover 可见时推进（歌词列表/面板主体依赖低频 store，不失效）
        if now - lastTickerAt >= 0.04 {
            lastTickerAt = now
            if popover.isShown { ticker.positionMs = store.displayPos }
        }

        let text = store.barText
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        if text != lastText {
            lastText = text
            textWidth = (text as NSString).size(withAttributes: attrs).width
            marqueeOffset = 0
            marqueeStepPerSec = defaultSpeed
            if textWidth > maxWidth {
                let span = textWidth + 80
                // 换句时按「整圈行程 / 行总时长」固定圈速：整句匀速滚完一圈，句内不变速
                if let idx = store.currentIndex, idx < store.lines.count {
                    let line = store.lines[idx]
                    let durSec = CGFloat(max(0.8, Double(line.endMs - line.startMs))) / 1000
                    marqueeStepPerSec = min(max(span / durSec, minSpeed), maxSpeed)
                }
            }
            // 一次性渲染整幅位图。滚动文本：左右各留 maxWidth 空白（contentsRect 全程合法，
            // 避免视窗越界导致的闪烁）；短文本：maxWidth 宽居中
            let pad = textWidth > maxWidth ? maxWidth : 0
            let bitmapW = textWidth > maxWidth ? textWidth + 80 + pad * 2 : maxWidth
            bitmapSpan = bitmapW
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let s = attrStr.size()
            let img = NSImage(size: NSSize(width: bitmapW, height: height))
            img.lockFocus()
            let drawX = (textWidth > maxWidth) ? pad + (maxWidth - s.width) / 2 : (bitmapW - s.width) / 2
            attrStr.draw(with: NSRect(x: drawX, y: (height - s.height) / 2, width: s.width, height: s.height), options: [.usesLineFragmentOrigin])
            img.unlockFocus()
            cachedBitmap = img
            if let layer = statusItem.button?.layer {
                layer.contents = img
            }
            layerDirty = true   // 文本/位图变化 → 需重设视窗
        }

        guard let layer = statusItem.button?.layer else { return }
        // 防御：系统可能重置 button 的 layer 内容，每帧确保位图在位（identity 比较）
        if let cur = layer.contents as? NSImage, let cached = cachedBitmap, cur !== cached {
            layer.contents = cached
            layerDirty = true
        }
        // 视窗更新：长文本滚动每帧；短文本仅位图/文本变化帧（静态关闭态零每帧层写）
        if textWidth > maxWidth {
            let span = textWidth + 80
            marqueeOffset += marqueeStepPerSec * dt
            if marqueeOffset > span {
                // 滚完一圈：停在尾部等换行，不再归零重滚本句。
                // 归零会让视窗从「句尾」瞬间跳回「句首」，而 currentIndex 依赖 100ms 快照
                // 可能还没切到下一句——造成「本句闪回开头、停 0.1s 才换句」的不连贯观感。
                // 换行（text 变化）时位图重建 + offset 归零，新句自然从头滑入。
                marqueeOffset = span
            }
            // 视窗 = 位图 [offset, offset + maxWidth]，恒在 [0, totalW] 内；offset=0 时视窗落在
            // 左侧空白区（与原「初始全空、文本右缘滑入」视觉一致）
            layer.contentsRect = CGRect(x: marqueeOffset / bitmapSpan, y: 0, width: maxWidth / bitmapSpan, height: 1)
            layerDirty = false
        } else if layerDirty {
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            layerDirty = false
        }
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