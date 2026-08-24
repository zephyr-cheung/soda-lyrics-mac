import SwiftUI
import AppKit
import SodaLyrics

/// 应用信息（当前版本：发版时同步）
enum AppInfo {
    static let version = "0.3.6"
    static let repo = "https://github.com/zephyr-cheung/soda-lyrics-mac"
    static let author = "https://github.com/zephyr-cheung"
}

/// 设置面板（展开面板内切换视图）：运行方式 / 更新检测与自动更新 / 关于 / 退出
struct SettingsView: View {
    let onClose: () -> Void

    /// 状态模型（共享单例：避免 @ObservedObject 默认值在 body 重建时重置）
    final class Model: ObservableObject {
        static let shared = Model()
        @Published var checkState: Check = .idle
        @Published var updating = false
        @Published var runMode = "检测中…"
        /// 拖动中的宽度预览值（nil = 未拖动，显示实际值）
        @Published var draggingWidth: CGFloat?
        enum Check: Equatable { case idle, checking, upToDate, found(String), failed(String) }
    }

    @ObservedObject private var model = Model.shared

    /// 当前状态栏歌词宽度（AppDelegate 实时值）
    private var currentBarWidth: CGFloat {
        AppDelegate.current?.barWidthValue ?? 260
    }

    /// 单个颜色圆点（拆分出独立函数：内联组合会让编译器类型推断超时）
    private func colorSwatch(_ color: NSColor?, selected: Bool) -> some View {
        let fillColor = Color(nsColor: color ?? NSColor.labelColor)
        let borderColor = Color(nsColor: selected ? NSColor.controlAccentColor : NSColor.separatorColor)
        let width: CGFloat = selected ? 2.5 : 1
        return Circle()
            .fill(fillColor)
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(borderColor, lineWidth: width))
    }

    /// 预设色板（名称, 颜色；nil = 系统默认）
    private var colorPresets: [(String, NSColor?)] {
        [
            ("默认", nil),
            ("白色", .white),
            ("红色", .systemRed),
            ("橙色", .systemOrange),
            ("黄色", .systemYellow),
            ("绿色", .systemGreen),
            ("青色", .systemTeal),
            ("蓝色", .systemBlue),
            ("紫色", .systemPurple),
            ("粉色", .systemPink),
            ("黑色", .black),
        ]
    }

    private var rainbowOn: Bool {
        UserDefaults.standard.bool(forKey: "sodaRainbow")
    }

    /// 颜色 hex（sRGB 解析；动态系统色按当前外观解析，保证与持久化 hex 可比）
    private func hexOf(_ c: NSColor?) -> String? {
        guard let c, let srgb = c.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X",
                      Int(srgb.redComponent * 255), Int(srgb.greenComponent * 255), Int(srgb.blueComponent * 255))
    }

    private func isColorSelected(_ c: NSColor?) -> Bool {
        // 用 hex 比较：重启后当前色是从 hex 重建的静态色，与预设动态系统色 isEqual 会失败
        hexOf(AppDelegate.current?.barTextColorValue) == hexOf(c)
    }

    /// 应用颜色：非默认色自动关闭彩虹（二选一）；默认色保留当前彩虹状态
    private func applyColorPreset(_ c: NSColor?) {
        AppDelegate.current?.setBarColor(c)
        if c != nil { AppDelegate.current?.setRainbowMode(false) }
    }

    /// 可选状态栏字体（显示名, postscript 名；"" = 系统菜单栏字体）——全部 macOS 自带
    private var fontChoices: [(String, String)] {
        [
            ("系统菜单栏字体", ""),
            // 苹方（PingFang SC）全字重
            ("苹方-简 常规", "PingFangSC-Regular"),
            ("苹方-简 中黑", "PingFangSC-Medium"),
            ("苹方-简 中粗", "PingFangSC-Semibold"),
            ("苹方-简 细体", "PingFangSC-Light"),
            ("苹方-简 极细", "PingFangSC-Thin"),
            ("苹方-简 特细", "PingFangSC-Ultralight"),
            // 中文字体（postscript 名已逐一校验有效）
            ("黑体-简 常规", "STHeitiSC-Light"),
            ("黑体-简 中黑", "STHeitiSC-Medium"),
            ("宋体-简 常规", "STSongti-SC-Regular"),
            ("宋体-简 粗体", "STSongti-SC-Bold"),
            ("宋体-简 细体", "STSongti-SC-Light"),
            ("宋体-简 黑体", "STSongti-SC-Black"),
            ("楷体-简 常规", "STKaitiSC-Regular"),
            ("楷体-简 粗体", "STKaitiSC-Bold"),
            ("楷体-简 特粗", "STKaitiSC-Black"),
            ("圆体-简 常规", "STYuanti-SC-Regular"),
            ("圆体-简 细体", "STYuanti-SC-Light"),
            ("圆体-简 粗体", "STYuanti-SC-Bold"),
            ("华文仿宋", "STFangsong"),
            // 华文字库
            ("华文细黑", "STXihei"),
            ("华文宋体", "STSong"),
            ("华文楷体", "STKaiti"),
            ("华文黑体", "STHeitiSC-Medium"),
            // 西文无衬线
            ("Helvetica Neue 常规", "HelveticaNeue"),
            ("Helvetica Neue 细体", "HelveticaNeue-Light"),
            ("Helvetica Neue 中黑", "HelveticaNeue-Medium"),
            ("Arial", "ArialMT"),
            ("Arial 粗体", "Arial-BoldMT"),
            ("Verdana", "Verdana"),
            ("Trebuchet MS", "TrebuchetMS"),
            ("Optima", "Optima-Regular"),
            ("Gill Sans", "GillSans"),
            ("Futura", "Futura-Medium"),
            // 西文衬线
            ("Times New Roman", "TimesNewRomanPSMT"),
            ("Georgia", "Georgia"),
            ("Palatino", "Palatino-Roman"),
            ("Baskerville", "Baskerville"),
            ("Didot", "Didot"),
            ("Copperplate", "Copperplate"),
            ("American Typewriter", "AmericanTypewriter"),
            // 等宽
            ("Menlo", "Menlo-Regular"),
            ("Monaco", "Monaco"),
            ("Courier New", "CourierNewPSMT"),
            // 手写/装饰
            ("Marker Felt", "MarkerFelt-Thin"),
            ("Snell Roundhand", "SnellRoundhand"),
            ("Zapfino", "Zapfino"),
        ]
    }

    private var currentFontName: String {
        AppDelegate.current?.barFontNameValue ?? ""
    }

    private var currentFontSize: CGFloat {
        AppDelegate.current?.barFontSizeValue ?? 13
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 10)
            List {
                Section("运行方式") {
                    HStack(spacing: 6) {
                        Image(systemName: "power.circle")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("当前：\(model.runMode)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    commandRow("单次运行（本次启动，不开机自启）",
                               "brew services run soda-lyrics")
                    commandRow("开机自启（登录自动运行，崩溃自动拉起）",
                               "brew services start soda-lyrics")
                    Text("停止：brew services stop soda-lyrics · 状态：brew services info soda-lyrics")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }

                Section("状态栏") {
                    HStack(spacing: 10) {
                        Text("歌词宽度")
                            .font(.system(size: 13))
                            .font(.system(size: 13))
                        Slider(value: Binding(
                            get: { model.draggingWidth ?? currentBarWidth },
                            set: { model.draggingWidth = $0 }   // 拖动中仅预览，不触碰 statusItem
                        ), in: 140...440, step: 10,
                        onEditingChanged: { editing in
                            if editing {
                                model.draggingWidth = currentBarWidth
                            } else if let w = model.draggingWidth {
                                // 拖完一次性应用：避免 statusItem 宽度连续变化带动 popover 重定位
                                AppDelegate.current?.setBarWidth(w)
                                model.draggingWidth = nil
                            }
                        })
                        Text("\(Int(model.draggingWidth ?? currentBarWidth)) pt")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }

                    Picker("歌词字体", selection: Binding(
                        get: { currentFontName },
                        set: { name in
                            AppDelegate.current?.setBarFont(name: name, size: currentFontSize)
                        }
                    )) {
                        ForEach(fontChoices, id: \.1) { choice in
                            Text(choice.0).tag(choice.1)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 13))

                    HStack(spacing: 10) {
                        Text("字号")
                            .font(.system(size: 13))
                        Slider(value: Binding(
                            get: { currentFontSize },
                            set: { size in
                                // 字号不触碰 statusItem 宽度，实时应用安全（无 popover 位移）
                                AppDelegate.current?.setBarFont(name: currentFontName ?? "", size: size)
                            }
                        ), in: 10...15, step: 1)
                        Text("\(Int(currentFontSize))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }

                    // 字体颜色（预设色板；与彩虹二选一）
                    HStack(spacing: 6) {
                        ForEach(colorPresets, id: \.0) { preset in
                            Button {
                                applyColorPreset(preset.1)
                            } label: {
                                colorSwatch(preset.1, selected: isColorSelected(preset.1))
                            }
                            .buttonStyle(.plain)
                            .help(preset.0)
                            .disabled(rainbowOn)
                        }
                    }
                    Text(rainbowOn ? "彩虹渐变开启中，颜色不可用（二选一）" : "歌词颜色（选色会自动关闭彩虹）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    Toggle(isOn: Binding(
                        get: { rainbowOn },
                        set: { on in
                            AppDelegate.current?.setRainbowMode(on)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("彩虹渐变").font(.system(size: 13))
                            Text("状态栏歌词按字符色相渐变（默认关闭）")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }

                Section("启动与更新") {
                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "sodaAutoUpdate") },
                        set: { UserDefaults.standard.set($0, forKey: "sodaAutoUpdate") }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动更新").font(.system(size: 13))
                            Text("启动时静默检查 GitHub 新版本")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)

                    HStack {
                        Text("当前版本 \(AppInfo.version)")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button(checkButtonTitle) {
                            checkForUpdates()
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.checkState == .checking || model.updating)
                    }
                    updateHint
                    if case .found = model.checkState {
                        Text("brew upgrade zephyr-cheung/tap/soda-lyrics")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("立即更新（brew upgrade + 重启服务）") {
                            applyUpdate()
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(model.updating)
                    }
                }

                Section("关于") {
                    linkRow("开源地址", AppInfo.repo, system: "link")
                    linkRow("作者", AppInfo.author, system: "person.crop.circle")
                    HStack(spacing: 8) {
                        Text("MIT License").font(.system(size: 13))
                        Spacer()
                        Button("查看") { openURL(AppInfo.repo + "/blob/main/LICENSE") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Text("© 2026 zephyr-cheung")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text("苏打歌词")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text("汽水音乐 & Apple Music 状态栏歌词")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }

                Section {
                    Button(role: .destructive) {
                        quitApp()
                    } label: {
                        HStack {
                            Image(systemName: "power").font(.system(size: 12))
                            Text("退出软件")
                        }
                    }
                    .controlSize(.small)
                }
            }
            .listStyle(.inset)
        }
        .padding(12)
        .frame(width: 360, height: 420)
        .onAppear {
            DispatchQueue.global().async { [self] in
                let info = detectRunMode()
                DispatchQueue.main.async { model.runMode = info }
            }
        }
    }

    /// 检测当前运行方式：开机自启的判定依据是 plist 是否写入用户 LaunchAgents
    /// （只有 `brew services start` 会写；`run` 仅用 opt 模板加载一次，不注册自启）
    private func detectRunMode() -> String {
        let agentPlist = NSString(string: "~/Library/LaunchAgents/homebrew.mxcl.soda-lyrics.plist").expandingTildeInPath
        if FileManager.default.fileExists(atPath: agentPlist) {
            return "开机自启运行中（brew 服务，登录自动启动）"
        }
        if isServiceManaged {
            return "单次运行中（brew services run，未注册开机自启）"
        }
        return "单次运行中（未注册开机自启）"
    }

    /// 命令 + 复制按钮
    private func commandRow(_ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    copyText(command)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    private func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text("设置")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("返回") { onClose() }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    @ViewBuilder
    private var updateHint: some View {
        switch model.checkState {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在检查…").font(.system(size: 11)).foregroundStyle(.secondary) }
        case .upToDate:
            Text("已是最新版本").font(.system(size: 11)).foregroundStyle(.secondary)
        case .found(let v):
            Text("发现新版本 \(v)").font(.system(size: 11)).foregroundStyle(.orange)
        case .failed(let msg):
            Text(msg).font(.system(size: 11)).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private var checkButtonTitle: String {
        switch model.checkState {
        case .found: return "重新检查"
        default: return "检查更新"
        }
    }

    private func linkRow(_ title: String, _ url: String, system: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: system).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13))
            Spacer()
            Button("打开") { openURL(url) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    // MARK: - 退出软件

    /// 是否由 launchd（brew services）托管运行——被托管时退出后 KeepAlive 会立即拉回
    private var isServiceManaged: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.contains("soda-lyrics") == true
    }

    /// 退出软件：服务托管时先停服务再退出（防 KeepAlive 拉回）
    private func quitApp() {
        let exit = { NSApplication.shared.terminate(nil) }
        if isServiceManaged {
            DispatchQueue.global().async { [self] in
                if let brew = brewPath {
                    _ = runOutput(brew, ["services", "stop", "soda-lyrics"])
                }
                Thread.sleep(forTimeInterval: 1.0)   // 等待 launchd 卸载完成
                DispatchQueue.main.async { exit() }
            }
        } else {
            exit()
        }
    }

    // MARK: - 工具

    private var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func runOutput(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            // 先消费管道再等退出（防管道缓冲死锁，同 cleanupOrphanProcesses）
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            for _ in 0..<120 {
                if !p.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    // MARK: - 更新检测与更新

    private func checkForUpdates() {
        model.checkState = .checking
        Self.fetchLatestVersion { tag in
            DispatchQueue.main.async {
                guard let tag else {
                    model.checkState = .failed("网络或接口异常（大陆网络可尝试开启代理后重试）")
                    return
                }
                model.checkState = versionNewer(tag, than: AppInfo.version) ? .found(tag) : .upToDate
            }
        }
    }

    /// 多源获取最新版本（大陆网络兼容）：
    /// 1) GitHub Releases API（配自动代理探测）
    /// 2) jsDelivr CDN 拉取仓库根 VERSION 文件（大陆可达性好）
    static func fetchLatestVersion(_ completion: @escaping (String?) -> Void) {
        let session = URLSession(configuration: updateURLSessionConfiguration())
        let sources: [(URL, (String) -> String?)] = [
            (URL(string: "https://api.github.com/repos/zephyr-cheung/soda-lyrics-mac/releases/latest")!, { raw in
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                      let tag = obj["tag_name"] as? String else { return nil }
                return tag
            }),
            (URL(string: "https://cdn.jsdelivr.net/gh/zephyr-cheung/soda-lyrics-mac@main/VERSION")!, { raw in
                let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }),
        ]
        var index = 0
        func tryNext() {
            guard index < sources.count else { completion(nil); return }
            let (url, parse) = sources[index]
            index += 1
            var req = URLRequest(url: url)
            req.setValue("SodaLyrics/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 12
            session.dataTask(with: req) { data, _, _ in
                guard let data, let raw = String(data: data, encoding: .utf8), let tag = parse(raw) else {
                    tryNext()
                    return
                }
                completion(tag)
            }.resume()
        }
        tryNext()
    }

    private func versionNewer(_ tag: String, than current: String) -> Bool {
        let a = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .components(separatedBy: ".").compactMap(Int.init)
        let b = current.components(separatedBy: ".").compactMap(Int.init)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 立即更新：brew upgrade + 重启服务（无 brew 时打开 releases 页人工更新）
    private func applyUpdate() {
        guard let brew = brewPath else {
            openURL(AppInfo.repo + "/releases/latest")
            return
        }
        model.updating = true
        DispatchQueue.global().async { [self] in
            _ = runOutput(brew, ["upgrade", "zephyr-cheung/tap/soda-lyrics"])
            _ = runOutput(brew, ["services", "restart", "soda-lyrics"])
            DispatchQueue.main.async {
                model.updating = false
                model.checkState = .upToDate
            }
        }
    }
}

/// URLSession 代理自动检测（环境变量 → 系统代理 → 直连）：
/// URLSession 默认只走「系统网络偏好」代理，不读 https_proxy 等环境变量；
/// 墙内直连 GitHub API 会失败，这里自动补上两种代理来源。
func updateURLSessionConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 12
    if let proxy = detectProxyDictionary() {
        config.connectionProxyDictionary = proxy
    }
    return config
}

/// 代理字典：1) 环境变量 https_proxy/http_proxy/all_proxy（http/socks5）
///           2) 系统代理（scutil --proxy）
func detectProxyDictionary() -> [AnyHashable: Any]? {
    let env = ProcessInfo.processInfo.environment
    var envProxy: (host: String, port: Int, socks: Bool)?
    for key in ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"] {
        guard let raw = env[key], !raw.isEmpty else { continue }
        var v = raw.trimmingCharacters(in: .whitespaces)
        let lower = v.lowercased()
        let isSocks = lower.hasPrefix("socks5://") || lower.hasPrefix("socks://")
        if let scheme = v.range(of: "://") {
            v = String(v[scheme.upperBound...])
        }
        guard let colon = v.lastIndex(of: ":") else { continue }
        let host = String(v[..<colon])
        guard let port = Int(v[v.index(after: colon)...]), !host.isEmpty else { continue }
        envProxy = (host, port, isSocks)
        break
    }
    var dict: [AnyHashable: Any] = [:]
    if let (host, port, socks) = envProxy {
        if socks {
            dict[kCFNetworkProxiesSOCKSEnable] = 1
            dict[kCFNetworkProxiesSOCKSProxy] = host
            dict[kCFNetworkProxiesSOCKSPort] = port
        } else {
            dict[kCFNetworkProxiesHTTPEnable] = 1
            dict[kCFNetworkProxiesHTTPProxy] = host
            dict[kCFNetworkProxiesHTTPPort] = port
            dict[kCFNetworkProxiesHTTPSEnable] = 1
            dict[kCFNetworkProxiesHTTPSProxy] = host
            dict[kCFNetworkProxiesHTTPSPort] = port
        }
        return dict
    }
    // 系统代理（scutil --proxy）
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
    p.arguments = ["--proxy"]
    let pipe = Pipe(); p.standardOutput = pipe
    do {
        try p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var host: String?; var port: Int?
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "HTTPSProxy" || key == "HTTPProxy" { host = val }
            if key == "HTTPSPort" || key == "HTTPPort" { port = Int(val) }
        }
        if let host, let port {
            dict[kCFNetworkProxiesHTTPEnable] = 1
            dict[kCFNetworkProxiesHTTPProxy] = host
            dict[kCFNetworkProxiesHTTPPort] = port
            dict[kCFNetworkProxiesHTTPSEnable] = 1
            dict[kCFNetworkProxiesHTTPSProxy] = host
            dict[kCFNetworkProxiesHTTPSPort] = port
            return dict
        }
    } catch {}
    return nil
}

/// 启动时静默更新检查（自动更新开关开启时调用；有新版则日志提示，不打扰）
func AutoUpdateCheckOnLaunch() {
    guard UserDefaults.standard.bool(forKey: "sodaAutoUpdate") else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        SettingsView.fetchLatestVersion { tag in
            guard let tag else { return }
            let a = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .components(separatedBy: ".").compactMap(Int.init)
            let b = AppInfo.version.components(separatedBy: ".").compactMap(Int.init)
            var newer = false
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : 0
                let y = i < b.count ? b[i] : 0
                if x != y { newer = x > y; break }
            }
            if newer {
                DispatchQueue.main.async {
                    NowPlayingStore.log("auto-update: 发现新版本 \(tag)")
                }
            }
        }
    }
}