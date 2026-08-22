import SwiftUI
import SodaLyrics

struct LyricsPanel: View {
    @ObservedObject var store: NowPlayingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            lyricArea
        }
        .padding(12)
        .frame(width: 360, height: 420)
        .onAppear { store.start() }
        // 30fps 刷新由 AppDelegate 按 popover 可见性驱动（store.pulse()）。
        // 不在 view 内挂 Timer：popover 关闭时也要重新布局，白白烧 CPU（AttributeGraph）
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            coverArt
            VStack(alignment: .leading, spacing: 6) {
                Text(store.now.title.isEmpty ? "汽水歌词助手" : store.now.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(store.now.artist.isEmpty ? (store.lyricCredit.isEmpty ? "正在监听汽水音乐…" : store.lyricCredit) : store.now.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if store.now.durationMs > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(max(0, store.displayPositionMs)), total: Double(store.now.durationMs))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: .infinity)
                        Text(formatClock(store.displayPositionMs) + " / " + formatClock(store.now.durationMs))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)

                    }
                }
                if !(store.candidates.isEmpty && store.lyricCredit.isEmpty && store.status != .error && store.status != .noResult) {
                    sourceRow
                }
            }
        }
    }

    /// 曲目封面：歌词采用曲目（或候选预载）的 cover_url；无封面时显示占位
    @ViewBuilder
    private var coverArt: some View {
        let box = RoundedRectangle(cornerRadius: 8)
        if let urlStr = store.coverURL, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    coverPlaceholder
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(box)
        } else {
            coverPlaceholder
        }
    }

    private var coverPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
            Image(systemName: "music.note")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 52, height: 52)
    }

    /// 歌词源行：候选 Menu（手动切换）+ 失败时的刷新按钮
    private var sourceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note.list")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if store.candidates.isEmpty {
                Text("歌词源：\(store.selectedCandidateLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Menu {
                    ForEach(store.candidates) { c in
                        Button {
                            store.pickCandidate(c.id)
                        } label: {
                            if c.id == store.selectedTrackId {
                                Label("\(c.title) · \(c.artist)（\(formatClock(Double(c.durationMs)))）", systemImage: "checkmark")
                            } else {
                                Text("\(c.title) · \(c.artist)（\(formatClock(Double(c.durationMs)))）")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("歌词源：\(store.selectedCandidateLabel)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    // 弹性占满可用宽度（不可用 fixedSize：会按理想尺寸撑开导致超宽）
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if store.status == .error || store.status == .noResult {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("重新搜索当前歌曲")
            }
        }
    }

    @ViewBuilder
    private var lyricArea: some View {
        switch store.status {
        case .noPermission:
            hint("需要辅助功能权限才能读取播放状态", detail: "打开 系统设置 → 隐私与安全性 → 辅助功能，勾选本 App")
        case .appMissing:
            hint("未检测到汽水音乐", detail: "请先打开 汽水音乐 App 并播放歌曲")
        case .noResult:
            hint("未找到这首歌的歌词", detail: store.now.title + " - " + store.now.artist)
        case .error:
            hint("歌词获取失败", detail: "请检查网络，或点右下角刷新按钮重新搜索")
        case .loading:
            VStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("加载歌词中…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        default:
            if store.lines.isEmpty {
                hint("等待播放…", detail: "在汽水音乐中播放歌曲后，这里会显示滚动歌词")
            } else {
                lyricList
            }
        }
    }

    private var lyricList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(store.lines.enumerated()), id: \.offset) { idx, line in
                        LyricRow(line: line, isCurrent: idx == store.currentIndex,
                                 sungWord: idx == store.currentIndex ? LyricParser.currentWordIndex(line, positionMs: store.displayPositionMs) : nil,
                                 positionMs: store.displayPositionMs)
                            .id(idx)
                    }
                }
                .padding(.vertical, 160)
            }
            .onChange(of: store.currentIndex) { idx in
                if let idx {
                    // spring 跟手且不抖动（easeInOut 在快速换行时动画反复重启会发涩）
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
    }

    private func hint(_ t: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(t).font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// 单行歌词（当前行词级卡拉OK染色）
struct LyricRow: View {
    let line: LyricLine
    let isCurrent: Bool
    let sungWord: Int?
    /// 当前播放进度（ms）：正在唱的词按词内时间进度逐字点亮，避免词级二值跳变
    let positionMs: Double

    var body: some View {
        Text(attributed)
            .font(.system(size: isCurrent ? 16 : 13, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        guard !line.words.isEmpty else {
            var a = AttributedString(line.text)
            if isCurrent { a.foregroundColor = .primary }
            return a
        }
        // sungWord=nil 只在「本行未开始或词未开始」时出现（词间间隙已由
        // LyricParser 返回「最后已开始的词」），此时不应点亮任何词——
        // 用 Int.max 兜底会把整句瞬间铺满（行开始瞬间、首词未启动的窗口常见）
        let sung = sungWord ?? -1
        let rel = Int(positionMs) - line.startMs
        for (wi, w) in line.words.enumerated() {
            if wi > 0 {
                let prevLast = line.words[wi - 1].text.last ?? " "
                let curFirst = w.text.first ?? " "
                let bothCJK = (prevLast.unicodeScalars.first?.properties.isIdeographic ?? false)
                    && (curFirst.unicodeScalars.first?.properties.isIdeographic ?? false)
                if !bothCJK { out += AttributedString(" ") }
            }
            if isCurrent && wi <= sung {
                let chars = Array(w.text)
                // 正在唱的词：词内按时间进度逐字点亮，字与字之间带淡入过渡
                // （硬切会在 30fps 下显得生硬；淡入让逐字推进连续流动）
                let wordActive = rel >= w.offsetMs && rel < w.offsetMs + w.durMs
                if wordActive && chars.count > 1 {
                    let wordProgress = Double(rel - w.offsetMs) / Double(max(1, w.durMs))
                    let charCount = Double(chars.count)
                    for (ci, ch) in chars.enumerated() {
                        let charStart = Double(ci) / charCount      // 字起点（词内比例）
                        let charEnd = Double(ci + 1) / charCount    // 字终点
                        // 淡入窗口：字周期的一小段（约 40~100ms），字到点前就开始渐亮
                        let fade = max(0.04, min(0.10, (charEnd - charStart) * 0.4))
                        let t = (wordProgress - (charStart - fade)) / fade
                        var a = AttributedString(String(ch))
                        if wordProgress >= charEnd {
                            a.foregroundColor = .primary              // 已唱完的字：稳定高亮
                        } else if t > 0 {
                            a.foregroundColor = .primary.opacity(min(1, t))  // 正在淡入
                        }
                        out += a
                    }
                } else {
                    var a = AttributedString(w.text)
                    a.foregroundColor = .primary
                    out += a
                }
            } else {
                out += AttributedString(w.text)
            }
        }
        return out
    }
}