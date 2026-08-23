# Agents.md · soda-lyrics-mac

> **苏打歌词**（SodaLyrics）：macOS 状态栏歌词助手，适配 **汽水音乐 + Apple Music** 双平台。本文件是给后续 agent（人或 AI）的上下文速查。

## 项目现状

- **阶段**：功能完成并可运行（Swift UI + Rust core + python 代理三进程协同）；Apple Music 双平台已接入（dev 验证中，Apple 板块未正式发版）。
- **当前运行**：`swift-ui/.build/release/soda-lyrics` 启动（自动拉起 Rust core 与 python 代理）。
- **进度**：真实进度来自系统 MediaRemote 的 `CurrentPlaybackDate`（`elC = 墙钟 − CurrentPlaybackDate`），与播放器同步；非自推进。
- **白名单/路由**：`com.soda.music` → 汽水 Provider（volcengine）；`com.apple.Music`（按 iTunesStoreIdentifier>0 判定）→ Apple 多源引擎；其他 App 播放自动清空状态。

## 架构（三进程）

1. **Swift UI**（`swift-ui/`，SwiftPM + AppKit）
   - `SodaLyricsApp.swift`：AppDelegate、NSStatusItem 自绘跑马灯（位图缓存 + CALayer contentsRect GPU 平移，60fps Timer；避开 SwiftUI TimelineView 饿死 runloop 的坑）。面板 30fps 刷新由本类按 popover 可见性节流驱动（关闭时零开销）
   - `LyricsPanel.swift`：NSPopover 面板——封面/歌名/歌手/进度条 + 歌词列表（当前行高亮、词级染色带淡入、spring 自动滚动、候选切换、右上角 ⚙️ 齿轮切设置页）
   - `SettingsView.swift`：设置面板——开机自启（brew services / 自管 LaunchAgent）、更新检测 / 自动更新（GitHub Releases API + 自动代理探测）、开源地址 / 作者 / MIT、退出软件（服务托管时先停服务再退出）
   - `PipelineStore.swift`（库）：spawn Rust core，读 stdout JSONL 行 → @Published 状态
2. **Rust core**（`src/`，`cargo build --release`）
   - `main.rs`：主循环——播放器白名单路由（Soda/Apple）→ 状态合并 → 100ms 快照 JSONL；换歌时发全量歌词
   - `media.rs`：spawn python 代理（ctypes 调 dylib）→ 解析 → 进度合成（elC 优先 → Apple elapsed+ts 外推 → 自推进）；adamID 路由
   - `api.rs`（汽水专属）：volcengine 搜索（limit=20，时长匹配过滤）+ beta-luna `h5_seo_track` 词级歌词
   - `api_apple.rs`：Apple 歌词引擎入口（并发多源 → 打分排序 → 解析选优）+ iTunes 候选
   - `providers.rs`：9 源并发（LRCLIB/Kugou/QQ/网易/Kuwo/AMLL/Migu/Musixmatch/volcengine）——移植自 Lyrics-Plus（MIT）
   - `lyrics_match.rs`：打分匹配（title/artist/album/duration 加权 + normalized_levenshtein + 繁简归一 + Smart 排序）
   - `lyrics_parse.rs`：统一解析（LRC 行级 / YRC / QRC / Enhanced / volcengine 词级 / TTML → LyricLine）
   - `lyrics.rs`：词级解析（全角逗号归一化、词间空格、句级+词级）
   - `store.rs`：采集线程（100ms 帧）+ 歌词加载线程（Provider 分派，汽水流程不受影响）
3. **python 代理**（Apple 签名的 `/usr/bin/python3`，一次 fork 常驻）
   - `resources/libmr_full.dylib`（自写 ObjC 插件，源码 `libmr_full.m`）→ `MRMediaRemoteGetNowPlayingInfo` + `MRMediaRemoteGetNowPlayingApplicationDisplayName`（未用，需 MROrigin）
   - 200ms 循环输出 `{title,artist,dur,rate,elC,elapsed,ts,adamID}`（elapsed=ElapsedTime 快照、ts=Timestamp epoch、adamID=Apple 曲目 id）

## 通信协议（JSONL）

**core → Swift（stdout）**
- 快照：`{"t":"snap","title":...,"artist":...,"pos":...,"dur":...,"playing":...,"track":false}`（100ms 一条；`track:true` = core 检测到「位置回退式切歌」（MediaRemote 元数据滞后时标题未变但位置回退到开头），Swift 须立即清空进加载态）
- 歌词：`{"t":"lyrics","title":...,"artist":...,"credit":...,"track_id":...,"cover":...,"fail":"none|noresult|error","lines":[...]}`（换歌/手动切换时一条；`fail` 区分无结果与接口错误；`cover` 为采用曲目封面 URL 可空）
- 候选：`{"t":"candidates","title":...,"artist":...,"items":[{"id","title","artist","dur","cover"}]}`（自动搜索完成后一条，已时长过滤）

**Swift → core（stdin）**
- `{"t":"pick","id":"..."}`：手动指定候选（同曲目内不再自动降级）
- `{"t":"refresh"}`：清手动选择，重新自动搜索当前曲目

## 关键技术结论（重要，勿推翻）

1. **MediaRemote 只对解释器类进程返回数据**：perl/python 可以，Rust/ObjC CLI 一律 null（已用 dlopen flags/签名/直接链接全矩阵验证）。**采集必须经由解释器代理**（当前 python）——不要尝试把采集搬到 Rust 直连。
   - **2026-08 补充：mediaremoted 对客户端有来源校验**——仅 **Apple 签名**的解释器返回数据：`/usr/bin/python3` ✓；**Homebrew 的 python（无 Apple 签名）实测一律 null**。`media.rs::locate_python()` 必须优先 `/usr/bin/python3`；formula **不得**注入 `SODA_PYTHON` 指向 brew python。
2. **真实进度 = 当前墙钟 − CurrentPlaybackDate**：汽水音乐不上报 `ElapsedTime`（恒 0），但 dict 里有 `CurrentPlaybackDate`（曲目起点）。用这个公式，不要自推进（自推进曾导致误差/乱跳）。
3. **elapsed 恒 0 的原因**：Electron 播放器不向系统更新该键。此前所有「自推进/增量推进/1s 偏移」方案均已废弃——直接信任 elC。
4. **dylib 必须 ad-hoc 签名**：macOS 未签名 dylib 被解释器进程加载时直接杀进程（exit 137）。重建必须跑 `scripts/build-plugin.sh`（含 codesign）。
5. **python 输出必须无缓冲**：spawn 用 `python3 -u`；perl 方案需 `$|=1`（perl 在 core spawn 场景未打通，勿回退 perl）。
6. **播放器路由（双平台）**：`provider_for(app_id)`——`com.soda.music` → Soda（volcengine）；`com.apple.Music` → Apple 多源引擎；**Apple 判定依据**：now-playing dict 的 `kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier`（adam id）> 0（MediaRemote 的 dict 不含 bundle id，`GetNowPlayingApplicationPid` 符号不存在、`DisplayName` 需 MROrigin——勿再走这些路）；app_id 空保持现状 / 其他 App 清空（防抖：仅清一次）。

## 已知坑

- Swift 端 `displayPos` 用 @Published（直接存快照 pos），不要二次叠加自推进（曾导致跳变）。
- `LyricParser.currentLineIndex` 间隙保持上一句（不跳空）；`currentWordIndex` 词间隙保持「最后已开始的词」（返回 nil 会让 UI 用 Int.max 兜底导致整句瞬间铺满——已移除该兜底）。
- 歌词接口偶发无结果（某些歌 0 行）：`status=.noResult` 显示「未找到歌词」。
- 切歌加载态：core 用「位置回退 >20s 到开头」识别 MediaRemote 元数据滞后型切歌（title 未变但已换歌）；Swift 收到 `track:true` 立即清空，状态栏显示「加载歌词…」。
- 面板 30fps 刷新只在 popover 可见时驱动（Store.pulse 由 AppDelegate 节流）；在 LyricsPanel 内挂 Timer 会让 popover 关闭时也重算 AttributeGraph（CPU 10%+）。
- 跑马灯：滚完一圈停在尾部等换行（不要归零重滚，会「闪回句首」）；位图左右 pad=maxWidth 保证 contentsRect 恒在 [0,1]；固定 `withLength: 260`（variableLength 无 image 会塌缩）。
- 父项目 `AGENTS.md` 提到的 `qishui-api` 本地服务与本项目无关（本项目直连上游）。
- **设置面板（SettingsView.swift）**：
  - 当前 Swift toolchain 的 `@State`/`@AppStorage` 宏不可用（SwiftUIMacros 插件缺失，`external macro implementation type ... could not be found`）——状态一律用 `@ObservedObject` + **共享单例**（`Model.shared`/`PanelUI.shared`）；⚠️ `@ObservedObject var x = Model()` 默认值会在每次 body 重建时 new 新实例导致状态重置（表现为「点击无反应」），必须单例或外部注入。
  - URLSession **不走环境变量代理**（只认系统网络偏好）→ 更新检查用 `detectProxyDictionary()`：`https_proxy` 等 env（http/socks5 区分）→ `scutil --proxy` → 直连兜底。
  - `brew services`/`launchctl` 调用必须**后台线程**执行（同步会阻塞主线程/面板弹出），且加超时保护（12s terminate）。
  - 「退出软件」先停服务再退出：brew services `KeepAlive=true` 会在退出后立即拉回进程。
  - 版本号在 `SettingsView.swift` 的 `AppInfo.version` 维护（发版时同步）。

## 开发命令

```bash
bash scripts/build-plugin.sh        # 重建采集插件（编译+签名）
cargo build --release               # Rust core
cd swift-ui && swift build -c release   # Swift UI（release；debug 位图方案 CPU 高）
swift-ui/.build/release/soda-lyrics     # 运行
tail -f /tmp/soda-lyrics-rust.log   # Rust 日志
tail -f /tmp/soda-lyrics-swift.log  # Swift 日志
```

## 分发注意

- **Homebrew**：tap `zephyr-cheung/homebrew-tap`（formula 模板在 `scripts/Formula/soda-lyrics.rb`）。发版：`git tag vX.Y.Z && git push --tags` → 更新 tarball sha256 → 同步 formula 到 tap 仓库。依赖：rust / swift（构建期；运行期无 brew 依赖——采集用系统 python）。
- 安装布局：`bin/soda-lyrics` + `libexec/soda-core` + `libexec/libmr_full.dylib`（全相对定位）。**不注入 SODA_PYTHON**（必须用 Apple 签名的 /usr/bin/python3）。
- python 解释器查找顺序：`SODA_PYTHON`（显式覆盖，慎用）→ `/usr/bin/python3`（Apple 签名，MediaRemote 兼容）→ brew python 兜底。
- 打包 .app 时：swift build 产物 + `target/release/soda-lyrics` + `resources/`（含 dylib 与源码）一起分发；Info.plist 需 `LSUIElement=true`。
- `brew services start soda-lyrics` 开机自启（keep_alive 崩溃自动拉起）。
