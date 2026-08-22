# Apple Music 板块 · 接口调研报告

> 目的：把本项目从「仅汽水音乐」扩展到 Apple Music。搜索 + 歌词两个接口的可用性、认证、数据形态与接入建议。
> 方法：全部候选接口已在本机实测（2026-08）；标注 ✅ = 实测可用，⚠️ = 有条件可用，❌ = 不可行。

## 一、搜索接口

### 1. iTunes Search API（推荐 · 零门槛）✅ 实测通过

```
GET https://itunes.apple.com/search
    ?term=<关键词>&entity=song&limit=<N>
```

- **认证**：无（公开接口，无需 token/cookie）
- **返回**：`results[]` 每项含：
  - `trackId`（Apple Music 曲目 ID，可用于歌词/预览关联）
  - `trackName` / `artistName` / `collectionName`
  - `trackTimeMillis`（时长 → 歌词时长匹配）
  - `artworkUrl100`（封面，可替换 `100x100bb` 为 `600x600bb` 等分辨率）
  - `previewUrl`（30s 试听 AAC）
  - `isrc`（国际标准录音编码）
  - `primaryGenreName` / `releaseDate`

- 实测：`term=陈奕迅 好久不见` → 命中 `好久不見`（trackId=1443352467，时长 250493ms）
- 局限：部分新曲/地区差异命中率一般；中文曲名繁简体需自行归一化

### 2. MusicKit Catalog Search（Apple 官方 · 有条件）⚠️

```
GET https://api.music.apple.com/v1/catalog/{storefront}/search?term=<>&types=songs
```

- **认证**：需要 **MusicKit Developer Token**（JWT：`ES256` 签名，Apple Developer 账号 + MusicKit Private Key，免费注册开发者即可签发）；查询 catalog 不需要用户 token
- **返回**：`songs.data[]`：`id`、`attributes: {name, artistName, url, artwork{url}, durationInMillis, isrc, previews[]}`（字段与 iTunes API 同源，质量更高、可直接获得 id）
- 免费层限制：无硬性每日限额（API 本身免费），但 token 需自行维护（签名、过期 refresh）
- **结论**：作为 iTunes API 的补充/备选；首版建议直接用 iTunes API（零门槛）

## 二、歌词接口

### 关键事实：Apple Music 官方 API **不提供歌词**

MusicKit/App Store API 的 songs catalog **没有 lyrics 字段**（Apple 从未开放歌词接口）。Apple Music 客户端内歌词来自 **Musixmatch**（授权）。所以歌词必须走第三方。

### 1. LRCLIB（推荐 · 零门槛）✅ 实测通过

```
GET https://lrclib.net/api/search?track_name=<>&artist_name=<>
  （模糊搜索，返回多候选，含 duration 便于时长匹配）
GET https://lrclib.net/api/get?track_name=<>&artist_name=<>&duration=<秒>
  （精确匹配：时长对齐才返回）
```

- **认证**：无（免费开源歌词库，用户社区维护）
- **返回**：`[{id, trackName, artistName, albumName, duration, instrumental, plainLyrics, syncedLyrics}]`
  - `syncedLyrics`：**LRC 行级**格式 `[mm:ss.xx] 歌词行`（✅ 实测：陈奕迅「好久不见」返回 20 候选，行级时间戳完整）
  - `plainLyrics`：纯文本无时间
- **词级**：❌ **无词级时间戳**（只有行级）——逐字卡拉OK需「行时间戳 + 行内字符均分」降级方案
- 限制：新歌/冷门歌可能缺失；无速率限制（要求礼貌使用，建议单请求+重试）

### 2. Musixmatch（Apple Music 同款歌词源 · 有条件）⚠️

```
GET https://api.musixmatch.com/ws/1.1/matcher.lyrics.get?apikey=<>&q_track=<>&q_artist=<>
```

- **认证**：免费 API key（开发者注册可得）；**词级同步歌词（richsync）需要付费/更高 tier**，免费层仅普通文本歌词
- **结论**：免费层拿不到词级时间戳；词级需付费订阅——**首版不引入**，如未来需要词级可评估付费

### 3. Apple Music 非官方歌词端点 ❌ 不建议

- 社区方案的 `amp-api.music.apple.com/v1/catalog/{cc}/songs/{id}/lyrics` 需要 MusicKit token + 会话 cookie，非公开接口随时可能失效，**不采用**。

### 4. 网易云/QQ 词级接口 ❌ 不建议

- 非官方、需逆向签名参数、有封禁风险、与 Apple Music 曲库 ID 关联成本高——**不采用**。

## 三、接入方案（建议）

### 播放器路由

现架构 `media.rs` 里 `StreamRow.app_id` **硬编码为 `com.soda.music`**（libmr_full.m 未输出真实 bundle id）。扩展需两步：

1. `libmr_full.m`：采集输出真实 `appID`（`MRMediaRemoteGetNowPlayingInfo` dict 含 `kMRMediaRemoteNowPlayingInfoApplicationBundleIdentifier`）→ 需要重建插件 + ad-hoc 签名（`scripts/build-plugin.sh`）
2. core 按 `app_id` 路由歌词 Provider：
   - `com.soda.music` → 现有 volcengine 搜索 + 词级歌词（不动）
   - `com.apple.Music` → **iTunes Search API** 搜索 + **LRCLIB** 歌词

### 歌词数据适配（行级 → 逐字）

LRCLIB 只给行级时间戳。现有面板/跑马灯依赖词级（LyricLine.words）。适配策略：

- **方案 A（首版）**：行级时间戳 + 行内字符均分生成 `words`（每字时长 = 行时长 / 字数）——复用现有 `charUnits` 均分逻辑，观感接近词级卡拉OK
- **方案 B（未来）**：Musixmatch 付费词级直接替换

### 进度与快照

- Apple Music（原生播放器）会上报 `ElapsedTime` 且更新 `CurrentPlaybackDate` → 现有 `elC = now − CurrentPlaybackDate` 公式**无需改动**，暂停/切歌行为一致
- 白名单逻辑升级为「多播放器白名单」（soda + apple.music），其他 App 仍自动清空

### 面板表现

- 搜索候选列表 / 手动切换 / 封面：iTunes API 字段可直接映射现有 `LyricCandidate`（id=trackId、durationMs=trackTimeMillis、coverUrl=artworkUrl100）
- "歌词源"行显示 provider 名（如 "Apple Music · LRCLIB"），与汽水模式视觉一致

## 四、工作量清单

| 项目 | 改动 | 量级 |
|---|---|---|
| 插件输出真实 app_id | `libmr_full.m` + 重签 | 小 |
| core 播放器路由 + 白名单 | `main.rs` / `media.rs` | 小 |
| iTunes 搜索 Provider | 新增 `api_apple.rs` | 小 |
| LRCLIB Provider（LRC 解析 + 行级转词级） | 新增（LRC 解析器可与现有 lyrics.rs 并存） | 中 |
| Swift UI：provider 标识显示 | PipelineStore / LyricsPanel | 小 |
| 联调 + 构建 + 发版 | — | — |

**结论**：零门槛可行（iTunes Search + LRCLIB 均免认证已验证）；Apple Music 官方无歌词接口、词级歌词无法免费获取，首版用「行级时间戳 + 行内均分」实现逐字效果，后续可付费升级词级。