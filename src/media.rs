//! 播放信息采集：spawn python3 代理（ctypes 调 libmr_full.dylib），长驻 stream 模式，零重复 fork
//! 进度策略：信任系统真实进度 elC = 当前墙钟 - CurrentPlaybackDate（精确、无漂移）；暂停冻结
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{channel, Receiver};
use std::time::Instant;

/// 采集到的播放快照
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Snapshot {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: f64,
    pub position_ms: f64,
    pub rate: f64,
    pub playing: bool,
    pub available: bool,
    /// 正在播放的应用 Bundle ID（mediaremote-rs 提供）
    pub app_id: String,
}

/// stream 行（适配器持续输出的 NowPlayingInfo JSON）
#[derive(Debug, Clone, Default)]
pub struct StreamRow {
    pub title: String,
    pub artist: String,
    pub duration_ms: f64,
    pub rate: f64,
    pub playing: bool,
    pub app_id: String,
    /// 真实进度：now - CurrentPlaybackDate（系统 dict 提供，适配器恒 0 但 cpd 准确）
    pub elapsed_ms: f64,
}


/// 常驻 stream：启动 perl + dylib（一次 fork），按 interval_ms 持续输出 JSON 行
pub fn spawn_stream_source(interval_ms: u64) -> (Option<Child>, Receiver<StreamRow>) {
    let (tx, rx) = channel::<StreamRow>();
    let dylib = locate_dylib();
    let Some(dylib) = dylib else {
        return (None, rx);
    };
    let py = format!(
        "import ctypes,time,sys\nlib=ctypes.CDLL(sys.argv[1])\nf=lib.mr_get_full_json\nwhile True:\n    f()\n    sys.stdout.flush()\n    time.sleep({})\n",
        (interval_ms.max(200) as f64) / 1000.0
    );
    match Command::new("/usr/bin/python3")
        .arg("-u")
        .arg("-c")
        .arg(&py)
        .arg(&dylib)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(mut child) => {
            let stdout = child.stdout.take();
            if let Some(pipe) = stdout {
                std::thread::spawn(move || {
                    let reader = BufReader::new(pipe);
                    let mut line_n = 0usize;
                    for line in reader.lines() {
                        line_n += 1;
                        if line_n % 25 == 0 {
                            crate::store::log(&format!("stream rows: {}", line_n));
                        }
                        let Ok(line) = line else { break };
                        let trimmed = line.trim();
                        if trimmed.is_empty() || trimmed == "null" {
                            continue;
                        }
                        if let Ok(v) = serde_json::from_str::<Value>(trimmed) {
                            let _ = v;
                            // 调试：行到达节流日志
                            // (在 parse 处计数)
                            let row = StreamRow {
                                title: v.get("title").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                                artist: v.get("artist").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                                duration_ms: v.get("dur").and_then(|x| x.as_f64()).unwrap_or(0.0) * 1000.0,
                                rate: v.get("rate").and_then(|x| x.as_f64()).unwrap_or(1.0),
                                playing: v.get("rate").and_then(|x| x.as_f64()).unwrap_or(0.0) > 0.0,
                                app_id: "com.soda.music".to_string(),
                                elapsed_ms: v.get("elC").and_then(|x| x.as_f64()).unwrap_or(-1.0) * 1000.0,
                            };
                            if tx.send(row).is_err() {
                                break;
                            }
                        }
                    }
                });
            }
            (Some(child), rx)
        }
        Err(e) => {
            crate::store::log(&format!("stream spawn failed: {}", e));
            (None, rx)
        }
    }
}

/// 定位采集插件 dylib（相对定位，不依赖绝对路径）：
/// 1) 打包分发：与可执行文件同目录（bundle Resources）
/// 2) 开发目录：沿可执行文件逐级向上找 <root>/resources/libmr_full.dylib
/// 3) cwd 兜底：<cwd>/resources/libmr_full.dylib
fn locate_dylib() -> Option<String> {
    let mut candidates: Vec<String> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("libmr_full.dylib").to_string_lossy().to_string());
        }
        let mut dir = exe.parent();
        while let Some(d) = dir {
            candidates.push(d.join("resources").join("libmr_full.dylib").to_string_lossy().to_string());
            if d.as_os_str().is_empty() {
                break; // 防御：parent 链抵达路径起点（空路径）即终止
            }
            dir = d.parent();
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("resources").join("libmr_full.dylib").to_string_lossy().to_string());
    }
    candidates.iter().find(|p| std::path::Path::new(p).exists()).cloned()
}

/// 采集器：消化 stream 行 + 增量推进
pub struct Collector {
    rx: Receiver<StreamRow>,
    pos: f64,
    last_at: Instant,
    rate: f64,
    playing: bool,
    have_song: bool,
    last_title: String,
    last_artist: String,
    last_dur: f64,
    app_id: String,
    fallback: bool,
    hit_at: Option<Instant>,
    pending_title: Option<String>,
}

impl Collector {
    pub fn new(rx: Receiver<StreamRow>) -> Self {
        Self {
            rx,
            pos: 0.0,
            last_at: Instant::now(),
            rate: 1.0,
            playing: false,
            have_song: false,
            last_title: String::new(),
            last_artist: String::new(),
            last_dur: 0.0,
            app_id: String::new(),
            fallback: false,
            hit_at: None,
            pending_title: None,
        }
    }

    pub fn poll(&mut self) -> Snapshot {
        let mut snap = Snapshot::default();
        let now = Instant::now();

        // 1) 消化 stream 行（最多 10 行/帧，防积压）
        let mut row: Option<StreamRow> = None;
        for _ in 0..10 {
            match self.rx.try_recv() {
                Ok(r) => row = Some(r),
                Err(_) => break,
            }
        }
        let mut row_elc: f64 = -1.0;
        if let Some(r) = row {
            // 空 title 行（无信息/查询异常）：完全忽略，避免误清状态
            if r.title.is_empty() {
                return snap;
            }
            self.app_id = r.app_id.clone();
            // 换歌防抖：需连续两行同 title 才确认（防适配器偶发抖动行）
            if r.title != self.last_title {
                match &self.pending_title {
                    Some(p) if *p == r.title => {
                        self.pending_title = None;
                        self.last_title = r.title.clone();
                        self.last_artist = r.artist.clone();
                        self.last_dur = r.duration_ms;
                        self.pos = 0.0;
                        self.last_at = now;
                    }
                    _ => {
                        self.pending_title = Some(r.title.clone());
                    }
                }
            } else {
                self.pending_title = None;
            }
            self.rate = r.rate;
            self.playing = r.playing;
            self.last_dur = r.duration_ms;
            self.have_song = !r.title.is_empty();
            row_elc = r.elapsed_ms;
        }

        // 2) 进度：优先真实进度（elC = now - CurrentPlaybackDate，系统口径精确）
        if self.playing && self.have_song && row_elc >= 0.0 {
            self.pos = row_elc;
        } else {
            // 兜底增量推进（暂停冻结）
            let dt = now.duration_since(self.last_at).as_secs_f64() * 1000.0;
            if self.playing && self.have_song && dt > 0.0 && dt < 5000.0 {
                self.pos += dt * self.rate;
            }
        }
        self.last_at = now;
        // 3) 曲尾保护：不显示 100%；播放中越过曲尾 2s 判定循环/切歌自动回 0
        if self.last_dur > 0.0 && self.pos >= self.last_dur - 500.0 {
            if self.playing {
                match self.hit_at {
                    None => self.hit_at = Some(now),
                    Some(t0) => {
                        if now.duration_since(t0).as_secs_f64() > 2.0 {
                            self.pos = 0.0;
                            self.hit_at = None;
                        } else {
                            self.pos = self.last_dur - 500.0;
                        }
                    }
                }
            } else {
                self.pos = self.last_dur - 500.0;
            }
        } else {
            self.hit_at = None;
        }

        snap.title = self.last_title.clone();
        snap.artist = self.last_artist.clone();
        snap.duration_ms = self.last_dur;
        snap.position_ms = self.pos;
        snap.rate = self.rate;
        snap.playing = self.playing;
        snap.available = self.have_song;
        snap.app_id = self.app_id.clone();
        snap
    }
}

