//! Apple Music 歌词匹配引擎（移植自 Lyrics-Plus，MIT）
//! 并发搜索 → 加权打分（title/artist/album/duration + 繁简归一 + title 过滤）→ Smart 排序

use serde_json::Value;
use strsim::normalized_levenshtein;
use zhhz::{Config, Converter};

#[derive(Debug, Clone, Default)]
pub struct LyricsSearchInput {
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration_ms: Option<i64>,
}

#[derive(Debug, Clone, Default)]
pub struct LyricsSearchResult {
    pub id: String,
    pub provider_id: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration_ms: Option<i64>,
    pub source: String,
    pub synced: bool,
    pub has_translation: bool,
    pub has_word_timing: bool,
    pub has_romanization: bool,
    pub score: f64,
    /// 原始歌词文本（LRC / 词级 LRC / YRC / QRC / TTML 等，由解析器统一识别）
    pub lyrics: String,
}

/// 权重（与 Lyrics-Plus 默认一致：总分 100；duration 容差 12s）
pub struct MatchWeights {
    pub title: u8,
    pub artist: u8,
    pub album: u8,
    pub duration: u8,
}

impl Default for MatchWeights {
    fn default() -> Self {
        Self { title: 39, artist: 36, album: 8, duration: 17 }
    }
}

struct ScoringSettings {
    weights: MatchWeights,
    normalize_chinese: bool,
    title_filter_keywords: Vec<String>,
}

impl Default for ScoringSettings {
    fn default() -> Self {
        Self {
            weights: MatchWeights::default(),
            normalize_chinese: true,
            title_filter_keywords: default_title_filter_keywords(),
        }
    }
}

fn default_title_filter_keywords() -> Vec<String> {
    [
        "feat", "ft", "featuring", "主题曲", "片头曲", "片尾曲", "插曲", "电影", "电视剧", "动画", "游戏", "ost",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

static SIMPLIFIER: std::sync::OnceLock<std::sync::Mutex<Converter>> = std::sync::OnceLock::new();

fn simplify(value: &str) -> String {
    let converter = SIMPLIFIER.get_or_init(|| std::sync::Mutex::new(Converter::new(Config::T2s)));
    if let Ok(c) = converter.lock() {
        c.convert(value)
    } else {
        value.to_string()
    }
}

fn normalize_case(value: &str, normalize_chinese: bool) -> String {
    if normalize_chinese {
        simplify(value).to_lowercase()
    } else {
        value.to_lowercase()
    }
}

fn normalise(value: &str, normalize_chinese: bool) -> String {
    normalize_case(value, normalize_chinese)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// 标题过滤：去掉 "feat."/"ft."/"Live"/括号内容等干扰词（含 ASCII 边界判断）
fn filter_title(value: &str, keywords: &[String]) -> String {
    let mut out = value.to_string();
    for keyword in keywords {
        let needs_boundaries = keyword.chars().all(|c| c.is_ascii_alphanumeric());
        loop {
            let Some((start, _end)) = out.match_indices(keyword).find_map(|(s, m)| {
                let e = s + m.len();
                let boundary = !needs_boundaries
                    || (out[..s].chars().next_back().is_none_or(|c| !c.is_ascii_alphanumeric())
                        && out[e..].chars().next().is_none_or(|c| !c.is_ascii_alphanumeric()));
                boundary.then_some((s, e))
            }) else { break };
            out.replace_range(start.._end, "");
        }
    }
    // 去掉括号内容（(Live) /（Live）等）
    out = out.replace(&['(', '（'][..], "\u{0}").replace(&[')', '）'][..], "\u{0}");
    out.split('\u{0}').collect::<Vec<_>>().join("")
}

/// 候选打分（Lyrics-Plus score_candidate 移植）：
/// title/artist/album 用归一化 Levenshtein；duration 用 12s 线性容差；同步加分 0.04
pub fn score_candidate(input: &LyricsSearchInput, result: &LyricsSearchResult) -> f64 {
    let scoring = ScoringSettings::default();
    let norm = |s: &str| normalise(s, scoring.normalize_chinese);
    let title = normalized_levenshtein(
        &norm(&filter_title(&input.title, &scoring.title_filter_keywords)),
        &norm(&filter_title(&result.title, &scoring.title_filter_keywords)),
    );
    let artist = normalized_levenshtein(&norm(&input.artist), &norm(&result.artist));
    let album = match (&input.album, &result.album) {
        (Some(expected), Some(actual)) => normalized_levenshtein(&norm(expected), &norm(actual)),
        _ => 0.6,
    };
    let duration = match (input.duration_ms, result.duration_ms) {
        (Some(expected), Some(actual)) => {
            let delta = (expected - actual).abs() as f64;
            (1.0 - delta / 12_000.0).clamp(0.0, 1.0)
        }
        _ => 0.6,
    };
    let w = &scoring.weights;
    let total = f64::from(w.title + w.artist + w.album + w.duration);
    (title * f64::from(w.title) / total
        + artist * f64::from(w.artist) / total
        + album * f64::from(w.album) / total
        + duration * f64::from(w.duration) / total
        + if result.synced { 0.04 } else { 0.0 })
        .clamp(0.0, 1.0)
}

/// Smart 排序（Lyrics-Plus）：分数降序 → 分数带（≤0.035 同档）内按源优先级
pub fn sort_smart(results: &mut [LyricsSearchResult], provider_order: &[&str]) {
    results.sort_by(|l, r| r.score.total_cmp(&l.score));
    let mut band_start = 0;
    while band_start < results.len() {
        let band_score = results[band_start].score;
        let len = results[band_start..]
            .iter()
            .take_while(|r| band_score - r.score <= 0.035)
            .count();
        let end = band_start + len;
        results[band_start..end].sort_by(|l, r| {
            let lp = provider_order.iter().position(|p| *p == l.provider_id).unwrap_or(usize::MAX);
            let rp = provider_order.iter().position(|p| *p == r.provider_id).unwrap_or(usize::MAX);
            lp.cmp(&rp).then_with(|| r.score.total_cmp(&l.score))
        });
        band_start = end;
    }
}

/// 去重：同 provider 同 id 去重（保留高分）
pub fn deduplicate(results: &mut Vec<LyricsSearchResult>) {
    let mut seen = std::collections::HashSet::new();
    results.retain(|r| seen.insert(format!("{}|{}", r.provider_id, r.id)));
}

/// 上游 JSON 解析辅助（provider 共用）
pub fn get_str<'a>(v: &'a Value, path: &[&str]) -> Option<&'a str> {
    let mut cur = v;
    for p in path {
        cur = cur.get(*p)?;
    }
    cur.as_str()
}

pub fn get_i64(v: &Value, path: &[&str]) -> Option<i64> {
    let mut cur = v;
    for p in path {
        cur = cur.get(*p)?;
    }
    cur.as_i64()
}