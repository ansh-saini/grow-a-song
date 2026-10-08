// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrowCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "GrowCore", targets: ["GrowCore"]),
    ],
    targets: [
        .target(name: "GrowCore"),
        .executableTarget(name: "growsong-render", dependencies: ["GrowCore"]),
        .testTarget(name: "GrowCoreTests", dependencies: ["GrowCore"]),
    ],
    swiftLanguageModes: [.v5]
)
