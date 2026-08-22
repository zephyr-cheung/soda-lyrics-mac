# Homebrew Formula · soda-lyrics
#
# 汽水音乐 macOS 菜单栏歌词助手（Swift UI 状态栏跑马灯 + Rust core + python 采集代理）
#
# 安装:
#   brew tap zephyr-cheung/homebrew-tap
#   brew install zephyr-cheung/tap/soda-lyrics
#
# 开机自启（登录时自动启动，崩溃自动拉起）:
#   brew services start soda-lyrics
#
# 依赖分析:
#   - rust           构建期：Rust core（reqwest/rustls 静态链接，无系统库依赖）
#   - swift          构建期：Swift UI（brew 独立 toolchain；AppKit/SwiftUI 为系统框架）
#   - python@3.12    运行期：采集代理解释器（MediaRemote 只对解释器类进程返回数据，
#                    Rust 直连一律 null——不可省）；brew services 注入 SODA_PYTHON
#   - libmr_full.dylib 运行期：自写 ObjC 采集插件，随包分发（安装时重新 ad-hoc 签名，
#                    未签名被解释器加载会杀进程 exit 137）
#   - macOS 13+      SwiftUI（AsyncImage 等）

class SodaLyrics < Formula
  desc "汽水音乐 macOS 菜单栏歌词助手（状态栏跑马灯 + 卡拉OK面板）"
  homepage "https://github.com/zephyr-cheung/soda-lyrics-mac"
  url "https://github.com/zephyr-cheung/soda-lyrics-mac/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "c4eb895a0233fe77061f3c01bf936adee007673bf587dd5daf85f21432dde93c"
  license "MIT"

  depends_on :macos => :ventura
  depends_on "rust"
  depends_on "swift"
  depends_on "python@3.12"

  def install
    # 1) Rust core（release，LTO）
    system "cargo", "build", "--release"

    # 2) Swift UI（brew swift toolchain；产物按 SwiftPM 布局 glob 兜底）
    swift = Formula["swift"].opt_prefix/"usr/bin/swift"
    Dir.chdir("swift-ui") do
      system swift, "build", "-c", "release"
    end
    swift_bin = Dir.glob("swift-ui/.build/**/release/soda-lyrics").first
    odie "Swift build output not found" unless swift_bin

    # 3) 安装布局：
    #    <prefix>/bin/soda-lyrics          Swift UI（入口）
    #    <prefix>/libexec/soda-core        Rust core（Swift 经 ../libexec 相对定位）
    #    <prefix>/libexec/libmr_full.dylib 采集插件（core 经「同目录」定位）
    bin.install swift_bin => "soda-lyrics"
    libexec.install "target/release/soda-lyrics" => "soda-core"
    libexec.install "resources/libmr_full.dylib"
    libexec.install "resources/libmr_full.m" # 插件源码（参考）
    system "codesign", "--force", "--sign", "-", libexec/"libmr_full.dylib"
  end

  # 开机自启：brew services start soda-lyrics
  service do
    run [opt_bin/"soda-lyrics"]
    keep_alive true
    process_type :interactive
    environment_variables "SODA_PYTHON" => "#{Formula["python@3.12"].opt_bin}/python3.12"
  end

  def caveats
    <<~EOS
      启动并设置开机自启：
        brew services start soda-lyrics
      停止 / 查看状态：
        brew services stop soda-lyrics
        brew services info soda-lyrics
      手动前台运行（调试）：
        #{opt_bin}/soda-lyrics

      使用前提：
        - 汽水音乐 App 正在播放（仅响应 com.soda.music，其他 App 播放自动清空）
        - 首次使用在 系统设置 → 隐私与安全性 → 辅助功能 勾选本程序
          （读取播放状态授权；若使用 brew 的 python 解释器也需一并授权）
        - 歌词来自 volcengine 公开搜索接口，需要网络
      日志：
        tail -f #{HOMEBREW_PREFIX}/var/log/soda-lyrics-swift.log
        tail -f #{HOMEBREW_PREFIX}/var/log/soda-lyrics-rust.log
    EOS
  end

  test do
    assert_predicate bin/"soda-lyrics", :exist?
    assert_predicate libexec/"soda-core", :exist?
    assert_predicate libexec/"libmr_full.dylib", :exist?
  end
end