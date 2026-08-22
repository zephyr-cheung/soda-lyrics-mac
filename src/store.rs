//! 状态合并：采集 -> 曲目识别 -> 歌词加载
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::Duration;

use crate::api;
use crate::lyrics::LyricLine;
use crate::media::{Collector, Snapshot};

/// 歌词加载结果（发送给主线程）
#[derive(Debug, Clone, Default)]
pub struct LyricsPayload {
    pub track_key: String,
    pub credit: String,
    pub lines: Vec<LyricLine>,
    pub ok: bool,
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

/// 歌词加载线程：主线程发 (track_key, title, artist)，异步返回歌词
pub fn spawn_lyrics_loader(receiver: Receiver<(String, String, String)>) -> Receiver<LyricsPayload> {
    let (tx, rx) = channel::<LyricsPayload>();
    std::thread::spawn(move || {
        while let Ok((key, title, artist)) = receiver.recv() {
            let payload = load_lyrics(&key, &title, &artist);
            if tx.send(payload.0).is_err() { break }
            log(&format!("lyrics-loaded {} {}x{} ok={}", key, title, artist, payload.1));
        }
    });
    rx
}

/// 识别并加载歌词：搜索 → best_match → h5_seo_track
fn load_lyrics(key: &str, title: &str, artist: &str) -> (LyricsPayload, bool) {
    let keyword = format!("{} {}", title, artist);
    let mut payload = LyricsPayload { track_key: key.to_string(), credit: format!("{} · {}", title, artist), ..Default::default() };
    match api::search_tracks(&keyword) {
        Ok(tracks) => {
            if let Some(best) = api::best_match(&tracks, title, artist).or_else(|| tracks.first().cloned()) {
                match api::fetch_lyrics(&best.id) {
                    Ok(lines) => {
                        let got = !lines.is_empty();
                        payload.lines = lines;
                        payload.credit = format!("{} · {}", best.title, best.artist);
                        payload.ok = got;
                        (payload, got)
                    }
                    Err(e) => { log(&format!("lyrics fetch error: {}", e)); (payload, false) }
                }
            } else {
                (payload, false)
            }
        }
        Err(e) => { log(&format!("search error: {}", e)); (payload, false) }
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