import SwiftUI
import AppKit
import SodaLyrics

/// 应用信息（当前版本：发版时同步）
enum AppInfo {
    static let version = "0.3.1"
    static let repo = "https://github.com/zephyr-cheung/soda-lyrics-mac"
    static let author = "https://github.com/zephyr-cheung"
}

/// 设置面板（展开面板内切换视图）：开机自启 / 更新检测与自动更新 / 开源与作者信息 / MIT
struct SettingsView: View {
    let onClose: () -> Void

    /// 状态模型（避免 @State 宏依赖，兼容构建工具链）
    /// 必须用共享单例：SwiftUI 在每次 body 重建时会重新求值 @ObservedObject 默认值，
    /// 若每次 new 实例，任何状态变化都会在下一次重建时被重置（表现为点击无反应）
    final class Model: ObservableObject {
        static let shared = Model()
        @Published var autoLaunch = false
        @Published var checkState: Check = .idle
        @Published var updating = false
        enum Check: Equatable { case idle, checking, upToDate, found(String), failed(String) }
    }

    @ObservedObject private var model = Model.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 10)
            List {
                Section("启动与更新") {
                    Toggle(isOn: Binding(
                        get: { model.autoLaunch },
                        set: { enable in
                            // 乐观更新：立即切换开关外观，后台执行后以真实状态校准
                            model.autoLaunch = enable
                            applyAutoLaunch(enable)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自启").font(.system(size: 13))
                            Text("登录时自动启动（brew services / LaunchAgent）")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)

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
            // 异步查询自启状态（brew services list 同步会阻塞面板弹出）
            DispatchQueue.global().async {
                let active = self.isAutoLaunchActive()
                DispatchQueue.main.async {
                    self.model.autoLaunch = active
                }
            }
        }
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

    /// 退出软件：若由 brew services 托管（KeepAlive 会在退出后立即拉回），先停服务再退出
    private func quitApp() {
        let exit = { NSApplication.shared.terminate(nil) }
        if isAutoLaunchActive() {
            DispatchQueue.global().async {
                self.applyAutoLaunchSync(false)
                Thread.sleep(forTimeInterval: 1.0)   // 等待 launchd 卸载完成
                DispatchQueue.main.async { exit() }
            }
        } else {
            exit()
        }
    }

    // MARK: - 开机自启

    private var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private var agentPlist: String {
        NSString(string: "~/Library/LaunchAgents/com.zephyr.sodalryrics.plist").expandingTildeInPath
    }

    /// 当前是否已注册开机自启（brew services started 或自管 plist 存在）
    private func isAutoLaunchActive() -> Bool {
        if let brew = brewPath,
           let out = runOutput(brew, ["services", "list"]),
           let line = out.split(separator: "\n").first(where: { $0.contains("soda-lyrics") }),
           line.contains("started") {
            return true
        }
        return FileManager.default.fileExists(atPath: agentPlist) || FileManager.default.fileExists(
            atPath: NSString(string: "~/Library/LaunchAgents/homebrew.mxcl.soda-lyrics.plist").expandingTildeInPath)
    }

    private func applyAutoLaunch(_ enable: Bool) {
        // 异步执行（brew services/launchctl 阻塞主线程会令 UI 无响应）
        DispatchQueue.global().async {
            self.applyAutoLaunchSync(enable)
            DispatchQueue.main.async {
                self.model.autoLaunch = self.isAutoLaunchActive()
            }
        }
    }

    private func applyAutoLaunchSync(_ enable: Bool) {
        if let brew = brewPath {
            _ = runTool(brew, ["services", enable ? "start" : "stop", "soda-lyrics"])
        } else if enable {
            // 自管 LaunchAgent（无 brew 环境兜底）
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>com.zephyr.sodalryrics</string>
            <key>ProgramArguments</key><array><string>\(Bundle.main.executablePath ?? "")</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            </dict></plist>
            """
            do {
                try plist.write(toFile: agentPlist, atomically: true, encoding: .utf8)
                _ = runTool("/bin/launchctl", ["load", "-w", agentPlist])
            } catch {}
        } else {
            if FileManager.default.fileExists(atPath: agentPlist) {
                _ = runTool("/bin/launchctl", ["unload", agentPlist])
                try? FileManager.default.removeItem(atPath: agentPlist)
            }
        }
        model.autoLaunch = isAutoLaunchActive()
    }

    private func runTool(_ tool: String, _ args: [String]) -> Bool {
        runOutput(tool, args) != nil
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
            // 超时保护（brew/launchctl 异常卡住时 12s 强制终止，避免阻塞 UI/后台线程）
            for _ in 0..<120 {
                if !p.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    // MARK: - 更新检测与更新

    private func checkForUpdates() {
        model.checkState = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/zephyr-cheung/soda-lyrics-mac/releases/latest")!)
        req.setValue("SodaLyrics/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: updateURLSessionConfiguration()).dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                guard let data, error == nil,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    model.checkState = .failed("网络或接口异常")
                    return
                }
                model.checkState = versionNewer(tag, than: AppInfo.version) ? .found(tag) : .upToDate
            }
        }.resume()
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
        DispatchQueue.global().async {
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
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/zephyr-cheung/soda-lyrics-mac/releases/latest")!)
        req.setValue("SodaLyrics/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: updateURLSessionConfiguration()).dataTask(with: req) { data, _, _ in
            guard let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
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
        }.resume()
    }
}