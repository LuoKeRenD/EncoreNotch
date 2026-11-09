// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LyricsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LyricsKit", targets: ["LyricsKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0")
    ],
    targets: [
        .target(name: "LyricsKit", dependencies: ["Yams"]),
        .testTarget(name: "LyricsKitTests", dependencies: ["LyricsKit"]),
    ]
)
