// swift-tools-version:5.9
import PackageDescription

// WriterCore is plain Foundation (it also builds and tests on Linux);
// the SwiftUI app on top of it is macOS only.
var targets: [Target] = [
    .target(name: "WriterCore"),
    .testTarget(name: "WriterCoreTests", dependencies: ["WriterCore"]),
]
#if os(macOS)
targets.append(.executableTarget(name: "KeyboardWriter", dependencies: ["WriterCore"]))
#endif

let package = Package(
    name: "KeyboardWriter",
    platforms: [.macOS(.v13)],
    targets: targets
)
