//! 词级歌词模型与解析（移植自 Swift 版 LyricParser）

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Word {
    pub offset_ms: i64,
    pub dur_ms: i64,
    pub text: String,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct LyricLine {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
    pub words: Vec<Word>,
}

/// 解析上游词级歌词串：`[句起始ms,句时长ms]<词偏移ms,词时长ms,0>词文本<...>... [下句...]`
pub fn parse(raw_input: &str) -> Vec<LyricLine> {
    // 归一化：全角逗号 -> 半角
    let input: String = raw_input.replace("，", ",");
    let chars: Vec<char> = input.chars().collect();
    let n = chars.len();
    let mut i = 0usize;
    let mut lines: Vec<LyricLine> = Vec::new();

    while i < n {
        let c = chars[i];
        if c.is_whitespace() || c == ',' {
            i += 1;
            continue;
        }
        if c == '[' {
            // 找 ]
            let mut close = i + 1;
            while close < n && chars[close] != ']' { close += 1 }
            if close < n {
                let inner: String = chars[i + 1..close].iter().collect();
                let parts: Vec<&str> = inner.split(',').collect();
                if parts.len() >= 2 {
                    if let (Ok(start), Ok(dur)) = (parts[0].trim().parse::<i64>(), parts[1].trim().parse::<i64>()) {
                        let mut words: Vec<Word> = Vec::new();
                        let mut j = close + 1;
                        let mut ok = true;
                        while j < n {
                            if chars[j].is_whitespace() || chars[j] == ',' {
                                j += 1;
                                continue;
                            }
                            if chars[j] == '[' { break }   // 句边界：本句正常结束
                            if chars[j] != '<' { ok = false; break }
                            // <off,dur,0>
                            let mut g = j + 1;
                            while g < n && chars[g] != '>' { g += 1 }
                            if g >= n { ok = false; break }
                            let ginner: String = chars[j + 1..g].iter().collect();
                            let gparts: Vec<&str> = ginner.split(',').collect();
                            if gparts.len() < 2 { ok = false; break }
                            let (off, d) = match (gparts[0].trim().parse::<i64>(), gparts[1].trim().parse::<i64>()) {
                                (Ok(a), Ok(b)) => (a, b),
                                _ => { ok = false; break }
                            };
                            // 词文本：到下一个 < 或句边界 [ 为止
                            let mut k = g + 1;
                            while k < n && chars[k] != '<' && chars[k] != '[' { k += 1 }
                            let wtext: String = chars[g + 1..k].iter().collect::<String>().trim().to_string();
                            if wtext.is_empty() { ok = false; break }
                            words.push(Word { offset_ms: off, dur_ms: d, text: wtext });
                            j = k;
                        }
                        if ok && !words.is_empty() {
                            let text = join_words(&words);
                            lines.push(LyricLine { start_ms: start, end_ms: start + dur, text, words });
                        }
                        i = close + 1;
                        continue;
                    }
                }
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    lines
}

/// 词拼接：非 CJK 相邻边界补空格
pub fn join_words(words: &[Word]) -> String {
    let mut out = String::new();
    for (i, w) in words.iter().enumerate() {
        if i > 0 {
            let prev_last = words[i - 1].text.chars().last().unwrap_or(' ');
            let cur_first = w.text.chars().next().unwrap_or(' ');
            let both_cjk = is_ideographic(prev_last) && is_ideographic(cur_first);
            if !both_cjk { out.push(' '); }
        }
        out.push_str(&w.text);
    }
    out.trim().to_string()
}

pub fn is_ideographic(c: char) -> bool {
    // CJK 统一汉字区（简化判断：U+4E00..U+9FFF）
    ('一'..='鿿').contains(&c)
}

/// 给定当前毫秒，返回所在句下标（二分；间隙保持上一句）
pub fn current_line_index(lines: &[LyricLine], pos_ms: i64) -> Option<usize> {
    if lines.is_empty() { return None }
    let mut lo = 0usize;
    let mut hi = lines.len() - 1;
    while lo <= hi {
        let mid = (lo + hi) / 2;
        if lines[mid].start_ms <= pos_ms { lo = mid + 1 } else { hi = mid.saturating_sub(1) }
    }
    if hi == usize::MAX { None } else { Some(hi) }
}

/// 当前词下标（卡拉OK）
pub fn current_word_index(line: &LyricLine, pos_ms: i64) -> Option<usize> {
    let rel = pos_ms - line.start_ms;
    line.words.iter().position(|w| rel >= w.offset_ms && rel < w.offset_ms + w.dur_ms)
}