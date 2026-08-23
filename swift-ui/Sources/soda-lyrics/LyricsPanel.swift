import SwiftUI
import AppKit
import SodaLyrics

/// 歌词字符单元（词内均分词时长；含词间空格）
private struct CharUnit {
    let ch: Character
    let startMs: Int
    let durMs: Int
}

/// 展开 words → 字符序列（词间空格：CJK 相邻不加空格，与 Rust join_words 一致）
private func buildCharUnits(_ line: LyricLine) -> [CharUnit] {
    var out: [CharUnit] = []
    for (wi, w) in line.words.enumerated() {
        if wi > 0 {
            let prevLast = line.words[wi - 1].text.last ?? " "
            let curFirst = w.text.first ?? " "
            let bothCJK = (prevLast.unicodeScalars.first?.properties.isIdeographic ?? false)
                && (curFirst.unicodeScalars.first?.properties.isIdeographic ?? false)
            if !bothCJK { out.append(CharUnit(ch: " ", startMs: w.offsetMs, durMs: 0)) }
        }
        let chars = Array(w.text)
        let per = max(1, w.durMs / max(1, chars.count))
        for (ci, ch) in chars.enumerated() {
            out.append(CharUnit(ch: ch, startMs: w.offsetMs + ci * per, durMs: per))
        }
    }
    return out
}

struct LyricsPanel: View {
    @ObservedObject var store: NowPlayingStore
    /// 帧级进度源（仅透传：订阅发生在 ProgressBarView/TickerRow 内部，
    /// 面板 body 不随 25fps 重算——否则 header/歌词区每帧重建）
    let ticker: ProgressTicker

    /// 面板 UI 状态（设置页切换；@State 宏在部分 toolchain 不可用，用 ObservableObject）
    /// 共享单例：避免 @ObservedObject 默认值在 body 重建时重置（见 SettingsView.Model 注释）
    final class PanelUI: ObservableObject {
        static let shared = PanelUI()
        @Published var showSettings = false
    }

    @ObservedObject private var ui = PanelUI.shared

    var body: some View {
        if ui.showSettings {
            SettingsView(onClose: { ui.showSettings = false })
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().padding(.vertical, 8)
                lyricArea
            }
            .padding(12)
            .frame(width: 360, height: 420)
            .onAppear { store.start() }
            // 30fps 帧级刷新由 AppDelegate 按 popover 可见性驱动（ticker.positionMs）
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            coverArt
            VStack(alignment: .leading, spacing: 6) {
                Text(store.now.title.isEmpty ? "苏打歌词" : store.now.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(store.now.artist.isEmpty ? (store.lyricCredit.isEmpty ? "正在监听汽水音乐…" : store.lyricCredit) : store.now.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if store.now.durationMs > 0 {
                    ProgressBarView(totalMs: store.now.durationMs, ticker: ticker)
                }
                if !(store.candidates.isEmpty && store.lyricCredit.isEmpty && store.status != .error && store.status != .noResult) {
                    sourceRow
                }
            }
            Spacer(minLength: 0)
            Button {
                ui.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置")
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
            hint("未检测到播放器", detail: "请先打开并播放 汽水音乐 或 Apple Music")
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
                hint("等待播放…", detail: "在汽水音乐或 Apple Music 中播放歌曲后，这里会显示滚动歌词")
            } else {
                LyricListView(lines: store.lines, currentIndex: store.currentIndex, ticker: ticker)
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

/// 进度条：独立子视图——只在它内帧级重算（ticker），面板其余部分不失效
private struct ProgressBarView: View {
    let totalMs: Double
    @ObservedObject var ticker: ProgressTicker

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(max(0, ticker.positionMs)), total: totalMs)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
            Text(formatClock(ticker.positionMs) + " / " + formatClock(totalMs))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

/// 歌词列表：只依赖低频数据（lines / currentIndex），ticker 仅透传——
/// 30fps 进度刷新不会 invalidate 本列表（只有换行/歌词加载时才重算）
private struct LyricListView: View {
    let lines: [LyricLine]
    let currentIndex: Int?
    let ticker: ProgressTicker

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        rowView(line, index: idx)
                    }
                }
                .padding(.vertical, 160)
            }
            .onChange(of: currentIndex) { idx in
                if let idx {
                    // spring 跟手且不抖动（easeInOut 在快速换行时动画反复重启会发涩）
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ line: LyricLine, index: Int) -> some View {
        if index == currentIndex {
            TickerRow(ticker: ticker, line: line)
                .id(index)
        } else {
            StaticLyricRow(text: line.text)
                .id(index)
        }
    }
}

/// 非当前行：静态整行文本（仅依赖 text，不订阅任何帧级数据）
private struct StaticLyricRow: View, Equatable {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
    }
}

/// 当前行：订阅 ticker 的专用视图——ticker 每帧变化只 invalidate 本行
private struct TickerRow: View {
    @ObservedObject var ticker: ProgressTicker
    let line: LyricLine

    var body: some View {
        CurrentLineView(line: line, relMs: Int(ticker.positionMs) - line.startMs)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
    }
}

/// 当前行的「段式」渲染：同一行内按状态（已唱/正在唱/未唱）合并为段，
/// 每段一个 Text（正在唱段为单字符 mask 填充）——子视图数从「逐字符 40~60 个」
/// 降到「每行 3 个」，SwiftUI 布局与 GPU 层数大幅下降
private struct CurrentLineView: View {
    let line: LyricLine
    let relMs: Int

    /// 行内段：state 0=未唱 1=已唱完 2=正在唱（单字符）
    private struct Segment {
        let text: String
        let state: Int
        let progress: Double   // state==2 时字符内进度
    }

    private var bodyFont: NSFont { NSFont.systemFont(ofSize: 16, weight: .semibold) }

    var body: some View {
        let units = buildCharUnits(line)
        // 行级歌词（无词级时间戳）：整行高亮，不做逐字卡拉OK扫描
        if units.isEmpty {
            return AnyView(
                Text(line.text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            )
        }
        let segs = buildSegments(units)
        if segs.isEmpty {
            return AnyView(
                Text(line.text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            )
        }
        return AnyView(
            CharFlowLayout {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                    if s.state == 2, let ch = s.text.first {
                        CurrentCharText(ch: ch, progress: s.progress)
                    } else if s.state == 1 {
                        Text(s.text).foregroundStyle(.primary)
                    } else {
                        Text(s.text)   // 继承 .secondary 底色
                    }
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
        )
    }

    /// 行号计算 + 分段：与 CharFlowLayout 同源测量（同字体宽度），按行不跨段
    private func buildSegments(_ units: [CharUnit]) -> [Segment] {
        let width: CGFloat = 312   // 面板 360 - 左右 padding 24 - 行 padding 24
        let attrs: [NSAttributedString.Key: Any] = [.font: bodyFont]
        // 状态 + 行号
        var states: [Int] = []
        var rows: [Int] = []
        var x: CGFloat = 0
        var row = 0
        for u in units {
            let end = u.startMs + u.durMs
            let st: Int = relMs >= end ? 1 : (relMs >= u.startMs && u.durMs > 0 ? 2 : 0)
            states.append(st)
            let w = (String(u.ch) as NSString).size(withAttributes: attrs).width
            if x + w > width, x > 0 { row += 1; x = 0 }
            rows.append(row)
            x += w
        }
        // 连续 (行,状态) 合并为段
        var segs: [Segment] = []
        var start = 0
        for i in 1..<units.count {
            if rows[i] != rows[start] || states[i] != states[start] {
                segs.append(makeSegment(units, start, i - 1, states[start]))
                start = i
            }
        }
        segs.append(makeSegment(units, start, units.count - 1, states[start]))
        return segs
    }

    private func makeSegment(_ units: [CharUnit], _ lo: Int, _ hi: Int, _ state: Int) -> Segment {
        if state == 2 {
            let u = units[lo]
            let p = min(1.0, max(0.0, Double(relMs - u.startMs) / Double(max(1, u.durMs))))
            return Segment(text: String(u.ch), state: 2, progress: p)
        }
        var t = ""
        for i in lo...hi { t.append(units[i].ch) }
        return Segment(text: t, state: state, progress: 0)
    }
}

/// 正在唱的字符：基座未读色 + 上层已读色按字符内进度 mask 裁剪（两色硬切）
private struct CurrentCharText: View {
    let ch: Character
    let progress: Double

    var body: some View {
        Text(String(ch))
            .overlay {
                Text(String(ch))
                    .foregroundStyle(.primary)
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle()
                                .frame(width: geo.size.width * CGFloat(progress))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
            }
    }
}

/// 段流布局：按可用宽度自动换行（行为居中），每个子视图为一段文本
struct CharFlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 312
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 {
                x = 0
                y += rowH
                rowH = 0
            }
            x += s.width
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        // 第一遍：分行（子索引 + 宽度）
        var rows: [[(idx: Int, w: CGFloat)]] = []
        var cur: [(idx: Int, w: CGFloat)] = []
        var x: CGFloat = 0
        for (i, sv) in subviews.enumerated() {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > width, !cur.isEmpty {
                rows.append(cur)
                cur = []
                x = 0
            }
            cur.append((i, s.width))
            x += s.width
        }
        if !cur.isEmpty { rows.append(cur) }
        // 第二遍：行居中放置
        var y = bounds.minY
        for row in rows {
            let rowW = row.reduce(0) { $0 + $1.w }
            var xx = bounds.minX + max(0, (width - rowW) / 2)
            var rowH: CGFloat = 0
            for (i, w) in row {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: xx, y: y), proposal: ProposedViewSize(s))
                xx += w
                rowH = max(rowH, s.height)
            }
            y += rowH
        }
    }
}