//! Apple Music 歌词源并发层（移植 Lyrics-Plus 各 provider，MIT；同步 reqwest 版）
//! 全部源并行搜索，返回带原始歌词文本的候选；主流程做打分排序

use crate::lyrics_match::{get_i64, get_str, score_candidate, LyricsSearchInput, LyricsSearchResult};
use base64::Engine;
use serde_json::Value;
use std::time::Duration;

const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const TIMEOUT: Duration = Duration::from_secs(8);
const AMLL_RAW_BASE: &str = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/master";

/// 源顺序（Smart 分数带内按此优先级；与 Lyrics-Plus 默认一致 + volcengine 垫底）
pub const PROVIDER_ORDER: [&str; 9] = [
    "lrclib", "kugou", "qqmusic", "netease", "kuwo", "amll_ttml", "migu", "musixmatch", "volcengine",
];

fn client() -> reqwest::blocking::Client {
    reqwest::blocking::Client::builder().timeout(TIMEOUT).build().unwrap_or_default()
}

fn enc(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// 并发执行（线程池式；网络超时 8s 由 client 保证）
fn parallel<T: Send, R: Send>(items: Vec<T>, f: impl Fn(T) -> R + Sync + Send) -> Vec<R> {
    let mut out = Vec::with_capacity(items.len());
    let f = &f;
    std::thread::scope(|s| {
        let handles: Vec<_> = items.into_iter()
            .map(|it| s.spawn(move || f(it)))
            .collect();
        for h in handles {
            out.push(h.join().unwrap_or_else(|_| panic!("provider thread panicked")));
        }
    });
    out
}

/// 全部源并发搜索（amll 需要 adam_id；volcengine 走词级）
pub fn search_all(input: &LyricsSearchInput, adam_id: i64) -> Vec<LyricsSearchResult> {
    let mut results: Vec<LyricsSearchResult> = Vec::new();
    std::thread::scope(|s| {
        let handles: Vec<_> = PROVIDER_ORDER.iter().map(|name| {
            let name = *name;
            let input = input.clone();
            s.spawn(move || match name {
                "lrclib" => lrclib_search(&input),
                "kugou" => kugou_search(&input),
                "qqmusic" => qqmusic_search(&input),
                "netease" => netease_search(&input),
                "kuwo" => kuwo_search(&input),
                "amll_ttml" => amll_search(&input, adam_id),
                "migu" => migu_search(&input),
                "musixmatch" => musixmatch_search(&input),
                "volcengine" => volcengine_search(&input),
                _ => Vec::new(),
            })
        }).collect();
        for h in handles {
            results.extend(h.join().unwrap_or_default());
        }
    });
    results
}

fn strip_html(s: &str) -> String {
    s.replace("<em>", "").replace("</em>", "").replace("<b>", "").replace("</b>", "")
}

fn base_result(provider: &str, id: &str, title: &str, artist: &str, album: Option<String>, dur: Option<i64>, lyrics: String) -> LyricsSearchResult {
    LyricsSearchResult {
        id: id.to_string(),
        provider_id: provider.to_string(),
        title: title.to_string(),
        artist: artist.to_string(),
        album,
        duration_ms: dur,
        source: provider.to_string(),
        synced: true,
        has_translation: false,
        has_word_timing: false,
        has_romanization: false,
        score: 0.0,
        lyrics,
    }
}

// ---------------- LRCLIB ----------------

fn lrclib_search(input: &LyricsSearchInput) -> Vec<LyricsSearchResult> {
    let c = client();
    let mut out = Vec::new();
    // 精确（时长对齐）
    if let Some(dur) = input.duration_ms.filter(|d| *d > 0) {
        let url = format!("https://lrclib.net/api/get?track_name={}&artist_name={}&duration={}", enc(&input.title), enc(&input.artist), (dur / 1000).max(1));
        if let Ok(resp) = c.get(&url).header("User-Agent", UA).send() {
            if let Ok(v) = resp.json::<Value>() {
                if let Some(l) = v.get("syncedLyrics").and_then(|x| x.as_str()) {
                    let mut r = base_result("lrclib", "get", input.title.as_str(), input.artist.as_str(), None, Some(dur), l.to_string());
                    r.id = v.get("id").and_then(|x| x.as_i64()).map(|i| i.to_string()).unwrap_or_else(|| "get".into());
                    r.score = score_candidate(input, &r);
                    out.push(r);
                }
            }
        }
    }
    // 候选（按差排序取前 3）
    let url = format!("https://lrclib.net/api/search?track_name={}&artist_name={}", enc(&input.title), enc(&input.artist));
    if let Ok(resp) = c.get(&url).header("User-Agent", UA).send() {
        if let Ok(arr) = resp.json::<Value>() {
            if let Some(items) = arr.as_array() {
                let mut cands: Vec<(i64, &Value)> = items.iter().filter_map(|it| {
                    let has = it.get("syncedLyrics").and_then(|x| x.as_str()).map_or(false, |s| !s.is_empty());
                    if !has { return None }
                    let d = it.get("duration").and_then(|x| x.as_f64()).map(|d| (d * 1000.0) as i64).unwrap_or(0);
                    let diff = match (input.duration_ms, d > 0) { (Some(p), true) => (p - d).abs(), _ => 0 };
                    Some((diff, it))
                }).collect();
                cands.sort_by_key(|(diff, _)| *diff);
                for (_, it) in cands.into_iter().take(3) {
                    if let Some(l) = it.get("syncedLyrics").and_then(|x| x.as_str()) {
                        let mut r = base_result("lrclib", &it.get("id").and_then(|x| x.as_i64()).map(|i| i.to_string()).unwrap_or_default(),
                            it.get("trackName").and_then(|x| x.as_str()).unwrap_or(&input.title),
                            it.get("artistName").and_then(|x| x.as_str()).unwrap_or(&input.artist),
                            it.get("albumName").and_then(|x| x.as_str()).map(|s| s.to_string()),
                            it.get("duration").and_then(|x| x.as_f64()).map(|d| (d * 1000.0) as i64),
                            l.to_string());
                        r.has_word_timing = l.contains('<') || l.split('\n').any(|ln| ln.contains('(') && ln.contains(','));
                        r.score = score_candidate(input, &r);
                        if r.score > 0.55 { out.push(r); }
                    }
                }
            }
        }
    }
    out
}

// ---------------- NetEase ----------------

fn netease_search(input: &LyricsSearchInput) -> Vec<LyricsSearchResult> {
    let c = client();
    let keyword = format!("{} {}", input.title.trim(), input.artist.trim());
    let url = format!("https://music.163.com/api/search/get/web?s={}&type=1&offset=0&total=true&limit=100", enc(&keyword));
    let Ok(resp) = c.get(&url).header("Referer", "https://music.163.com/").send() else { return Vec::new() };
    let Ok(v) = resp.json::<Value>() else { return Vec::new() };
    let Some(songs) = v.pointer("/result/songs").and_then(|x| x.as_array()) else { return Vec::new() };
    let mut cands: Vec<(f64, String, LyricsSearchResult)> = songs.iter().filter_map(|s| {
        let id = get_i64(s, &["id"])?;
        let title = get_str(s, &["name"])?.to_string();
        let artist = s.pointer("/artists").and_then(|a| a.as_array())
            .map(|arr| arr.iter().filter_map(|x| get_str(x, &["name"])).collect::<Vec<_>>().join(" / "))
            .unwrap_or_default();
        let album = get_str(s, &["album", "name"]).map(|a| a.to_string());
        let dur = get_i64(s, &["duration"]);
        let mut r = base_result("netease", &id.to_string(), &title, &artist, album, dur, String::new());
        r.score = score_candidate(input, &r);
        Some((r.score, id.to_string(), r))
    }).collect();
    cands.sort_by(|a, b| b.0.total_cmp(&a.0));
    // 详情并发（top4 → 词级 yrc 优先）
    let tops: Vec<(String, LyricsSearchResult)> = cands.into_iter().take(4).map(|(_, id, r)| (id, r)).collect();
    let details = parallel(tops, |(id, r)| {
        let url = format!("https://music.163.com/api/song/lyric?id={}&lv=1&kv=1&tv=1&yv=1&rv=1", id);
        let mut out_r = r;
        if let Ok(resp) = client().get(&url).header("Referer", "https://music.163.com/").send() {
            if let Ok(v) = resp.json::<Value>() {
                let yrc = v.get("yrc").and_then(|x| x.get("lyric")).and_then(|x| x.as_str()).filter(|s| !s.trim().is_empty());
                let lrc = v.get("lrc").and_then(|x| x.get("lyric")).and_then(|x| x.as_str()).filter(|s| !s.trim().is_empty());
                if let Some(w) = yrc {
                    out_r.lyrics = w.to_string();
                    out_r.has_word_timing = true;
                } else if let Some(l) = lrc {
                    out_r.lyrics = l.to_string();
                } else {
                    out_r.lyrics.clear();
                }
            }
        }
        out_r
    });
    details.into_iter().filter(|r| !r.lyrics.is_empty()).collect()
}

// ---------------- QQMusic ----------------

fn qqmusic_search(input: &LyricsSearchInput) -> Vec<LyricsSearchResult> {
    let c = client();
    let keyword = format!("{} {}", input.title.trim(), input.artist.trim());
    let mut url = reqwest::Url::parse("https://c.y.qq.com/soso/fcgi-bin/client_search_cp").unwrap();
    url.query_pairs_mut()
        .append_pair("w", &keyword)
        .append_pair("t", "0")
        .append_pair("format", "json")
        .append_pair("p", "1")
        .append_pair("n", "10");
    let Ok(resp) = c.get(url).header("Referer", "https://y.qq.com/").send() else { return Vec::new() };
    let Ok(v) = resp.json::<Value>() else { return Vec::new() };
    let Some(list) = v.pointer("/data/song/list").and_then(|x| x.as_array()) else { return Vec::new() };
    let mut cands: Vec<(f64, String, LyricsSearchResult)> = list.iter().filter_map(|s| {
        let mid = get_str(s, &["songmid"])?.to_string();
        let title = get_str(s, &["songname"])?.to_string();
        let artist = s.get("singer").and_then(|a| a.as_array())
            .map(|arr| arr.iter().filter_map(|x| get_str(x, &["name"])).collect::<Vec<_>>().join(" / "))
            .unwrap_or_default();
        let album = get_str(s, &["albumname"]).map(|a| a.to_string());
        let dur = get_i64(s, &["interval"]).map(|sec| sec * 1000);
        let mut r = base_result("qqmusic", &mid, &title, &artist, album, dur, String::new());
        r.score = score_candidate(input, &r);
        Some((r.score, mid, r))
    }).collect();
    cands.sort_by(|a, b| b.0.total_cmp(&a.0));
    let tops: Vec<(String, LyricsSearchResult)> = cands.into_iter().take(3).map(|(_, id, r)| (id, r)).collect();
    let details = parallel(tops, |(mid, r)| {
        let mut url = reqwest::Url::parse("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg").unwrap();
        url.query_pairs_mut().append_pair("songmid", &mid).append_pair("format", "json").append_pair("nobase64", "1");
        let mut out_r = r;
        if let Ok(resp) = client().get(url).header("Referer", "https://y.qq.com/").send() {
            if let Ok(v) = resp.json::<Value>() {
                let lrc = v.get("lyric").and_then(|x| x.as_str()).filter(|s| !s.trim().is_empty());
                if let Some(l) = lrc { out_r.lyrics = l.to_string(); }
            }
        }
        out_r
    });
    details.into_iter().filter(|r| !r.lyrics.is_empty()).collect()
}

// ---------------- Kugou ----------------

fn kugou_search(input: &LyricsSearchInput) -> Vec<LyricsSearchResult> {
    let c = client();
    let keyword = format!("{} {}", input.title.trim(), input.artist.trim());
    let url = format!("https://songsearch.kugou.com/song_search_v2?keyword={}&page=1&pagesize=10&userid=-1&clientver=&platform=WebFilter&tag=em&filter=2&iscorrection=1&privilege_filter=0", enc(&keyword));
    let Ok(resp) = c.get(&url).header("Referer", "https://www.kugou.com/").send() else { return Vec::new() };
    let Ok(v) = resp.json::<Value>() else { return Vec::new() };
    let Some(list) = v.pointer("/data/lists").and_then(|x| x.as_array()) else { return Vec::new() };
    let mut cands: Vec<(f64, &Value)> = list.iter().map(|s| {
        let r = base_result("kugou", "", &strip_html(get_str(s, &["SongName"]).unwrap_or("")), strip_html(get_str(s, &["SingerName"]).unwrap_or("")).as_str(),
            get_str(s, &["AlbumName"]).map(|a| a.to_string()).filter(|a| !a.is_empty()),
            get_str(s, &["Duration"]).and_then(|d| d.parse::<i64>().ok()).map(|sec| sec * 1000), String::new());
        // 搜索接口无时长时按标题/歌手打分
        let sc = score_candidate(input, &r);
        (sc, s)
    }).collect();
    cands.sort_by(|a, b| b.0.total_cmp(&a.0));
    // 每候选：search lyric + download（取前 2，串行内部并发）
    let tops: Vec<&Value> = cands.into_iter().take(2).map(|(_, s)| s).collect();
    let details = parallel(tops, |s| {
        let hash = get_str(s, &["FileHash"]).unwrap_or("").to_string();
        let mix = get_str(s, &["MixSongID"]).map(|m| m.to_string());
        let dur = get_str(s, &["Duration"]).and_then(|d| d.parse::<i64>().ok()).map(|sec| sec * 1000);
        let mut r = base_result("kugou", &format!("{}|{}", hash, mix.as_deref().unwrap_or("")), get_str(s, &["SongName"]).unwrap_or(""),
            get_str(s, &["SingerName"]).unwrap_or(""), get_str(s, &["AlbumName"]).map(|a| a.to_string()).filter(|a| !a.is_empty()), dur, String::new());
        // lyrics.kugou.com/search
        let mut url = reqwest::Url::parse("https://lyrics.kugou.com/search").unwrap();
        url.query_pairs_mut().append_pair("ver", "1").append_pair("man", "yes").append_pair("client", "pc").append_pair("hash", &hash);
        if let Some(d) = dur { url.query_pairs_mut().append_pair("duration", &d.to_string()); }
        if let Some(m) = &mix { url.query_pairs_mut().append_pair("album_audio_id", m); }
        if let Ok(resp) = client().get(url).header("Referer", "https://www.kugou.com/").send() {
            if let Ok(v) = resp.json::<Value>() {
                if let Some(items) = v.get("candidates").and_then(|x| x.as_array()) {
                    if let Some(cand) = items.first() {
                        let id = get_str(cand, &["id"]).unwrap_or("");
                        let ak = get_str(cand, &["accesskey"]).unwrap_or("");
                        let mut url2 = reqwest::Url::parse("https://lyrics.kugou.com/download").unwrap();
                        url2.query_pairs_mut().append_pair("ver", "1").append_pair("client", "pc").append_pair("id", id).append_pair("fmt", "lrc").append_pair("charset", "utf8").append_pair("accesskey", ak);
                        if let Ok(resp2) = client().get(url2).send() {
                            if let Ok(v2) = resp2.json::<Value>() {
                                if let Some(b64) = v2.get("content").and_then(|x| x.as_str()) {
                                    if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(b64) {
                                        if let Ok(text) = String::from_utf8(bytes) {
                                            let word = text.contains('<') || text.contains("(0,");
                                            r.lyrics = text;
                                            r.has_word_timing = word;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        r.score = score_candidate(input, &r);
        r
    });
    details.into_iter().filter(|r| !r.lyrics.is_empty() && r.score > 0.4).collect()
}

// ---------------- Kuwo ----------------

fn kuwo_search(input: &LyricsSearchInput) -> Vec<LyricsSearchResult> {
    let c = client();
    let mut url = reqwest::Url::parse("https://search.kuwo.cn/r.s").unwrap();
    url.query_pairs_mut()
        .append_pair("key", &input.title)
        .append_pair("uid", "0")
        .append_pair("ver", "kwplayer_ar_9.80.0.1")
        .append_pair("client", "kt")
        .append_pair("ting", "header")
        .append_pair("pn", "0")
        .append_pair("rn", "10")
        .append_pair("fc", "4")
        .append_pair("rformat", "json")
        .append_pair("pnsearch", "0")
        .append_pair("pcjson", "1");
    let Ok(resp) = c.get(url).header("Referer", "https://www.kuwo.cn/").send() else { return Vec::new() };
    let Ok(v) = resp.json::<Value>() else { return Vec::new() };
    let Some(list) = v.get("abslist").and_then(|x| x.as_array()) else { return Vec::new() };
    let mut cands: Vec<(f64, LyricsSearchResult)> = list.iter().filter_map(|s| {
        let id = get_str(s, &["MUSICRID"]).map(|r| r.replace("MUSIC_", "")).unwrap_or_default();
        if id.is_empty() { return None }
        let title = get_str(s, &["SONGNAME"]).unwrap_or("").to_string();
        let artist = get_str(s, &["ARTIST"]).unwrap_or("").to_string();
        let album = get_str(s, &["ALBUM"]).map(|a| a.to_string()).filter(|a| !a.is_empty());
        let dur = get_str(s, &["DURATION"]).and_then(|d| d.split('.').next().and_then(|x| x.parse::<i64>().ok())).map(|sec| sec * 1000);
        let mut r = base_result("kuwo", &id, &title, &artist, album, dur, String::new());
        r.score = score_candidate(input, &r);
        Some((r.score, r))
    }).collect();
    cands.sort_by(|a, b| b.0.total_cmp(&a.0));
    let tops: Vec<LyricsSearchResult> = cands.into_iter().take(3).map(|(_, r)| r).collect();
    let details = parallel(tops, |mut r| {
        let url = format!("https://kuwo.cn/openapi/v1/www/lyric/getlyric?musicId={}", r.id);
        if let Ok(resp) = client().get(&url).header("Referer", "https://kuwo.cn/").send() {
            if let Ok(v) = resp.json::<Value>() {
                if let Some(rows) = v.pointer("/data/lrclist").and_then(|x| x.as_array()) {
                    let mut lrc = String::new();
                    for row in rows {
                        let t = get_str(row, &["time"]).unwrap_or("");
                        let line = get_str(row, &["lineLyric"]).unwrap_or("");
                        if !line.trim().is_empty() {
                            lrc.push_str(&format!("[{},{}]{}\n", to_lrc_time(t), "", line));
                            let _ = to_lrc_time(t);
                        }
                    }
                    if !lrc.is_empty() { r.lyrics = lrc; }
                } else if let Some(lrc) = v.pointer("/data/lrc").and_then(|x| x.as_str()) {
                    r.lyrics = lrc.to_string();
                }
            }
        }
        r
    });
    details.into_iter().filter(|r| !r.lyrics.is_empty()).collect()
}

/// "20.53" 秒（字符串）→ "[00:20.53]"（kuwo lrclist 的 time 为秒）
fn to_lrc_time(sec_str: &str) -> String {
    let sec: f64 = sec_str.parse().unwrap_or(0.0);
    let total = sec as i64;
    let m = total / 60;
    let s = total % 60;
    let frac = ((sec - total as f64) * 100.0) as i64;
    format!("{:02}:{:02}.{:02}", m, s, frac)
}

// ---------------- Migu ----------------

fn migu_search(input: &LyricsSearchInput) -> Vec<LyricsSearchResult> {
    let c = client();
    let kw = encode_migu(&input.title);
    let url = format!("https://c.musicapp.migu.cn/MIGUM3.0/v1.0/content/search_all.do?text={}&pageNo=1&pageSize=10&searchSwitch=%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A0%2C%22mvSong%22%3A0%2C%22songList%22%3A0%2C%22bestShow%22%3A1%7D", kw);
    let Ok(resp) = c.get(&url).header("User-Agent", UA).send() else { return Vec::new() };
    let Ok(v) = resp.json::<Value>() else { return Vec::new() };
    let Some(list) = v.pointer("/songResultData/result").and_then(|x| x.as_array()) else { return Vec::new() };
    let mut cands: Vec<(f64, LyricsSearchResult)> = list.iter().filter_map(|s| {
        let id = get_str(s, &["copyrightId"]).unwrap_or("").to_string();
        if id.is_empty() { return None }
        let title = get_str(s, &["name"]).unwrap_or("").to_string();
        let artist = s.get("singers").and_then(|a| a.as_array())
            .map(|arr| arr.iter().filter_map(|x| get_str(x, &["name"])).collect::<Vec<_>>().join(" / "))
            .unwrap_or_default();
        let dur = get_str(s, &["duration"]).and_then(|d| d.parse::<f64>().ok()).map(|sec| (sec * 1000.0) as i64);
        let mut r = base_result("migu", &id, &title, &artist, None, dur, String::new());
        r.score = score_candidate(input, &r);
        Some((r.score, r))
    }).collect();
    cands.sort_by(|a, b| b.0.total_cmp(&a.0));
    // 歌词 URL 直取（bestShow 保留的 song 带 lrcUrl/trcUrl）
    let tops: Vec<LyricsSearchResult> = cands.into_iter().take(3).map(|(_, r)| r).collect();
    let details = parallel(tops, |mut r| {
        // 通过 lyricUrl 获取（需再按 copyrightId 查详情获得 url——简化：用 lyric 详情接口）
        let url = format!("https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceId={}&resourceType=2", r.id);
        if let Ok(resp) = client().get(&url).header("User-Agent", UA).send() {
            if let Ok(v) = resp.json::<Value>() {
                if let Some(lrc_url) = get_str(&v, &["resource", "lrcUrl"]) {
                    if let Ok(resp2) = client().get(lrc_url).send() {
                        if let Ok(text) = resp2.text() {
                            if !text.trim().is_empty() { r.lyrics = text; }
                        }
                    }
                }
            }
        }
        r
    });
    details.into_iter().filter(|r| !r.lyrics.is_empty()).collect()
}

fn encode_migu(s: &str) -> String {
    // 咪咕需要 UTF-8 编码（URL 编码）
    enc(s)
}

// ---------------- Musixmatch ----------------

fn musixmatch_search(input: &LyricsSearchInput) -> Vec<LyricsSearchResult> {
    const BASE: &str = "https://apic-desktop.musixmatch.com/ws/1.1";
    const APP_ID: &str = "web-desktop-app-v1.0";
    let c = client();
    // 匿名 token
    let mut url = reqwest::Url::parse(&format!("{}/token.get", BASE)).unwrap();
    url.query_pairs_mut().append_pair("app_id", APP_ID);
    let token = match c.get(url).send() {
        Ok(resp) => resp.json::<Value>().ok()
            .and_then(|v| v.pointer("/message/body/user_token").and_then(|x| x.as_str()).map(|s| s.to_string())),
        Err(_) => None,
    };
    let Some(token) = token else { return Vec::new() };
    // 搜索
    let mut url = reqwest::Url::parse(&format!("{}/track.search", BASE)).unwrap();
    url.query_pairs_mut()
        .append_pair("q_track", input.title.trim())
        .append_pair("q_artist", input.artist.trim())
        .append_pair("page", "1")
        .append_pair("page_size", "10")
        .append_pair("s_track_rating", "desc")
        .append_pair("app_id", APP_ID)
        .append_pair("usertoken", &token);
    let Ok(resp) = c.get(url).send() else { return Vec::new() };
    let Ok(v) = resp.json::<Value>() else { return Vec::new() };
    let Some(list) = v.pointer("/message/body/track_list").and_then(|x| x.as_array()) else { return Vec::new() };
    let mut cands: Vec<(f64, (i64, String, String, Option<String>, Option<i64>))> = list.iter().filter_map(|item| {
        let t = item.get("track")?;
        let id = t.get("track_id")?.as_i64()?;
        let title = get_str(t, &["track_name"])?.to_string();
        let artist = get_str(t, &["artist_name"]).unwrap_or("").to_string();
        let album = get_str(t, &["album_name"]).map(|a| a.to_string());
        let dur = t.get("track_length").and_then(|x| x.as_i64()).map(|d| d * 1000);
        let r = base_result("musixmatch", &id.to_string(), &title, &artist, album, dur, String::new());
        let sc = score_candidate(input, &r);
        Some((sc, (id, title, artist, r.album.clone(), dur)))
    }).collect();
    cands.sort_by(|a, b| b.0.total_cmp(&a.0));
    let tops: Vec<(i64, String, String, Option<String>, Option<i64>)> = cands.into_iter().take(3).map(|(_, t)| t).collect();
    let details = parallel(tops, |(id, title, artist, album, dur)| {
        let mut url = reqwest::Url::parse(&format!("{}/track.subtitle.get", BASE)).unwrap();
        url.query_pairs_mut()
            .append_pair("track_id", &id.to_string())
            .append_pair("subtitle_format", "lrc")
            .append_pair("app_id", APP_ID)
            .append_pair("usertoken", &token);
        let mut r = base_result("musixmatch", &id.to_string(), &title, &artist, album, dur, String::new());
        if let Ok(resp) = client().get(url).send() {
            if let Ok(v) = resp.json::<Value>() {
                if let Some(body) = v.pointer("/message/body/subtitle/subtitle_body").and_then(|x| x.as_str()) {
                    if body.contains(']') && body.contains(':') { r.lyrics = body.to_string(); }
                }
            }
        }
        r.score = score_candidate(input, &r);
        r
    });
    details.into_iter().filter(|r| !r.lyrics.is_empty()).collect()
}

// ---------------- AMLL（adam 专属词级） ----------------

static AMLL_INDEX: std::sync::OnceLock<Option<Vec<(Vec<String>, String)>>> = std::sync::OnceLock::new();

fn amll_search(input: &LyricsSearchInput, adam_id: i64) -> Vec<LyricsSearchResult> {
    if adam_id <= 0 { return Vec::new() }
    let mut out = Vec::new();
    // 1) am-lyrics 特供版直查
    let url = format!("{}/am-lyrics/{}.ttml", AMLL_RAW_BASE, adam_id);
    if let Ok(resp) = client().get(&url).header("User-Agent", UA).send() {
        if resp.status().is_success() {
            if let Ok(text) = resp.text() {
                let mut r = base_result("amll_ttml", &adam_id.to_string(), &input.title, &input.artist, None, input.duration_ms, text);
                r.has_word_timing = true;
                r.score = score_candidate(input, &r);
                out.push(r);
                return out;
            }
        }
    }
    // 2) 平台索引
    let entries = amll_index();
    let key = adam_id.to_string();
    if let Some(entry) = entries.and_then(|es| es.iter().find(|(ids, _)| ids.contains(&key))) {
        let url = format!("{}/raw-lyrics/{}", AMLL_RAW_BASE, entry.1);
        if let Ok(resp) = client().get(&url).header("User-Agent", UA).send() {
            if resp.status().is_success() {
                if let Ok(text) = resp.text() {
                    let mut r = base_result("amll_ttml", &adam_id.to_string(), &input.title, &input.artist, None, input.duration_ms, text);
                    r.has_word_timing = true;
                    r.score = score_candidate(input, &r);
                    out.push(r);
                }
            }
        }
    }
    out
}

fn amll_index() -> Option<&'static Vec<(Vec<String>, String)>> {
    AMLL_INDEX.get_or_init(|| {
        let url = format!("{}/am-lyrics/index.jsonl", AMLL_RAW_BASE);
        let resp = client().get(&url).header("User-Agent", UA).send().ok()?;
        let text = resp.text().ok()?;
        let mut out: Vec<(Vec<String>, String)> = Vec::new();
        for line in text.lines() {
            if line.trim().is_empty() { continue }
            if let Ok(v) = serde_json::from_str::<Value>(line) {
                let ids: Vec<String> = v.pointer("/metadata").and_then(|m| m.as_array())
                    .and_then(|arr| arr.iter().find(|kv| kv.get(0).and_then(|x| x.as_str()) == Some("appleMusicId")))
                    .and_then(|kv| kv.get(1)).and_then(|x| x.as_array())
                    .and_then(|ids| ids.iter().map(|x| x.as_str().map(|s| s.to_string())).collect::<Option<Vec<_>>>())
                    .unwrap_or_default();
                let raw = get_str(&v, &["rawLyricFile"]).unwrap_or("").to_string();
                if !raw.is_empty() && !ids.is_empty() {
                    out.push((ids, raw));
                }
            }
        }
        crate::store::log(&format!("AMLL am-index loaded: {} entries", out.len()));
        Some(out)
    }).as_ref()
}

// ---------------- volcengine（词级，保底强源） ----------------

fn volcengine_search(input: &LyricsSearchInput) -> Vec<LyricsSearchResult> {
    let c = client();
    let keyword = format!("{} {}", input.title.trim(), input.artist.trim());
    let url = format!("https://api-vehicle.volcengine.com/v2/search/type?keyword={}&search_type=music&limit=20&real_offset=0&search_source=qishui&aid=386088", enc(&keyword));
    let Ok(resp) = c.get(&url).header("User-Agent", UA).send() else { return Vec::new() };
    let Ok(v) = resp.json::<Value>() else { return Vec::new() };
    let Some(list) = v.pointer("/data/list").and_then(|x| x.as_array()) else { return Vec::new() };
    // 时长过滤（8%/5s 容差）→ 时长差升序 → 前 3 拉词级歌词（并发）
    let allow = input.duration_ms.map(|d| ((d as f64 * 0.08).max(5000.0)) as i64);
    let mut cands: Vec<(i64, LyricsSearchResult)> = list.iter().filter_map(|s| {
        let id = get_str(s, &["item_id"])?.to_string();
        let title = get_str(s, &["title"])?.to_string();
        let artist = get_str(s, &["author_info", "name"]).or_else(|| get_str(s, &["author"])).unwrap_or("").to_string();
        let dur = get_i64(s, &["duration"]).map(|d| d * 1000).unwrap_or(0);
        if let Some(allow) = allow {
            if dur > 0 && (dur - allow).abs() > allow { return None }
        }
        let mut r = base_result("volcengine", &id, &title, &artist, None, if dur > 0 { Some(dur) } else { None }, String::new());
        r.album = None;
        // volcengine Track 结构无 album；把封面暂存于 id 后缀（歌词时不使用）
        let diff = if dur > 0 { (dur - input.duration_ms.unwrap_or(0)).abs() } else { 0 };
        Some((diff, r))
    }).collect();
    // 候选保持"选中的可尝试池"，挑 duration>0 的按时长差排序，混入无时长的
    cands.sort_by_key(|(diff, _)| *diff);
    let tops: Vec<LyricsSearchResult> = cands.into_iter().take(3).map(|(_, r)| r).collect();
    let details = parallel(tops, |mut r| {
        let url = format!("https://beta-luna.douyin.com/luna/h5/seo_track?track_id={}&device_platform=web", r.id);
        if let Ok(resp) = client().get(&url).header("User-Agent", UA).send() {
            if let Ok(v) = resp.json::<Value>() {
                if let Some(content) = v.pointer("/lyric/content").and_then(|x| x.as_str()) {
                    if !content.trim().is_empty() {
                        // volcengine 词级格式（[句起始ms,句时长ms]<词偏移ms,词时长ms,0>词）
                        r.lyrics = content.to_string();
                        r.has_word_timing = content.contains('<');
                    }
                }
            }
        }
        r.score = score_candidate(input, &r);
        r
    });
    details.into_iter().filter(|r| !r.lyrics.is_empty()).collect()
}