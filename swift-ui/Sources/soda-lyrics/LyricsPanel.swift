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

/// 单行歌词（当前行字符级卡拉OK：字符内部按进度渐变填充，对标汽水客户端）
struct LyricRow: View {
    let line: LyricLine
    let isCurrent: Bool
    /// 当前播放进度（ms）：当前行按字符时间窗逐字点亮，正在唱的字符内部渐变填充
    let positionMs: Double

    /// 展开后的字符单元（含词间空格；字符时间 = 词内均分词时长）
    private struct CharUnit {
        let ch: Character
        let startMs: Int
        let durMs: Int
    }

    var body: some View {
        if isCurrent, !charUnits.isEmpty {
            // 当前行：逐字符布局（自动换行 + 行居中），字符内渐变填充
            CharFlowLayout {
                ForEach(Array(charUnits.enumerated()), id: \.offset) { _, u in
                    unitText(u)
                }
            }
            .font(.system(size: 16, weight: .semibold))
            // 未唱字符底色（已唱/正在唱由 unitText 各自覆盖）
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        } else {
            Text(line.text)
                .font(.system(size: isCurrent ? 16 : 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
        }
    }

    /// 字符文本：已唱完 = 全亮；正在唱 = 字符内「左已读/右未读」两色硬切填充；未唱 = 继承底色
    @ViewBuilder
    private func unitText(_ u: CharUnit) -> some View {
        if isCurrent {
            let rel = Int(positionMs) - line.startMs
            let end = u.startMs + u.durMs
            if rel >= end {
                Text(String(u.ch)).foregroundStyle(.primary)
            } else if rel >= u.startMs, u.durMs > 0 {
                // 字符内进度：用 mask 按宽度裁剪，避免 LinearGradient 的插值过渡带
                // （primary→secondary 相邻色标会渲染出可见的第三种混合色）
                let p = min(0.999, max(0, Double(rel - u.startMs) / Double(u.durMs)))
                Text(String(u.ch))  // 基座：未读色（继承环境 .secondary）
                    .overlay {
                        Text(String(u.ch))
                            .foregroundStyle(.primary)  // 已读色，仅左侧 p 部分可见
                            .mask(alignment: .leading) {
                                GeometryReader { geo in
                                    Rectangle()
                                        .frame(width: geo.size.width * CGFloat(p))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                    }
            } else {
                Text(String(u.ch))
            }
        }
    }

    /// 展开 words → 字符序列（词间空格：CJK 相邻不加空格，与 Rust join_words 一致）
    private var charUnits: [CharUnit] {
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
}

/// 字符流布局：按可用宽度自动换行（行为居中），每个子视图为一个字符
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