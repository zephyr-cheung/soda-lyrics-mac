# Agents.md · soda-lyrics-mac

> 汽水音乐 macOS 菜单栏歌词助手：状态栏滚动歌词 + 卡拉OK面板。本文件是给后续 agent（人或 AI）的上下文速查。

## 项目现状

- **阶段**：功能完成并可运行（Swift UI + Rust core + python 代理三进程协同）。
- **当前运行**：`swift-ui/.build/debug/soda-lyrics` 启动（自动拉起 Rust core 与 python 代理）。
- **进度**：真实进度来自系统 MediaRemote 的 `CurrentPlaybackDate`（`elC = 墙钟 − CurrentPlaybackDate`），与播放器同步；非自推进。
- **白名单**：只响应 `com.soda.music`；其他 App 播放自动清空状态。

## 架构（三进程）

1. **Swift UI**（`swift-ui/`，SwiftPM + AppKit）
   - `SodaLyricsApp.swift`：AppDelegate、NSStatusItem 自绘跑马灯（0.1s Timer 重绘，避开 SwiftUI TimelineView 饿死 runloop 的坑）
   - `LyricsPanel.swift`：NSPopover 面板——歌名/歌手/进度条 + 歌词列表（当前行高亮、词级染色、自动滚动）
   - `PipelineStore.swift`（库）：spawn Rust core，读 stdout JSONL 行 → @Published 状态
2. **Rust core**（`src/`，`cargo build --release`）
   - `main.rs`：主循环——白名单过滤 → 状态合并 → 100ms 快照 JSONL；换歌时发全量歌词
   - `media.rs`：spawn python 代理（ctypes 调 dylib）→ 解析 → 真实进度合成（elC）
   - `api.rs`：volcengine 搜索（limit=20，时长匹配过滤剔除不一致候选）+ beta-luna `h5_seo_track` 词级歌词
   - `lyrics.rs`：词级解析（全角逗号归一化、词间空格、句级+词级）
   - `store.rs`：采集线程（100ms 帧）+ 歌词加载线程
3. **python 代理**（macOS 自带 `/usr/bin/python3`，一次 fork 常驻）
   - `resources/libmr_full.dylib`（自写 ObjC 插件，源码 `libmr_full.m`）→ `MRMediaRemoteGetNowPlayingInfo`
   - 200ms 循环输出 `{title,artist,dur,rate,elC}`

## 通信协议（JSONL）

**core → Swift（stdout）**
- 快照：`{"t":"snap","title":...,"artist":...,"pos":...,"dur":...,"playing":...}`（100ms 一条）
- 歌词：`{"t":"lyrics","title":...,"artist":...,"credit":...,"track_id":...,"fail":"none|noresult|error","lines":[...]}`（换歌/手动切换时一条；`fail` 区分无结果与接口错误）
- 候选：`{"t":"candidates","title":...,"artist":...,"items":[{"id","title","artist","dur"}]}`（自动搜索完成后一条，已时长过滤）

**Swift → core（stdin）**
- `{"t":"pick","id":"..."}`：手动指定候选（同曲目内不再自动降级）
- `{"t":"refresh"}`：清手动选择，重新自动搜索当前曲目

## 关键技术结论（重要，勿推翻）

1. **MediaRemote 只对解释器类进程返回数据**：perl/python 可以，Rust/ObjC CLI 一律 null（已用 dlopen flags/签名/直接链接全矩阵验证）。**采集必须经由解释器代理**（当前 python）——不要尝试把采集搬到 Rust 直连。
2. **真实进度 = 当前墙钟 − CurrentPlaybackDate**：汽水音乐不上报 `ElapsedTime`（恒 0），但 dict 里有 `CurrentPlaybackDate`（曲目起点）。用这个公式，不要自推进（自推进曾导致误差/乱跳）。
3. **elapsed 恒 0 的原因**：Electron 播放器不向系统更新该键。此前所有「自推进/增量推进/1s 偏移」方案均已废弃——直接信任 elC。
4. **dylib 必须 ad-hoc 签名**：macOS 未签名 dylib 被解释器进程加载时直接杀进程（exit 137）。重建必须跑 `scripts/build-plugin.sh`（含 codesign）。
5. **python 输出必须无缓冲**：spawn 用 `python3 -u`；perl 方案需 `$|=1`（perl 在 core spawn 场景未打通，勿回退 perl）。
6. **只响应汽水音乐**：`main.rs` 三段式——白名单正常 / app_id 空保持现状 / 其他 App 清空（防抖：仅清一次）。

## 已知坑

- Swift 端 `displayPos` 用 @Published（直接存快照 pos），不要二次叠加自推进（曾导致跳变）。
- `LyricParser.currentLineIndex` 间隙保持上一句（不跳空）。
- 歌词接口偶发无结果（某些歌 0 行）：`status=.noResult` 显示「未找到歌词」。
- 父项目 `AGENTS.md` 提到的 `qishui-api` 本地服务与本项目无关（本项目直连上游）。

## 开发命令

```bash
bash scripts/build-plugin.sh        # 重建采集插件（编译+签名）
cargo build --release               # Rust core
cd swift-ui && swift build          # Swift UI
swift-ui/.build/debug/soda-lyrics   # 运行
tail -f /tmp/soda-lyrics-rust.log   # Rust 日志
tail -f /tmp/soda-lyrics-swift.log  # Swift 日志
```

## 分发注意

- python3 依赖 Xcode CommandLineTools（新 Mac 可能没有）；perl 是 macOS 出厂自带（备用，待解 core spawn 卡住问题）。
- 打包 .app 时：swift build 产物 + `target/release/soda-lyrics` + `resources/`（含 dylib 与源码）一起分发；Info.plist 需 `LSUIElement=true`。
