import AppKit
import SwiftUI
import SodaLyrics
import Darwin

/// 自绘 NSStatusItem 菜单栏：位图缓存 + CALayer contentsRect 平移（60fps 跑马，零逐帧重绘）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 供设置面板调节状态栏宽度等
    static weak var current: AppDelegate?
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

    /// 状态栏歌词视窗宽度（设置面板可拖动调节，UserDefaults 持久化）
    private var barWidth: CGFloat = 260
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
    /// 状态栏字体（设置面板可调：字体名 nil=系统菜单栏字体；字号 10~15）
    private var barFontName: String?
    private var barFontSize: CGFloat = 13

    private var barFont: NSFont {
        if let n = barFontName, let f = NSFont(name: n, size: barFontSize) { return f }
        return NSFont.menuBarFont(ofSize: barFontSize)
    }

    /// 单实例锁 fd（进程生命周期持有；崩溃/退出自动释放）
    private static var lockFD: Int32 = -1

    /// 获取单实例锁：已有实例运行时返回 false（调用方应退出）
    @discardableResult
    static func acquireInstanceLock() -> Bool {
        let dir = NSString(string: "~/Library/Application Support/SodaLyrics").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("instance.lock")
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    /// 清理残留的孤儿采集进程（多次运行/升级留下的 core 与 python 代理会干扰 mediaremoted
    /// 的客户端投递——数据只给其中一个客户端，导致“不监听汽水音乐”）
    func cleanupOrphanProcesses() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid,command"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            // 必须先在“进程退出前”消费管道：ps 全量输出（含超长命令行）超过 64KB 管道缓冲，
            // 先 waitUntilExit 会因 ps 写满阻塞而永久死锁（此前导致启动卡死）
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            var victimPIDs: [Int32] = []
            for line in out.split(separator: "\n") {
                let isCore = line.contains("libexec/soda-core") || line.contains("target/release/soda-lyrics")
                let isProbe = line.contains("libmr_full.dylib")
                if isCore || isProbe {
                    NowPlayingStore.log("cleanup-match: \(line.prefix(80))")
                }
                guard isCore || isProbe else { continue }
                if line.contains("grep") || line.contains("ps -axo") { continue }
                guard let first = line.split(separator: " ").first else { continue }
                if let pid = Int32(first), pid > 1 {
                    victimPIDs.append(pid)
                }
            }
            for pid in victimPIDs {
                let r = kill(pid, SIGKILL)
                NowPlayingStore.log("orphan kill pid=\(pid) rc=\(r)")
            }
            if !victimPIDs.isEmpty {
                Thread.sleep(forTimeInterval: 0.5)
            }
        } catch {
            NowPlayingStore.log("cleanup error: \(error.localizedDescription)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护：已有实例直接退出（历史 bug：多实例互相干扰 MediaRemote 采集）
        let locked = Self.acquireInstanceLock()
        NowPlayingStore.log("instance lock acquired: \(locked)")
        guard locked else {
            NowPlayingStore.log("another instance is running, exiting")
            NSApplication.shared.terminate(nil)
            return
        }
        cleanupOrphanProcesses()
        Self.current = self
        let saved = UserDefaults.standard.double(forKey: "sodaBarWidth")
        if saved >= 120 { barWidth = CGFloat(saved) }
        let savedSize = UserDefaults.standard.double(forKey: "sodaBarFontSize")
        if savedSize >= 10 && savedSize <= 15 { barFontSize = CGFloat(savedSize) }
        let savedName = (UserDefaults.standard.string(forKey: "sodaBarFont") ?? "").trimmingCharacters(in: .whitespaces)
        barFontName = savedName.isEmpty ? nil : savedName
        rainbowMode = UserDefaults.standard.bool(forKey: "sodaRainbow")
        if let hex = UserDefaults.standard.string(forKey: "sodaBarColor"), hex.count == 6,
           let r = Int(hex.prefix(2), radix: 16),
           let g = Int(hex.dropFirst(2).prefix(2), radix: 16),
           let b = Int(hex.dropFirst(4), radix: 16) {
            barTextColor = NSColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0)
        }
        store.start()

        // 固定长度 = 跑马视窗宽：layer 方案不再设置 button.image，
        // variableLength 无内容时宽度会塌缩成不可见的空白
        statusItem = NSStatusBar.system.statusItem(withLength: barWidth)
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
        let attrs: [NSAttributedString.Key: Any] = [.font: barFont, .foregroundColor: barTextColor ?? NSColor.labelColor]

        if text != lastText {
            lastText = text
            textWidth = (text as NSString).size(withAttributes: attrs).width
            marqueeOffset = 0
            marqueeStepPerSec = defaultSpeed
            if textWidth > barWidth {
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
            let pad = textWidth > barWidth ? barWidth : 0
            let bitmapW = textWidth > barWidth ? textWidth + 80 + pad * 2 : barWidth
            bitmapSpan = bitmapW
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let s = attrStr.size()
            let img = NSImage(size: NSSize(width: bitmapW, height: height))
            img.lockFocus()
            let drawX = (textWidth > barWidth) ? pad + (barWidth - s.width) / 2 : (bitmapW - s.width) / 2
            if rainbowMode, !text.isEmpty {
                // 彩虹渐变：按字符位置色相循环（浅色模式自动用深色亮度保证可读）
                let darkBar = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let brightness: CGFloat = darkBar ? 0.95 : 0.32
                var penX = drawX
                let baselineY = (height - s.height) / 2
                let count = max(text.count, 1)
                for (i, ch) in text.enumerated() {
                    let hue = CGFloat(i) / CGFloat(count - 1)
                    let color = NSColor(hue: hue, saturation: 0.9, brightness: brightness, alpha: 1.0)
                    let chStr = NSAttributedString(string: String(ch), attributes: [.font: barFont, .foregroundColor: color])
                    let w = chStr.size().width
                    chStr.draw(with: NSRect(x: penX, y: baselineY, width: w, height: s.height), options: [.usesLineFragmentOrigin])
                    penX += w
                }
            } else {
                attrStr.draw(with: NSRect(x: drawX, y: (height - s.height) / 2, width: s.width, height: s.height), options: [.usesLineFragmentOrigin])
            }
            img.unlockFocus()
            cachedBitmap = img
            if let layer = statusItem.button?.layer {
                layer.contents = img
            }
            layerDirty = true   // 文本/位图变化 → 需重设视窗
        }

        guard let layer = statusItem.button?.layer else { return }
        // 防御：系统可能重置/清空 button 的 layer 内容（如打开 popover 瞬间），
        // 每帧确保位图在位：contents 为 nil、非 NSImage 或非缓定位图一律恢复
        if let cached = cachedBitmap {
            let cur = layer.contents
            let mismatched = cur == nil || (cur as? NSImage) !== cached
            if mismatched {
                layer.contents = cached
                layerDirty = true
            }
        }
        // 视窗更新：长文本滚动每帧；短文本仅位图/文本变化帧（静态关闭态零每帧层写）
        if textWidth > barWidth {
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
            layer.contentsRect = CGRect(x: marqueeOffset / bitmapSpan, y: 0, width: barWidth / bitmapSpan, height: 1)
            layerDirty = false
        } else if layerDirty {
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            layerDirty = false
        }
        statusItem.button?.toolTip = text
    }

    /// 当前状态栏歌词宽度（设置面板读取）
    var barWidthValue: CGFloat { barWidth }

    /// 状态栏歌词自定义单色（nil = 系统默认；与彩虹二选一）
    private var barTextColor: NSColor?

    /// 状态栏歌词彩虹渐变模式（默认关闭，设置面板开关）
    private var rainbowMode = false

    /// 当前状态栏字体设置（设置面板读取）
    var barFontNameValue: String? { barFontName }
    var barFontSizeValue: CGFloat { barFontSize }

    /// 彩虹渐变开关：持久化 + 强制重建位图
    var rainbowModeValue: Bool { rainbowMode }

    func setRainbowMode(_ on: Bool) {
        rainbowMode = on
        UserDefaults.standard.set(on, forKey: "sodaRainbow")
        lastText = ""          // 触发下一帧位图重建
    }

    /// 当前自定义颜色（设置面板读取；nil=默认）
    var barTextColorValue: NSColor? { barTextColor }

    /// 设置单色（nil=默认色；持久化 hex）：与彩虹互斥——设置面板保证选色时关彩虹
    func setBarColor(_ c: NSColor?) {
        barTextColor = c
        if let c, let srgb = c.usingColorSpace(.sRGB) {
            let hex = String(format: "%02X%02X%02X",
                             Int(srgb.redComponent * 255),
                             Int(srgb.greenComponent * 255),
                             Int(srgb.blueComponent * 255))
            UserDefaults.standard.set(hex, forKey: "sodaBarColor")
        } else {
            UserDefaults.standard.removeObject(forKey: "sodaBarColor")
        }
        lastText = ""
    }

    /// 设置状态栏字体与字号（立即重绘位图）
    func setBarFont(name: String?, size: CGFloat) {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespaces)
        barFontName = trimmed.isEmpty ? nil : trimmed
        barFontSize = min(max(size, 10), 15)
        UserDefaults.standard.set(trimmed, forKey: "sodaBarFont")
        UserDefaults.standard.set(Double(barFontSize), forKey: "sodaBarFontSize")
        lastText = ""          // 触发下一帧位图重建（字体变化）
    }

    /// 调节状态栏歌词宽度（设置面板拖动）：持久化 + 立即生效（强制重建位图）
    func setBarWidth(_ w: CGFloat) {
        let clamped = min(max(w, 140), 440)
        barWidth = clamped
        UserDefaults.standard.set(Double(clamped), forKey: "sodaBarWidth")
        statusItem.length = clamped
        lastText = ""          // 触发下一帧位图重建（宽度变化影响布局）
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