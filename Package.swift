// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopBLE",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "WhoopBLE", targets: ["WhoopBLE"])
    ],
    targets: [
        .target(name: "WhoopBLE"),
        .testTarget(name: "WhoopBLETests", dependencies: ["WhoopBLE"])
    ]
)
