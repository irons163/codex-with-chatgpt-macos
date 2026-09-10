// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexWithChatGPT",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "c2c", targets: ["c2c"]), .library(name: "C2CCore", targets: ["C2CCore"])],
    targets: [
        .target(name: "C2CCore"),
        .executableTarget(name: "c2c", dependencies: ["C2CCore"]),
        .testTarget(name: "C2CCoreTests", dependencies: ["C2CCore"])
    ]
)
