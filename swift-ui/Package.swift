// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SodaLyricsUI",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SodaLyrics"),
        .executableTarget(name: "soda-lyrics", dependencies: ["SodaLyrics"]),
    ]
)