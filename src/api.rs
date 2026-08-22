//! 官方接口：曲目搜索 + 词级歌词（免登录公开接口）
use serde_json::Value;
use std::time::Duration;

const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
/// 网络请求超时：挂起的请求不应永久阻塞歌词加载线程
const HTTP_TIMEOUT: Duration = Duration::from_secs(8);

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub duration_ms: i64,
    /// 封面图 URL（搜索接口返回；可能为空）
    pub cover_url: String,
}

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

/// volcengine 公开搜索（limit 尽量多取，供 UI 手动候选切换；不再做翻唱防御式打分）
pub fn search_tracks(keyword: &str) -> anyhow::Result<Vec<Track>> {
    let url = format!(
        "https://api-vehicle.volcengine.com/v2/search/type?keyword={}&search_type=music&limit=20&real_offset=0&search_source=qishui&aid=386088",
        encode(keyword)
    );
    let client = reqwest::blocking::Client::builder().timeout(HTTP_TIMEOUT).build()?;
    let resp = client.get(&url).header("User-Agent", UA).send()?;
    let v: Value = resp.json()?;
    let mut out = Vec::new();
    if let Some(list) = v.pointer("/data/list").and_then(|x| x.as_array()) {
        for it in list {
            let Some(id) = it.get("item_id").and_then(|x| x.as_str()) else { continue };
            let Some(title) = it.get("title").and_then(|x| x.as_str()) else { continue };
            let artist = match it.pointer("/author_info/name").and_then(|x| x.as_str()) {
                Some(a) => a.to_string(),
                None => it.get("author").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            };
            let dur = it.get("duration").and_then(|x| x.as_f64()).unwrap_or(0.0) as i64 * 1000;
            let cover = it.get("cover_url").and_then(|x| x.as_str()).unwrap_or("").to_string();
            if !title.is_empty() {
                out.push(Track { id: id.to_string(), title: title.to_string(), artist, duration_ms: dur, cover_url: cover });
            }
        }
    }
    Ok(out)
}

/// h5_seo_track：词级歌词（返回解析后的行）
pub fn fetch_lyrics(track_id: &str) -> anyhow::Result<Vec<crate::lyrics::LyricLine>> {
    let url = format!("https://beta-luna.douyin.com/luna/h5/seo_track?track_id={}&device_platform=web", track_id);
    let client = reqwest::blocking::Client::builder().timeout(HTTP_TIMEOUT).build()?;
    let resp = client.get(&url).header("User-Agent", UA).send()?;
    let v: Value = resp.json()?;
    let content = v.pointer("/lyric/content").and_then(|x| x.as_str()).unwrap_or("");
    Ok(crate::lyrics::parse(content))
}
