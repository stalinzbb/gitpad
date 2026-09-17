// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitPad",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "GitPadCore", targets: ["GitPadCore"])],
    targets: [
        // Foundation-only helpers shared with the iOS companion (Mobile/): markdown
        // parsing, checkbox glyph conversion, conflict-copy naming, remote URL parsing.
        .target(name: "GitPadCore", path: "Sources/GitPadCore"),
        .executableTarget(name: "GitPad", dependencies: ["GitPadCore"], path: "Sources/GitPad"),
    ]
)
