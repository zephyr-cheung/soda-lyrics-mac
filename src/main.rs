mod api;
mod lyrics;
mod media;
mod store;

use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::sync::mpsc::{channel, Sender};
use std::time::Duration;

fn main() {
    store::log("soda-core starting");
    let (_stop_tx, stop_rx) = channel::<()>();
    let snap_rx = store::spawn_collector(stop_rx);
    let (loader_tx, loader_rx): (Sender<store::LoadRequest>, _) = channel();
    let lyrics_rx = store::spawn_lyrics_loader(loader_rx);

    // stdin 指令通道（Swift UI -> core）：{"t":"pick","id":...} / {"t":"refresh"}
    let (stdin_tx, stdin_rx) = channel::<String>();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut lock = stdin.lock();
        let mut line = String::new();
        loop {
            line.clear();
            match lock.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    let l = line.trim().to_string();
                    if l.is_empty() || stdin_tx.send(l).is_err() { break }
                }
            }
        }
    });

    let mut loaded_key = String::new();
    let mut pending_key = String::new();
    let mut title = String::new();
    let mut artist = String::new();
    let mut pos = 0.0f64;
    let mut dur = 0.0f64;
    let mut playing = false;
    let mut lines: Vec<lyrics::LyricLine> = Vec::new();
    // 当前曲目候选列表（手动切换用；换歌清空）
    let mut current_candidates: Vec<api::Track> = Vec::new();
    // 手动指定的 track id（UI 切换后记录；换歌清空，重播同歌时沿用）
    let mut manual_id: Option<String> = None;
    // 切歌辅助检测：MediaRemote 元数据滞后时（切歌瞬间仍报旧 title），用
    // 「位置大幅回退到开头」识别切歌，提前清空并触发加载，避免旧歌词残留
    let mut last_track_pos: Option<f64> = None;

    let mut out = std::io::stdout();
    loop {
        // 采集快照（三段式：汽水 / 查询失败保持现状 / 其他 App 清空）
        // 本轮是否检测到「位置回退式切歌」（snap 消息带 track 标志通知 Swift 清空）
        let mut track_event = false;
        while let Some(snap) = store::recv_timeout(&snap_rx, 0) {
            let app_id = snap.app_id.clone();
            if app_id == "com.soda.music" {
                // 位置回退检测：标题未变但正在播放且位置回到开头（距上次 >20s 回退）
                if !snap.title.is_empty() && snap.playing && snap.position_ms < 5000.0 {
                    if let Some(prev) = last_track_pos {
                        if prev - snap.position_ms > 20000.0 {
                            if loaded_key == snap.title {
                                store::log(&format!("track-change(rewind) -> {}", snap.title));
                                lines.clear();
                                manual_id = None;
                                current_candidates.clear();
                                loader_tx
                                    .send(store::LoadRequest {
                                        key: snap.title.clone(),
                                        title: snap.title.clone(),
                                        artist: snap.artist.clone(),
                                        player_dur_ms: snap.duration_ms,
                                        manual: None,
                                    })
                                    .ok();
                                track_event = true;
                            }
                        }
                    }
                }
                title = snap.title.clone();
                artist = snap.artist.clone();
                pos = snap.position_ms;
                dur = snap.duration_ms;
                playing = snap.playing;
                if !snap.title.is_empty() && loaded_key != snap.title {
                    loaded_key = snap.title.clone();
                    pending_key = snap.title.clone();
                    lines.clear();
                    manual_id = None;
                    current_candidates.clear();
                    loader_tx
                        .send(store::LoadRequest {
                            key: snap.title.clone(),
                            title: snap.title.clone(),
                            artist: snap.artist.clone(),
                            player_dur_ms: snap.duration_ms,
                            manual: None,
                        })
                        .ok();
                    store::log(&format!("track-change -> {}", snap.title));
                }
                last_track_pos = if snap.playing { Some(snap.position_ms) } else { None };
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
                    manual_id = None;
                    current_candidates.clear();
                    let empty_msg = json!({"t": "lyrics", "title": "", "artist": "", "credit": "", "lines": []});
                    let _ = writeln!(out, "{}", serde_json::to_string(&empty_msg).unwrap_or_default());
                    let _ = out.flush();
                }
            }
        }
        // Swift UI 指令（pick / refresh）
        while let Ok(cmd) = stdin_rx.try_recv() {
            if let Ok(v) = serde_json::from_str::<Value>(&cmd) {
                match v.get("t").and_then(|x| x.as_str()) {
                    Some("pick") => {
                        if let Some(id) = v.get("id").and_then(|x| x.as_str()) {
                            if let Some(t) = current_candidates.iter().find(|t| t.id == id) {
                                manual_id = Some(id.to_string());
                                pending_key = title.clone();
                                lines.clear();
                                loader_tx.send(store::LoadRequest {
                                    key: title.clone(),
                                    title: title.clone(),
                                    artist: artist.clone(),
                                    player_dur_ms: dur,
                                    manual: Some(t.clone()),
                                }).ok();
                                store::log(&format!("user pick -> {} {}", id, t.title));
                            } else {
                                store::log(&format!("pick ignored (id not in candidates): {}", id));
                            }
                        }
                    }
                    Some("refresh") => {
                        manual_id = None;
                        current_candidates.clear();
                        pending_key = title.clone();
                        lines.clear();
                        if !title.is_empty() {
                            loader_tx.send(store::LoadRequest {
                                key: title.clone(),
                                title: title.clone(),
                                artist: artist.clone(),
                                player_dur_ms: dur,
                                manual: None,
                            }).ok();
                            store::log("refresh -> re-search current track");
                        }
                    }
                    _ => {}
                }
            }
        }
        // 歌词结果
        loop {
            match lyrics_rx.try_recv() {
                Ok(payload) => {
                    if pending_key == payload.track_key || pending_key.is_empty() {
                        lines = payload.lines;
                        pending_key.clear();
                        // 自动流程的候选列表 -> UI（手动指定时 payload.candidates 为空，不重发）
                        if !payload.candidates.is_empty() {
                            current_candidates = payload.candidates.clone();
                            let items: Vec<serde_json::Value> = payload.candidates.iter()
                                .map(|t| json!({"id": t.id, "title": t.title, "artist": t.artist, "dur": t.duration_ms, "cover": t.cover_url}))
                                .collect();
                            let cand_msg = json!({"t": "candidates", "title": title, "artist": artist, "items": items});
                            let _ = writeln!(out, "{}", serde_json::to_string(&cand_msg).unwrap_or_default());
                            let _ = out.flush();
                        }
                        // 完整歌词
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
                        let fail = match payload.fail {
                            store::FailKind::None => "none",
                            store::FailKind::NoResult => "noresult",
                            store::FailKind::Error => "error",
                        };
                        let msg = json!({
                            "t": "lyrics",
                            "title": title,
                            "artist": artist,
                            "credit": payload.credit,
                            "track_id": payload.track_id,
                            "cover": payload.cover_url,
                            "fail": fail,
                            "lines": lines_json,
                        });
                        let line = serde_json::to_string(&msg).unwrap_or_default();
                        let _ = writeln!(out, "{}", line);
                        let _ = out.flush();
                        store::log(&format!("lyrics sent {} lines fail={} manual={}", lines.len(), fail, manual_id.is_some()));
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
            // 位置回退式切歌：Swift 收到后立即清空歌词进入加载态
            // （否则它依赖 title 变化检测，MediaRemote 滞后期间会残留旧歌词）
            "track": track_event,
        });
        let line = serde_json::to_string(&snap_msg).unwrap_or_default();
        let _ = writeln!(out, "{}", line);
        let _ = out.flush();
        std::thread::sleep(Duration::from_millis(100));
    }
}