mod api;
mod lyrics;
mod media;
mod store;

use serde_json::json;
use std::io::Write;
use std::sync::mpsc::channel;
use std::time::Duration;

fn main() {
    store::log("soda-core starting");
    let (_stop_tx, stop_rx) = channel::<()>();
    let snap_rx = store::spawn_collector(stop_rx);
    let (loader_tx, loader_rx): (std::sync::mpsc::Sender<(String, String, String)>, _) = channel();
    let lyrics_rx = store::spawn_lyrics_loader(loader_rx);

    let mut loaded_key = String::new();
    let mut pending_key = String::new();
    let mut title = String::new();
    let mut artist = String::new();
    let mut pos = 0.0f64;
    let mut dur = 0.0f64;
    let mut playing = false;
    let mut lines: Vec<lyrics::LyricLine> = Vec::new();

    let mut out = std::io::stdout();
    let mut first = true;
    loop {
        // 采集快照（三段式：汽水 / 查询失败保持现状 / 其他 App 清空）
        while let Some(snap) = store::recv_timeout(&snap_rx, 0) {
            let app_id = snap.app_id.clone();
            let mut cleared = false;
            if app_id == "com.soda.music" {
                title = snap.title.clone();
                artist = snap.artist.clone();
                pos = snap.position_ms;
                dur = snap.duration_ms;
                playing = snap.playing;
                if !snap.title.is_empty() && loaded_key != snap.title {
                    loaded_key = snap.title.clone();
                    pending_key = snap.title.clone();
                    lines.clear();
                    loader_tx
                        .send((snap.title.clone(), snap.title.clone(), snap.artist.clone()))
                        .ok();
                    store::log(&format!("track-change -> {}", snap.title));
                }
            } else if app_id.is_empty() {
                // 查询失败 / 无数据：保持现状，避免误清空；Swift 侧自推进兜底
            } else {
                // 明确是其他 App：清空全部状态（防抖：仅清一次）
                if !title.is_empty() || !lines.is_empty() {
                    store::log(&format!("other-app playing ({}) -> cleared", app_id));
                    title.clear();
                    artist.clear();
                    pos = 0.0;
                    dur = 0.0;
                    playing = false;
                    lines.clear();
                    loaded_key.clear();
                    pending_key.clear();
                    let empty_msg = json!({"t": "lyrics", "title": "", "artist": "", "credit": "", "lines": []});
                    let _ = writeln!(out, "{}", serde_json::to_string(&empty_msg).unwrap_or_default());
                    let _ = out.flush();
                    cleared = true;
                }
            }
            let _ = cleared;
        }
        // 歌词结果
        loop {
            match lyrics_rx.try_recv() {
                Ok(payload) => {
                    if pending_key == payload.track_key || pending_key.is_empty() {
                        lines = payload.lines;
                        pending_key.clear();
                        // 发送完整歌词
                        let lines_json: Vec<serde_json::Value> = lines
                            .iter()
                            .map(|l| {
                                json!({
                                    "s": l.start_ms,
                                    "e": l.end_ms,
                                    "t": l.text,
                                    "w": l.words.iter().map(|w| json!({"o": w.offset_ms, "d": w.dur_ms, "t": w.text})).collect::<Vec<_>>(),
                                })
                            })
                            .collect();
                        let msg = json!({
                            "t": "lyrics",
                            "title": title,
                            "artist": artist,
                            "credit": payload.credit,
                            "lines": lines_json,
                        });
                        let line = serde_json::to_string(&msg).unwrap_or_default();
                        let _ = writeln!(out, "{}", line);
                        let _ = out.flush();
                        store::log(&format!("lyrics sent {} lines", lines.len()));
                    }
                }
                Err(_) => break,
            }
        }
        // 快照（每 100ms；首条立即）
        // pos 为系统口径真实进度（now - CurrentPlaybackDate），直接输出
        let snap_msg = json!({
            "t": "snap",
            "title": title,
            "artist": artist,
            "pos": pos,
            "dur": dur,
            "playing": playing,
        });
        let line = serde_json::to_string(&snap_msg).unwrap_or_default();
        let _ = writeln!(out, "{}", line);
        let _ = out.flush();
        first = false;
        std::thread::sleep(Duration::from_millis(100));
    }
}