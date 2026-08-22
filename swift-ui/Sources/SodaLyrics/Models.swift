import Foundation

/// 词级歌词片段
public struct Word: Sendable {
    public let offsetMs: Int
    public let durMs: Int
    public let text: String
}

/// 句级歌词行
public struct LyricLine: Sendable {
    public let startMs: Int
    public let endMs: Int
    public let text: String
    public let words: [Word]
}

/// 正在播放快照（来自 Rust core 管道）
public struct NowPlaying: Sendable {
    public let title: String
    public let artist: String
    public let positionMs: Double
    public let durationMs: Double
    public let isPlaying: Bool
}

/// 歌词搜索候选（供面板手动切换歌词源）
public struct LyricCandidate: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let durationMs: Int
}

public func formatClock(_ ms: Double) -> String {
    let s = max(0, Int(ms) / 1000)
    return String(format: "%02d:%02d", s / 60, s % 60)
}

/// 歌词行定位与词级进度（Rust 已解析，这里做查询）
public enum LyricParser {
    /// 给定当前毫秒，返回所在句下标；间隙保持上一句
    public static func currentLineIndex(_ lines: [LyricLine], positionMs: Double) -> Int? {
        let pos = Int(positionMs)
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].startMs <= pos { lo = mid + 1 } else { hi = mid - 1 }
        }
        return hi >= 0 ? hi : nil
    }

    /// 当前词下标（卡拉OK高亮）
    public static func currentWordIndex(_ line: LyricLine, positionMs: Double) -> Int? {
        let rel = Int(positionMs) - line.startMs
        for (idx, w) in line.words.enumerated() where rel >= w.offsetMs && rel < w.offsetMs + w.durMs {
            return idx
        }
        return nil
    }
}
