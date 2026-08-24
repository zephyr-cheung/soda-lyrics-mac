//! 状态合并：采集 -> 曲目识别 -> 歌词加载
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::Duration;

use crate::api;
use crate::lyrics::LyricLine;
use crate::media::{Collector, Snapshot};

/// 歌词 Provider：按播放器路由
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum Provider {
    /// 汽水音乐：volcengine 搜索 + 词级歌词
    #[default]
    Soda,
    /// Apple Music：iTunes Search + LRCLIB 行级歌词（行内均分降级词级）
    Apple,
}

/// 歌词加载请求（主线程 -> 加载线程）
#[derive(Debug, Clone, Default)]
pub struct LoadRequest {
    pub key: String,
    pub title: String,
    pub artist: String,
    /// 播放器上报的总时长（ms，用于时长匹配剔除不一致候选；0 = 未知不过滤）
    pub player_dur_ms: f64,
    /// 起作用的播放器（决定搜索/歌词接口）
    pub provider: Provider,
    /// 手动指定曲目（UI 候选切换）；None = 正常自动搜索流程
    pub manual: Option<crate::api::Track>,
    /// iTunes Store adam id（Apple 系；AMLL 词级歌词直查）
    pub adam_id: i64,
}

/// 歌词获取结果分类：none=成功 / noresult=搜到但全部无歌词 / error=接口或网络失败
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum FailKind {
    #[default]
    None,
    NoResult,
    Error,
}

/// 歌词加载结果（发送给主线程）
#[derive(Debug, Clone, Default)]
pub struct LyricsPayload {
    pub track_key: String,
    pub credit: String,
    pub lines: Vec<LyricLine>,
    pub ok: bool,
    pub fail: FailKind,
    /// 实际采用的 track id（UI 高亮当前歌词源）
    pub track_id: String,
    /// 实际采用曲目的封面图 URL（UI 面板左侧展示）
    pub cover_url: String,
    /// 自动搜索流程的候选列表（UI 手动切换数据源）；手动指定时为空
    pub candidates: Vec<crate::api::Track>,
}

/// UI 展示需要的合并状态（主线程持有）
#[derive(Debug, Clone, Default)]
pub struct UiState {
    pub title: String,
    pub artist: String,
    pub position_ms: f64,
    pub duration_ms: f64,
    pub playing: bool,
    pub lines: Vec<LyricLine>,
    pub credit: String,
    pub bar_text: String,
}

impl UiState {
    pub fn current_index(&self) -> Option<usize> {
        crate::lyrics::current_line_index(&self.lines, self.position_ms as i64)
    }
    pub fn current_word(&self, idx: usize) -> Option<usize> {
        self.lines.get(idx).and_then(|l| crate::lyrics::current_word_index(l, self.position_ms as i64))
    }
}

/// 采集线程：长驻 stream（200ms 行）+ 增量推进，100ms 向主循环推送快照
pub fn spawn_collector(stop: Receiver<()>) -> Receiver<Snapshot> {
    let (_child, stream_rx) = crate::media::spawn_stream_source(200);
    let (tx, rx) = channel::<Snapshot>();
    std::thread::spawn(move || {
        let mut c = Collector::new(stream_rx);
        loop {
            if let Ok(_) = stop.try_recv() { break }
            let snap = c.poll();
            if tx.send(snap).is_err() { break }
            std::thread::sleep(Duration::from_millis(100));
        }
    });
    rx
}

/// 歌词加载线程：主线程发 LoadRequest，异步返回歌词
pub fn spawn_lyrics_loader(receiver: Receiver<LoadRequest>) -> Receiver<LyricsPayload> {
    let (tx, rx) = channel::<LyricsPayload>();
    std::thread::spawn(move || {
        while let Ok(req) = receiver.recv() {
            let payload = load_lyrics(&req);
            if tx.send(payload).is_err() { break }
        }
    });
    rx
}

/// 加载歌词：按播放器 Provider 路由；手动指定直接拉该曲目；否则搜索候选按顺序降级
fn load_lyrics(req: &LoadRequest) -> LyricsPayload {
    match req.provider {
        Provider::Apple => load_apple_lyrics(req),
        Provider::Soda => load_soda_lyrics(req),
    }
}

/// Apple Music：iTunes 搜索候选 + LRCLIB 行级歌词（手动指定按其曲目信息直取）
fn load_apple_lyrics(req: &LoadRequest) -> LyricsPayload {
    let mut payload = LyricsPayload { track_key: req.key.clone(), credit: format!("{} · {}", req.title, req.artist), ..Default::default() };

    let (title, artist, dur_ms) = match &req.manual {
        Some(m) => (m.title.clone(), m.artist.clone(), m.duration_ms as f64),
        None => (req.title.clone(), req.artist.clone(), req.player_dur_ms),
    };

    // 歌词：AMLL 词级（adam 直查）→ volcengine 词级 → LRCLIB 行级。
    // 手动切换候选时其 adamID 与候选不一致（候选来自 iTunes 文本搜索），跳过 AMLL 走文本匹配源
    let adam = if req.manual.is_some() { 0 } else { req.adam_id };
    match crate::api_apple::fetch_apple_lyrics(adam, &title, &artist, dur_ms as i64) {
        Ok(lines) if !lines.is_empty() => {
            payload.lines = lines;
            payload.ok = true;
            payload.fail = FailKind::None;
            if let Some(m) = &req.manual {
                payload.track_id = m.id.clone();
                payload.cover_url = m.cover_url.clone();
            }
            log(&format!("apple lyrics ok: {} - {}", title, artist));
        }
        Ok(_) => {
            payload.fail = FailKind::NoResult;
            log(&format!("apple lyrics no result: {} - {}", title, artist));
        }
        Err(e) => {
            payload.fail = FailKind::Error;
            log(&format!("apple lyrics error: {} - {}: {}", title, artist, e));
        }
    }

    // 候选：手动指定时不再自动搜索；自动流程发 iTunes 候选（时长过滤保留）
    if req.manual.is_none() {
        let keyword = format!("{} {}", req.title, req.artist);
        if let Ok(tracks) = crate::api_apple::search_itunes(&keyword) {
            let kept: Vec<crate::api::Track> = if req.player_dur_ms > 0.0 {
                let allow = (req.player_dur_ms * 0.08).max(5000.0);
                tracks.iter().filter(|t| (t.duration_ms as f64 - req.player_dur_ms).abs() <= allow).cloned().collect()
            } else {
                tracks
            };
            payload.candidates = kept;
            log(&format!("apple candidates: {}", payload.candidates.len()));
        }
    }
    payload
}

/// 加载歌词：手动指定直接拉该曲目；否则搜索候选并按顺序降级重试
fn load_soda_lyrics(req: &LoadRequest) -> LyricsPayload {
    let mut payload = LyricsPayload { track_key: req.key.clone(), credit: format!("{} · {}", req.title, req.artist), ..Default::default() };

    // 手动指定：直接拉取，不做自动降级（用户意图明确，失败就明确告知）
    if let Some(m) = &req.manual {
        payload.track_id = m.id.clone();
        payload.credit = format!("{} · {}", m.title, m.artist);
        payload.cover_url = m.cover_url.clone();
        return match api::fetch_lyrics(&m.id) {
            Ok(lines) => {
                let got = !lines.is_empty();
                payload.lines = lines;
                payload.ok = got;
                payload.fail = if got { FailKind::None } else { FailKind::NoResult };
                log(&format!("manual lyrics {} {} ok={}", m.id, m.title, got));
                payload
            }
            Err(e) => {
                log(&format!("manual lyrics error: {} {}", m.id, e));
                payload.fail = FailKind::Error;
                payload
            }
        };
    }

    // 自动流程：搜索 -> 时长匹配剔除 -> 按候选顺序尝试（跳过空歌词），前 MAX_AUTO_TRY 条为限
    let keyword = format!("{} {}", req.title, req.artist);
    const MAX_AUTO_TRY: usize = 4;
    match api::search_tracks(&keyword) {
        Ok(tracks) => {
            // 时长匹配：剔除与播放器总时长差异明显的候选（阈值 = 8% 或 5s 取大），
            // 保留的按时长差升序（最接近播放器时长的优先尝试）；
            // 全部被剔除时回退全量（播放器时长可能不准，避免误杀导致无歌词）。
            // 归一化标题（比大小写/空白/标点）
            let norm = |x: &str| x.chars().filter(|c| c.is_alphanumeric()).collect::<String>().to_lowercase();
            let target = norm(&req.title);
            let (mut kept, rest): (Vec<&api::Track>, Vec<&api::Track>) = if req.player_dur_ms > 0.0 {
                let allow = (req.player_dur_ms * 0.08).max(5000.0);
                let mut k: Vec<&api::Track> = Vec::new();
                let mut r: Vec<&api::Track> = Vec::new();
                for t in &tracks {
                    if (t.duration_ms as f64 - req.player_dur_ms).abs() <= allow { k.push(t) } else { r.push(t) }
                }
                (k, r)
            } else {
                // 播放器时长缺失（dur=0）：时长过滤/排序不可靠 → 标题精确匹配优先，其余垫后
                let mut k: Vec<&api::Track> = Vec::new();
                let mut r: Vec<&api::Track> = Vec::new();
                for t in &tracks {
                    if norm(&t.title) == target { k.push(t) } else { r.push(t) }
                }
                (k, r)
            };
            if req.player_dur_ms > 0.0 {
                kept.sort_by_key(|t| (t.duration_ms as f64 - req.player_dur_ms).abs() as i64);
            }
            let chosen: Vec<&api::Track> = if kept.is_empty() {
                tracks.iter().collect()
            } else {
                kept.iter().copied().chain(rest.iter().copied()).collect()
            };
            // 发给 UI 的候选 = 时长匹配保留集（空则回退全量）
            payload.candidates = if kept.is_empty() { tracks.clone() } else { kept.iter().map(|t| (*t).clone()).collect() };
            log(&format!(
                "dur-match player={:.0}ms kept={}/{}",
                req.player_dur_ms, payload.candidates.len(), tracks.len()
            ));
            let mut saw_err = false;
            for t in chosen.iter().take(MAX_AUTO_TRY) {
                match api::fetch_lyrics(&t.id) {
                    Ok(lines) if !lines.is_empty() => {
                        payload.lines = lines;
                        payload.credit = format!("{} · {}", t.title, t.artist);
                        payload.track_id = t.id.clone();
                        payload.cover_url = t.cover_url.clone();
                        payload.ok = true;
                        payload.fail = FailKind::None;
                        log(&format!("lyrics hit at #{} {} {}", tracks.iter().position(|x| x.id == t.id).unwrap_or(0) + 1, t.id, t.title));
                        break;
                    }
                    Ok(_) => {
                        log(&format!("lyrics empty at {} {}", t.id, t.title));
                    }
                    Err(e) => {
                        saw_err = true;
                        log(&format!("lyrics fetch error: {} {}", t.id, e));
                    }
                }
            }
            if !payload.ok {
                payload.fail = if saw_err { FailKind::Error } else { FailKind::NoResult };
            }
            payload
        }
        Err(e) => {
            log(&format!("search error: {}", e));
            payload.fail = FailKind::Error;
            payload
        }
    }
}

/// 运行日志（/tmp/soda-lyrics-rust.log）
pub fn log(s: &str) {
    use std::io::Write;
    let line = format!("{} {}\n", chrono_like_now(), s);
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open("/tmp/soda-lyrics-rust.log") {
        let _ = f.write_all(line.as_bytes());
    }
}

fn chrono_like_now() -> String {
    // 轻量时间戳（避免引 chrono）
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    let (_, secs) = (secs / 86400, secs % 86400);
    let (h, rest) = ((secs / 3600 + 8) % 24, secs % 3600);
    let (m, s) = (rest / 60, rest % 60);
    format!("{:02}:{:02}:{:02}", h, m, s)
}

/// mpsc recv 辅助：非致命轮询
pub fn recv_timeout<T>(rx: &Receiver<T>, ms: u64) -> Option<T> {
    match rx.recv_timeout(Duration::from_millis(ms)) {
        Ok(v) => Some(v),
        Err(RecvTimeoutError::Disconnected) => None,
        Err(RecvTimeoutError::Timeout) => None,
    }
}

/// 给 UI 用：mpsc Sender 模式
pub type LoaderSender = Sender<(String, String, String)>;