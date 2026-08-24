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
#   - 系统 python3   运行期：采集代理解释器（/usr/bin/python3，Apple 签名——
#                    MediaRemote 对客户端有来源校验，仅 Apple 签名的解释器返回数据；
#                    brew 的 python 实测一律 null）。brew 前置要求 CLT，故必然存在)
#   - libmr_full.dylib 运行期：自写 ObjC 采集插件，随包分发（安装时重新 ad-hoc 签名，
#                    未签名被解释器加载会杀进程 exit 137）
#   - macOS 13+      SwiftUI（AsyncImage 等）

class SodaLyrics < Formula
  desc "汽水音乐 macOS 菜单栏歌词助手（状态栏跑马灯 + 卡拉OK面板）"
  homepage "https://github.com/zephyr-cheung/soda-lyrics-mac"
  url "https://github.com/zephyr-cheung/soda-lyrics-mac/archive/refs/tags/v0.3.8.tar.gz"
  sha256 "7629875edb1511ed432ffc72cd3993b4782b3b48753cb5799d2a7dcc5f87962d"
  license "MIT"

  depends_on :macos => :ventura
  depends_on "rust"
  depends_on "swift"

  def install
    # 0) 确保系统 python3：/usr/bin/python3 来自 Xcode Command Line Tools（Apple 签名，
    #    MediaRemote 来源校验所必需；brew python 不可替代）。缺失时自动拉起系统安装。
    unless File.exist?("/usr/bin/python3")
      opoo "系统 python3 (/usr/bin/python3) 缺失 —— 正在触发 Xcode Command Line Tools 安装…"
      system "xcode-select", "--install"
      odie <<~EOS
        /usr/bin/python3 不存在。请等待系统弹出「安装 Command Line Tools」对话框完成安装，
        然后重新运行 brew install zephyr-cheung/tap/soda-lyrics。
        （可用 xcode-select -p 验证：应输出 /Library/Developer/CommandLineTools）
      EOS
    end

    # 0b) cargo 镜像（墙内友好；rsproxy 全球可访问，不影响海外构建）
    (buildpath/".cargo/config.toml").write <<~EOS
      [source.crates-io]
      replace-with = "rsproxy-sparse"
      [source.rsproxy-sparse]
      registry = "sparse+https://rsproxy.cn/index/"
      [net]
      git-fetch-with-cli = true
    EOS

    # 1) Rust core（release，LTO）
    system "cargo", "build", "--release"

    # 2) Swift UI（brew swift toolchain；产物按 SwiftPM 布局 glob 兜底）
    swift = Formula["swift"].opt_bin/"swift"
    # SwiftPM manifest 编译默认走 sandbox-exec；brew 公式沙箱内嵌套沙箱会被拒
    # （sandbox_apply: Operation not permitted），显式禁用沙箱
    ENV["SWIFTPM_DISABLE_SANDBOX"] = "1"
    Dir.chdir("swift-ui") do
      system swift, "build", "-c", "release", "--disable-sandbox"
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
  # 注意：不注入 SODA_PYTHON——必须使用 Apple 签名的 /usr/bin/python3
  # （MediaRemote 来源校验；brew python 返回 null）
  service do
    run [opt_bin/"soda-lyrics"]
    keep_alive true
    process_type :interactive
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
        - 采集使用系统 /usr/bin/python3（Apple 签名；MediaRemote 对客户端有来源校验，
          brew python 会拿到 null——勿用 SODA_PYTHON 覆盖为 brew python）
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