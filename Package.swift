// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RemarkableFeeds",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RemarkableFeeds")
    ]
)
