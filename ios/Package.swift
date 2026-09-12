// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHAnywhere",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DSHAnywhere", targets: ["DSHAnywhere"]),
    ],
    targets: [
        .target(name: "DSHAnywhere", path: "DSHAnywhere/Core"),
        .testTarget(name: "DSHAnywhereTests", dependencies: ["DSHAnywhere"],
                    path: "DSHAnywhereTests/Core"),
    ]
)
