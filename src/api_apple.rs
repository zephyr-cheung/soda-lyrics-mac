//! Apple Music 板块：iTunes Search 候选 + 歌词引擎（Lyrics-Plus 移植）
//! 歌词获取 = 并发多源搜索 → 打分排序（Smart）→ 依次解析词级/行级文本

use crate::lyrics_match::{deduplicate, sort_smart, LyricsSearchInput, LyricsSearchResult};
use crate::providers::PROVIDER_ORDER;
use crate::lyrics_parse::parse_document;
use serde_json::Value;
use std::time::Duration;

const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const HTTP_TIMEOUT: Duration = Duration::from_secs(8);

fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// Apple Music 歌词获取（Lyrics-Plus 匹配引擎移植）：
/// 并发搜索全部源 → Smart 打分排序 → 候选依次解析（词级优先格式识别）→ 返回最优
pub fn fetch_apple_lyrics(adam_id: i64, title: &str, artist: &str, player_dur_ms: i64) -> anyhow::Result<Vec<crate::lyrics::LyricLine>> {
    let input = LyricsSearchInput {
        title: title.trim().to_string(),
        artist: artist.trim().to_string(),
        album: None,
        duration_ms: (player_dur_ms > 0).then_some(player_dur_ms),
    };
    // 1) 并发收集各源候选
    let mut results: Vec<LyricsSearchResult> = crate::providers::search_all(&input, adam_id);
    deduplicate(&mut results);
    crate::store::log(&format!("apple lyrics candidates: {} raw", results.len()));

    // 2) Smart 排序（分数降序；分数带内按源顺序）
    sort_smart(&mut results, &PROVIDER_ORDER);

    // 3) 依次解析候选（词级优先自动识别），第一个可用即返回
    for r in results.iter().take(12) {
        if r.lyrics.trim().is_empty() { continue }
        if let Some(lines) = parse_document(&r.lyrics) {
            let word = lines.iter().any(|l| !l.words.is_empty());
            crate::store::log(&format!(
                "apple lyrics hit: {} | {} - {} | lines={} word={}",
                r.provider_id, r.title, r.artist, lines.len(), word
            ));
            return Ok(lines);
        }
    }
    crate::store::log(&format!("apple lyrics no result: {} - {}", title, artist));
    Ok(Vec::new())
}

/// iTunes Search：免认证搜索候选（trackId/名称/时长/封面）
pub fn search_itunes(keyword: &str) -> anyhow::Result<Vec<crate::api::Track>> {
    let url = format!(
        "https://itunes.apple.com/search?term={}&entity=song&limit=15",
        encode(keyword)
    );
    let client = reqwest::blocking::Client::builder().timeout(HTTP_TIMEOUT).build()?;
    let resp = client.get(&url).header("User-Agent", UA).send()?;
    let v: Value = resp.json()?;
    let mut out = Vec::new();
    if let Some(arr) = v.get("results").and_then(|x| x.as_array()) {
        for it in arr {
            let Some(id) = it.get("trackId").and_then(|x| x.as_i64()) else { continue };
            let Some(title) = it.get("trackName").and_then(|x| x.as_str()) else { continue };
            let artist = it.get("artistName").and_then(|x| x.as_str()).unwrap_or("").to_string();
            let dur = it.get("trackTimeMillis").and_then(|x| x.as_i64()).unwrap_or(0);
            let cover = it.get("artworkUrl100").and_then(|x| x.as_str())
                .map(|s| s.replace("100x100bb", "300x300bb")).unwrap_or_default();
            if !title.is_empty() {
                out.push(crate::api::Track {
                    id: id.to_string(),
                    title: title.to_string(),
                    artist,
                    duration_ms: dur,
                    cover_url: cover,
                });
            }
        }
    }
    Ok(out)
}