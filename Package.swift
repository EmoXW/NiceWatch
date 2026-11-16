// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NiceWatch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NiceWatch", targets: ["NiceWatch"])
    ],
    targets: [
        .executableTarget(
            name: "NiceWatch",
            path: "Sources/NiceWatch"
        ),
        .testTarget(name: "NiceWatchTests", dependencies: ["NiceWatch"])
    ]
)
