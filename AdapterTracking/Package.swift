// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AdapterTracking",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "AdapterTracking", targets: ["AdapterTracking"])],
    targets: [
        .target(name: "AdapterTracking"),
        .testTarget(name: "AdapterTrackingTests", dependencies: ["AdapterTracking"])
    ]
)
