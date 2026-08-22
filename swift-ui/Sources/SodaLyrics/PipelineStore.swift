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

    private var proc: Process?
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

    /// 菜单栏显示文本：当前歌词行优先，其次歌名
    public var barText: String {
        if let idx = currentIndex, idx < lines.count { return lines[idx].text }
        if !now.title.isEmpty { return now.title }
        switch status {
        case .appMissing: return "汽水音乐未运行"
        case .loading: return "加载歌词…"
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

    public func stop() { proc?.terminate(); proc = nil }

    /// 面板/进度条 0.1s 刷新驱动
    public func pulse() { objectWillChange.send() }

    private func procEnded() {
        proc = nil
        status = .appMissing
    }

    /// 定位 Rust core 二进制：bundle Resources 优先，其次开发目录
    private func locateCore() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("soda-core"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Project/soda-music-tui/soda-lyrics-mac/target/release/soda-lyrics"),
        ]
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
            if title != lastTitle, !title.isEmpty {
                lastTitle = title
                lines = []
                lyricCredit = ""
                status = .loading
            }
            lastPos = pos
            lastDur = dur
            lastPlaying = playing
            receivedAt = Date()
            displayPos = pos
            now = NowPlaying(title: title, artist: artist, positionMs: pos, durationMs: dur, isPlaying: playing)
            if title.isEmpty { status = .idle }
        case "lyrics":
            let credit = obj["credit"] as? String ?? ""
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
            status = parsed.isEmpty ? .noResult : .ok
            Self.log("lyrics applied: \(parsed.count) lines")
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