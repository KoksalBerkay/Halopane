// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpatialMath",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "SpatialMath", targets: ["SpatialMath"])],
    targets: [
        .target(name: "SpatialMath"),
        .testTarget(name: "SpatialMathTests", dependencies: ["SpatialMath"])
    ])
