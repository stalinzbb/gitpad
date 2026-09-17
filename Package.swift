// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitPad",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "GitPad", path: "Sources/GitPad")]
)
