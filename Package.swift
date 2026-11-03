// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fetchly",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fetchly", targets: ["FetcherApp"]),
        .executable(name: "fetchcli", targets: ["fetchcli"]),
    ],
    targets: [
        .target(name: "FetcherCore"),
        .executableTarget(name: "FetcherApp", dependencies: ["FetcherCore"]),
        .executableTarget(name: "fetchcli", dependencies: ["FetcherCore"]),
        .testTarget(name: "FetcherCoreTests", dependencies: ["FetcherCore"]),
    ]
)
