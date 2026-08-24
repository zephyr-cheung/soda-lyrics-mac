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
    /// iTunes Store adam id（Apple 系；路由 AMLL 词级歌词用）
    pub adam_id: i64,
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
    /// elC：now - CurrentPlaybackDate（汽水提供；Apple Music 恒 -1）
    pub elapsed_ms: f64,
    /// Apple Music：ElapsedTime 快照（播放开始时刻，播放中不更新）
    pub elapsed_snapshot_ms: f64,
    /// Apple Music：Timestamp epoch（毫秒）——快照时刻，用于 elC 缺失时实时推算
    pub ts_ms: f64,
    /// iTunes Store adam id（Apple 系内容；汽水/第三方 0）
    pub adam_id: i64,
}


/// 定位 python 解释器（采集代理必须经解释器进程；MediaRemote 只对解释器类进程返回数据）：
/// 实测结论：mediaremoted 对客户端有来源校验——仅 Apple 签名的 /usr/bin/python3 可读，
/// Homebrew 的 python（无 Apple 签名）一律返回 null。
/// 1) 环境变量 SODA_PYTHON（用户显式覆盖，需自行承担兼容性）
/// 2) /usr/bin/python3（系统自带，Apple 签名；依赖 CommandLineTools——
///    能用 brew 必有 CLT，故 brew 分发场景必然存在）
/// 3) Homebrew python 兜底（仅当系统 python 缺席时尝试）
fn locate_python() -> String {
    if let Ok(p) = std::env::var("SODA_PYTHON") {
        if !p.is_empty() { return p }
    }
    if std::path::Path::new("/usr/bin/python3").exists() {
        return "/usr/bin/python3".to_string();
    }
    let candidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ];
    for c in candidates {
        if std::path::Path::new(c).exists() {
            return c.to_string();
        }
    }
    "/usr/bin/python3".to_string()
}

/// 常驻 stream：启动 python + dylib（一次 fork），按 interval_ms 持续输出 JSON 行
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
    match Command::new(locate_python())
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
                            // 播放器路由：Apple 系内容带 iTunes Store adam id（汽水/第三方恒 0）
                            let adam = v.get("adamID").and_then(|x| x.as_i64()).unwrap_or(0);
                            // 真实进度：elC（汽水 cpd 折算）优先；Apple Music 无 cpd 时
                            // elapsed 为快照、ts 为快照时刻（core 用 elapsed+(now-ts)*rate 实时推算）
                            let elc = v.get("elC").and_then(|x| x.as_f64()).filter(|e| *e >= 0.0).unwrap_or(-1.0);
                            let row = StreamRow {
                                title: v.get("title").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                                artist: v.get("artist").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                                duration_ms: v.get("dur").and_then(|x| x.as_f64()).unwrap_or(0.0) * 1000.0,
                                rate: v.get("rate").and_then(|x| x.as_f64()).unwrap_or(1.0),
                                playing: v.get("rate").and_then(|x| x.as_f64()).unwrap_or(0.0) > 0.0,
                                app_id: if adam > 0 { "com.apple.Music" } else { "com.soda.music" }.to_string(),
                                elapsed_ms: elc * 1000.0,
                                elapsed_snapshot_ms: v.get("elapsed").and_then(|x| x.as_f64()).unwrap_or(-1.0) * 1000.0,
                                ts_ms: v.get("ts").and_then(|x| x.as_f64()).unwrap_or(0.0) * 1000.0,
                                adam_id: adam,
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
    last_switch_at: Instant,
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
            last_switch_at: Instant::now(),
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
        let mut row_elapsed: f64 = -1.0;
        let mut row_ts: f64 = 0.0;
        let mut row_rate: f64 = 1.0;
        let mut row_adam: i64 = 0;
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
                        self.last_switch_at = now;   // 切歌时刻（30s 播放窗口兜底）
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
            row_elapsed = r.elapsed_snapshot_ms;
            row_ts = r.ts_ms;
            row_rate = r.rate;
            row_adam = r.adam_id;
        }

        // 2) 进度：真实优先
        //    a) elC = now - CurrentPlaybackDate（汽水，系统口径精确）
        //    b) Apple Music（adamID>0）：ElapsedTime 快照 + Timestamp 推算 = elapsed + (now - ts) * rate
        //       （播放中 dict 不刷新，但 ts 时刻已知，推算无漂移；
        //         汽水也有 ElapsedTime/Timestamp 键，但其 elC 短暂缺失时不能走此分支——会跳到快照值）
        //    c) 兜底增量推进（暂停冻结）
        if self.have_song {
            // elC 防呆：明显超出曲目时长（或时长缺失时超过 1 小时）的会话级陈旧值视为无效，
            // 否则 MR 会话挂起时会显示 13 小时之类的假进度
            let elc_ok = row_elc >= 0.0 && {
                if self.last_dur > 0.0 {
                    row_elc <= self.last_dur + 30_000.0
                } else {
                    row_elc <= 3_600_000.0
                }
            };
            if elc_ok {
                // 无条件同步：汽水 dict 偶发 rate=0（playing 判定 false）时也要显示真实位置
                self.pos = row_elc;
            } else if self.playing && row_adam > 0 && row_elapsed >= 0.0 && row_ts > 0.0 {
                let epoch_ms = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as f64;
                self.pos = row_elapsed + (epoch_ms - row_ts) * row_rate;
            } else {
                // 播放兜底：MR 时间轴失效（dur/rate 恒 0）时，切歌后 30 秒内按 1x 自推进，
                // 让进度条先走起来；MR 恢复后 elC/elapsed 接管
                let switching = self.last_switch_at.elapsed().as_secs() < 30;
                let dt = now.duration_since(self.last_at).as_secs_f64() * 1000.0;
                if (self.playing || switching) && dt > 0.0 && dt < 5000.0 {
                    let r = if self.rate > 0.0 { self.rate } else { 1.0 };
                    self.pos += dt * r;
                }
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
        snap.adam_id = row_adam;
        snap
    }
}

