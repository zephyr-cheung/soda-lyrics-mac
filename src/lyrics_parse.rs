//! Apple 歌词文本统一解析：能识别 LRC（行级）、Enhanced LRC（词级 <t>词）、
//! YRC（网易词级）、QRC（QQ 词级）、volcengine 词级格式与 TTML（Apple 词级），
//! 全部归一为 LyricLine（words 词级时间戳，面板逐字卡拉OK直接可用）

use crate::lyrics::{LyricLine, Word};

/// 尝试解析任意歌词文本：按词级优先探测（platform yrc/qrc → volcengine → enhanced → ttml → lrc）
pub fn parse_document(raw: &str) -> Option<Vec<LyricLine>> {
    let text = raw.trim();
    if text.is_empty() { return None }
    if let Some(lines) = parse_platform_or_lrc(text) {
        return Some(lines);
    }
    if let Some(lines) = parse_ttml(text) {
        return Some(lines);
    }
    None
}

/// 统一出处：解析为词级行或回退行级 LRC（同一扫描实现）
fn parse_platform_or_lrc(raw: &str) -> Option<Vec<LyricLine>> {
    let mut rows: Vec<(i64, i64, String, Vec<Word>)> = Vec::new(); // (start, end, text, words)
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() { continue }
        if let Some(after) = line.strip_prefix('[') {
            let Some(close) = after.find(']') else { continue };
            let content = &after[close + 1..];
            let tag = &after[..close];
            // LRC 时间戳 [mm:ss(.xx)]
            if let Some(ms) = lrc_timestamp_ms(tag) {
                let text = content.trim();
                if !text.is_empty() && !is_metadata_line(text) {
                    rows.push((ms, -1, text.to_string(), Vec::new()));
                }
                continue;
            }
            // 平台词级 [start,dur]
            let nums: Vec<i64> = tag.split(',').filter_map(|v| v.trim().parse().ok()).collect();
            if nums.len() == 2 {
                let start = nums[0];
                let dur = nums[1];
                let content = content.trim();
                let words = if content.starts_with('(') {
                    parse_yrc_words(content)  // (off,dur,type)词
                } else if content.starts_with('<') {
                    parse_volc_words(content) // <off,dur,0>词
                } else {
                    parse_qrc_words(content)  // 词(off,dur)
                };
                if !words.is_empty() {
                    let text: String = words.iter().map(|w| w.text.clone()).collect();
                    rows.push((start, start + dur.max(0), text, words));
                } else if !content.is_empty() {
                    rows.push((start, start + dur.max(0), content.to_string(), Vec::new()));
                }
                continue;
            }
        }
        // 增强 LRC（行内 <t>词）——仅在行首非 [] 时
        if line.contains('<') && !line.starts_with('[') {
            if let Some((text, words)) = parse_enhanced_line(line) {
                if !words.is_empty() {
                    rows.push((0, 0, text, words));
                }
            }
        }
    }
    if rows.is_empty() { return None }
    rows.sort_by_key(|r| r.0);
    // 推导 end 与行文本；enhanced（无起始时间）行丢弃（需行时间）
    let mut out: Vec<LyricLine> = Vec::new();
        for (i, (start, end, text, words)) in rows.iter().enumerate() {
        if *start < 0 { continue }
        let e = if *end > 0 { *end } else {
            if i + 1 < rows.len() { rows[i + 1].0 } else { *start + 8000 }
        };
        if e <= *start { continue }
        if !words.is_empty() {
            out.push(LyricLine { start_ms: *start, end_ms: e, text: text.trim().to_string(), words: words.clone() });
        } else {
            // 行级歌词（非词级）：不带 words → 面板当前行整行高亮（不做假逐字扫描）
            out.push(LyricLine { start_ms: *start, end_ms: e, text: text.trim().to_string(), words: Vec::new() });
        }
    }
    if out.is_empty() { None } else { Some(out) }
}

/// [mm:ss(.xx)] → ms
fn lrc_timestamp_ms(tag: &str) -> Option<i64> {
    let (m, s) = tag.split_once(':')?;
    let mm: f64 = m.trim().parse().ok()?;
    let ss: f64 = s.trim().parse().ok()?;
    if mm < 0.0 || ss < 0.0 { return None }
    Some((mm * 60.0 * 1000.0 + ss * 1000.0) as i64)
}

fn is_metadata_line(text: &str) -> bool {
    text.starts_with("ti:") || text.starts_with("ar:") || text.starts_with("al:")
        || text.starts_with("by:") || text.starts_with("offset:") || text.starts_with("length:")
        || text.starts_with("[lyrics-plus:")
}

/// YRC（网易词级）：(开始ms, 时长ms, 类型)词
fn parse_yrc_words(content: &str) -> Vec<Word> {
    let mut words = Vec::new();
    let mut rest = content;
    while let Some(open) = rest.find('(') {
        let Some(close_rel) = rest[open + 1..].find(')') else { break };
        let close = open + 1 + close_rel;
        let nums: Vec<i64> = rest[open + 1..close].split(',').filter_map(|v| v.trim().parse().ok()).collect();
        let text_start = close + 1;
        let text_end = rest[text_start..].find('(').map(|v| text_start + v).unwrap_or(rest.len());
        let text = rest[text_start..text_end].to_string();
        if nums.len() >= 2 && !text.is_empty() {
            words.push(Word { offset_ms: nums[0], dur_ms: nums[1].max(1), text });
        }
        if text_end >= rest.len() { break }
        rest = &rest[text_end..];
    }
    words
}

/// volcengine 词级：<偏移ms,时长ms,0>词
fn parse_volc_words(content: &str) -> Vec<Word> {
    let mut words = Vec::new();
    let mut rest = content;
    while let Some(open) = rest.find('<') {
        let Some(close_rel) = rest[open + 1..].find('>') else { break };
        let close = open + 1 + close_rel;
        let nums: Vec<i64> = rest[open + 1..close].split(',').filter_map(|v| v.trim().parse().ok()).collect();
        let text_start = close + 1;
        let text_end = rest[text_start..].find('<').map(|v| text_start + v).unwrap_or(rest.len());
        let text = rest[text_start..text_end].trim().to_string();
        if nums.len() >= 2 && !text.is_empty() {
            words.push(Word { offset_ms: nums[0], dur_ms: nums[1].max(1), text });
        }
        if text_end >= rest.len() { break }
        rest = &rest[text_end..];
    }
    words
}

/// QRC（QQ 词级）：词(偏移ms,时长ms)
fn parse_qrc_words(content: &str) -> Vec<Word> {
    let mut words = Vec::new();
    let mut rest = content;
    while let Some(open) = rest.find('(') {
        let Some(close_rel) = rest[open + 1..].find(')') else { break };
        let close = open + 1 + close_rel;
        let nums: Vec<i64> = rest[open + 1..close].split(',').filter_map(|v| v.trim().parse().ok()).collect();
        let text = rest[..open].to_string();
        if nums.len() >= 2 && !text.is_empty() {
            words.push(Word { offset_ms: nums[0], dur_ms: nums[1].max(1), text });
        }
        rest = &rest[close + 1..];
    }
    words
}

/// Enhanced LRC：行尾词级 <开始ms>词（一行一次，行起始需由外部时间戳提供）
fn parse_enhanced_line(content: &str) -> Option<(String, Vec<Word>)> {
    let mut words = Vec::new();
    let mut rest = content;
    while let Some(open) = rest.find('<') {
        let Some(close_rel) = rest[open + 1..].find('>') else { break };
        let close = open + 1 + close_rel;
        let start: i64 = rest[open + 1..close].trim().parse().ok()?;
        let text_start = close + 1;
        let text_end = rest[text_start..].find('<').map(|v| text_start + v).unwrap_or(rest.len());
        let text = rest[text_start..text_end].trim().to_string();
        if !text.is_empty() {
            words.push(Word { offset_ms: start, dur_ms: 1, text });
        }
        if text_end >= rest.len() { break }
        rest = &rest[text_end..];
    }
    if words.is_empty() { return None }
    let text: String = words.iter().map(|w| w.text.clone()).collect();
    Some((text, words))
}

/// TTML（Apple 词级：<p begin="秒" end="秒"><span begin="秒" end="秒">词</span>…）
pub fn parse_ttml(raw: &str) -> Option<Vec<LyricLine>> {
    let body_start = raw.find("<body").unwrap_or(0);
    let body = &raw[body_start..];
    let mut out: Vec<LyricLine> = Vec::new();
    let mut rest = body;
    while let Some(ps) = rest.find("<p ") {
        let Some(pend) = rest[ps..].find("</p>") else { break };
        let pseg = &rest[ps..ps + pend];
        let (Some(begin), Some(end)) = (attr_secs(pseg, "begin"), attr_secs(pseg, "end")) else {
            rest = &rest[ps + 4..];
            continue;
        };
        if end <= begin { rest = &rest[ps + 4..]; continue }
        let mut words: Vec<Word> = Vec::new();
        let mut plain = String::new();
        let inner_start = pseg.find('>').map(|i| i + 1).unwrap_or(0);
        let inner = &pseg[inner_start..];
        let mut srest = inner;
        while let Some(ss) = srest.find("<span") {
            let Some(sep) = srest[ss..].find("</span>") else { break };
            let sseg = &srest[ss..ss + sep];
            let sc = sseg.find('>').map(|i| i + 1).unwrap_or(0);
            let stext = &sseg[sc..];
            let role = sseg.contains("x-translation") || sseg.contains("x-roman");
            let txt = decode_entities(stext.trim());
            if !role && !txt.is_empty() {
                plain.push_str(&txt);
                if let (Some(b), Some(e)) = (attr_secs(sseg, "begin"), attr_secs(sseg, "end")) {
                    if e > b {
                        words.push(Word { offset_ms: (b * 1000.0) as i64, dur_ms: ((e - b) * 1000.0) as i64, text: txt });
                    }
                }
            }
            srest = &srest[ss + sep + 7..];
        }
        let plain_lead = decode_entities(&inner[..inner.find("<span").unwrap_or(inner.len())]);
        if !plain_lead.trim().is_empty() && words.is_empty() {
            plain = plain_lead;
        }
        if plain.trim().is_empty() { rest = &rest[ps + 4..]; continue }
        if words.is_empty() {
            // 行级退化：不带 words（面板整行高亮）
            words = Vec::new();
        }
        out.push(LyricLine {
            start_ms: (begin * 1000.0) as i64,
            end_ms: (end * 1000.0) as i64,
            text: plain.trim().to_string(),
            words,
        });
        rest = &rest[ps + pend + 4..];
    }
    out.sort_by_key(|l| l.start_ms);
    if out.is_empty() { None } else { Some(out) }
}

fn attr_secs(seg: &str, name: &str) -> Option<f64> {
    let key = format!("{}=\"", name);
    let i = seg.find(&key)?;
    let vstart = i + key.len();
    let vend = seg[vstart..].find('"')? + vstart;
    seg[vstart..vend].parse::<f64>().ok()
}

fn decode_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let rest = &s[i..];
        if rest.starts_with("&amp;") { out.push('&'); i += 5; continue }
        if rest.starts_with("&lt;") { out.push('<'); i += 4; continue }
        if rest.starts_with("&gt;") { out.push('>'); i += 4; continue }
        if rest.starts_with("&quot;") { out.push('"'); i += 6; continue }
        if rest.starts_with("&#39;") { out.push('\''); i += 5; continue }
        let ch = s[i..].chars().next().unwrap_or(' ');
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}
