// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotHelix",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HelixKit", targets: ["HelixKit"]),
        .executable(name: "hxdump", targets: ["hxdump"]),
    ],
    targets: [
        .target(name: "HelixKit"),
        .executableTarget(name: "hxdump", dependencies: ["HelixKit"]),
        .testTarget(name: "HelixKitTests", dependencies: ["HelixKit"]),
    ]
)
