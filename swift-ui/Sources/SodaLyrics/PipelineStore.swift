import Foundation
import SwiftUI

/// 数据管道：spawn Rust core（soda-lyrics 二进制），读 JSONL 行驱动 UI
@MainActor
public final class NowPlayingStore: ObservableObject {
    public enum Status { case idle, loading, ok, noResult, noPermission, appMissing, error }

    @Published public var now = NowPlaying(title: "", artist: "", positionMs: 0, durationMs: 0, isPlaying: false)
    /// 当前进度（snap 时同步赋值，@Published 保证 UI 重绘）
    @Published public var displayPos: Double = 0
    @Published public var lines: [LyricLine] = []
    @Published public var lyricCredit = ""
    @Published public var status: Status = .idle
    /// 歌词搜索候选（手动切换歌词源）
    @Published public var candidates: [LyricCandidate] = []
    /// 当前歌词来自哪个候选（core 在 lyrics 消息中回带）
    @Published public var selectedTrackId: String?
    /// 当前曲目封面图 URL（歌词采用曲目的封面；candidates 预载兜底）
    @Published public var coverURL: String?

    private var proc: Process?
    private var stdinPipe: Pipe?
    private var buf = ""
    private var lastTitle = ""
    private var snapCount = 0
    private var receivedAt = Date()
    private var lastPos: Double = 0
    private var lastDur: Double = 0
    private var lastPlaying = false

    public init() {}

    /// 实时进度：完全信任 Rust core 的 100ms 帧推进（避免二次叠加跳变）
    public var displayPositionMs: Double { displayPos }

    public var currentIndex: Int? { LyricParser.currentLineIndex(lines, positionMs: displayPositionMs) }

    /// 菜单栏显示文本：当前歌词行优先，其次加载态提示，其次歌名
    public var barText: String {
        if let idx = currentIndex, idx < lines.count { return lines[idx].text }
        // 切歌/启动的歌词获取期：明确显示加载过渡，避免「上一首第一句」残留观感
        if status == .loading { return "加载歌词…" }
        if !now.title.isEmpty { return now.title }
        switch status {
        case .appMissing: return "汽水音乐未运行"
        case .noResult, .error: return "未找到歌词"
        default: return "汽水歌词"
        }
    }

    public func start() {
        guard proc == nil else { return }
        guard let bin = locateCore() else {
            status = .appMissing
            Self.log("core binary not found")
            return
        }
        let p = Process()
        p.executableURL = bin
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // stdin 指令通道（core 侧有读取线程）
        let inPipe = Pipe()
        p.standardInput = inPipe
        stdinPipe = inPipe
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.procEnded() }
        }
        do {
            try p.run()
        } catch {
            status = .appMissing
            Self.log("spawn core failed: " + String(describing: error))
            return
        }
        // 若已有旧实例先停
        proc = p
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in self.consume(text) }
        }
        Self.log("core spawned")
    }

    public func stop() {
        proc?.terminate()
        proc = nil
        stdinPipe = nil
    }

    /// 手动切换歌词源到指定候选（写 stdin 指令，core 负责拉取并回发歌词）
    public func pickCandidate(_ id: String) {
        sendCommand(["t": "pick", "id": id])
    }

    /// 重新搜索当前歌曲（清手动选择，走自动流程）
    public func refresh() {
        candidates = []
        selectedTrackId = nil
        sendCommand(["t": "refresh"])
    }

    /// 当前歌词源显示文案：手动选中候选优先，其次自动匹配 credit
    public var selectedCandidateLabel: String {
        if let sid = selectedTrackId,
           let c = candidates.first(where: { $0.id == sid }) {
            return "\(c.title) · \(c.artist)"
        }
        return lyricCredit.isEmpty ? "自动匹配" : lyricCredit
    }

    private func sendCommand(_ obj: [String: String]) {
        guard let pipe = stdinPipe,
              let data = (try? JSONSerialization.data(withJSONObject: obj)).flatMap({ $0 + "\n".data(using: .utf8)! }) else { return }
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            Self.log("stdin write failed: " + String(describing: error))
        }
    }

    /// 面板/进度条 0.1s 刷新驱动
    public func pulse() { objectWillChange.send() }

    private func procEnded() {
        proc = nil
        status = .appMissing
    }

    /// 定位 Rust core 二进制（相对定位，不依赖绝对路径）：
    /// 1) bundle Resources 下的 soda-core（打包分发；不找 soda-lyrics——
    ///    裸二进制开发场景下 resourceURL 即可执行文件目录，该名会命中程序自身导致自 spawn）
    /// 2) 沿可执行文件逐级向上找 <root>/target/release/soda-lyrics（开发目录）
    /// 3) cwd 兜底：<cwd>/target/release/soda-lyrics
    private func locateCore() -> URL? {
        var candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("soda-core"),
        ]
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        // 注意：URL.deletingLastPathComponent() 对根路径 "/" 返回自身（自引用），必须显式终止
        while let d = dir, !d.path.isEmpty, d.path != "/" {
            candidates.append(d.appendingPathComponent("target/release/soda-lyrics"))
            dir = d.deletingLastPathComponent()
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("target/release/soda-lyrics")
        )
        for c in candidates {
            if let c, FileManager.default.isExecutableFile(atPath: c.path) {
                return c
            }
        }
        return nil
    }

    // MARK: - 管道解析

    private func consume(_ chunk: String) {
        buf += chunk
        var parts = buf.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.count > 1 { buf = String(parts.popLast() ?? "") } else { return }
        for line in parts { handle(String(line)) }
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["t"] as? String else { return }
        switch type {
        case "snap":
            snapCount += 1
            if snapCount % 30 == 0 {
                Self.log("snap pos=" + String(obj["pos"] as? Double ?? -1) + " title=" + String(obj["title"] as? String ?? ""))
            }
            let title = obj["title"] as? String ?? ""
            let artist = obj["artist"] as? String ?? ""
            let pos = obj["pos"] as? Double ?? 0
            let dur = obj["dur"] as? Double ?? 0
            let playing = obj["playing"] as? Bool ?? false
            // core 侧位置回退检测到的切歌（此时 title 可能还是旧歌，MediaRemote 滞后）：
            // 立即清空歌词进加载态，避免旧歌词残留到新歌词就绪
            let trackEvent = (obj["track"] as? Bool) ?? false
            if trackEvent || (!title.isEmpty && title != lastTitle) {
                lastTitle = title
                lines = []
                lyricCredit = ""
                coverURL = nil
                status = .loading
            }
            lastPos = pos
            lastDur = dur
            lastPlaying = playing
            receivedAt = Date()
            displayPos = pos
            now = NowPlaying(title: title, artist: artist, positionMs: pos, durationMs: dur, isPlaying: playing)
            if title.isEmpty { status = .idle }
        case "candidates":
            // 候选列表（自动搜索流程发）；title 与当前歌曲不一致视为过期丢弃
            if let msgTitle = obj["title"] as? String, msgTitle != lastTitle { break }
            var cands: [LyricCandidate] = []
            if let arr = obj["items"] as? [[String: Any]] {
                for it in arr {
                    cands.append(LyricCandidate(
                        id: it["id"] as? String ?? "",
                        title: it["title"] as? String ?? "",
                        artist: it["artist"] as? String ?? "",
                        durationMs: Int(it["dur"] as? Double ?? 0),
                        coverUrl: it["cover"] as? String ?? ""
                    ))
                }
            }
            candidates = cands
            // 歌词仍未确定时先用第一个候选的封面预载（lyrics 消息到达后以采用曲目为准）
            if coverURL == nil, let first = cands.first(where: { !$0.coverUrl.isEmpty }) {
                coverURL = first.coverUrl
            }
            Self.log("candidates applied: \(cands.count)")
        case "lyrics":
            let credit = obj["credit"] as? String ?? ""
            if let tid = obj["track_id"] as? String, !tid.isEmpty {
                selectedTrackId = tid
            }
            let fail = obj["fail"] as? String ?? "none"
            if let c = obj["cover"] as? String, !c.isEmpty {
                coverURL = c
            }
            var parsed: [LyricLine] = []
            if let arr = obj["lines"] as? [[String: Any]] {
                for it in arr {
                    let s = Int(it["s"] as? Double ?? 0)
                    let e = Int(it["e"] as? Double ?? 0)
                    let t = it["t"] as? String ?? ""
                    var words: [Word] = []
                    if let ws = it["w"] as? [[String: Any]] {
                        for w in ws {
                            words.append(Word(
                                offsetMs: Int(w["o"] as? Double ?? 0),
                                durMs: Int(w["d"] as? Double ?? 0),
                                text: w["t"] as? String ?? ""
                            ))
                        }
                    }
                    parsed.append(LyricLine(startMs: s, endMs: e, text: t, words: words))
                }
            }
            lines = parsed
            lyricCredit = credit
            // fail 区分「没找到歌词」与「接口/网络错误」，UI 文案不同
            status = parsed.isEmpty ? (fail == "error" ? .error : .noResult) : .ok
            Self.log("lyrics applied: \(parsed.count) lines fail=\(fail)")
        default:
            break
        }
    }

    /// 调试日志（/tmp/soda-lyrics-swift.log）
    public static func log(_ s: String) {
        let line = Date().formatted(.iso8601) + " " + s + "\n"
        if let d = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/soda-lyrics-swift.log")) {
                h.seekToEndOfFile()
                h.write(d)
                try? h.close()
            } else {
                try? d.write(to: URL(fileURLWithPath: "/tmp/soda-lyrics-swift.log"))
            }
        }
    }
}