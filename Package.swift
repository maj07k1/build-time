// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BuildTime",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BuildTime", path: "Sources/BuildTime"),
        .testTarget(name: "BuildTimeTests", dependencies: ["BuildTime"], path: "Tests/BuildTimeTests"),
    ]
)
