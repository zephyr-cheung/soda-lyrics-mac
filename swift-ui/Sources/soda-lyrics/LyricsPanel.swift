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
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in store.pulse() }
    }

    private var header: some View {
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
            VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.frame(maxWidth: .infinity)
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
                                 sungWord: idx == store.currentIndex ? LyricParser.currentWordIndex(line, positionMs: store.displayPositionMs) : nil)
                            .id(idx)
                    }
                }
                .padding(.vertical, 160)
            }
            .onChange(of: store.currentIndex) { idx in
                if let idx {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(idx, anchor: .center) }
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
        let sung = sungWord ?? (isCurrent ? Int.max : -1)
        for (wi, w) in line.words.enumerated() {
            if wi > 0 {
                let prevLast = line.words[wi - 1].text.last ?? " "
                let curFirst = w.text.first ?? " "
                let bothCJK = (prevLast.unicodeScalars.first?.properties.isIdeographic ?? false)
                    && (curFirst.unicodeScalars.first?.properties.isIdeographic ?? false)
                if !bothCJK { out += AttributedString(" ") }
            }
            var a = AttributedString(w.text)
            if isCurrent && wi <= sung { a.foregroundColor = .primary }
            out += a
        }
        return out
    }
}