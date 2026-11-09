// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LyricsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LyricsKit", targets: ["LyricsKit"])
    ],
    targets: [
        .target(name: "LyricsKit"),
        .testTarget(name: "LyricsKitTests", dependencies: ["LyricsKit"]),
    ]
)
