
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EvenG1Kit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "EvenG1Kit", targets: ["EvenG1Kit"]),
    ],
    targets: [
        .target(
            name: "EvenG1Kit",
            dependencies: [],
            path: "Sources/EvenG1Kit"
        ),
        .testTarget(
            name: "EvenG1KitTests",
            dependencies: ["EvenG1Kit"],
            path: "Tests/EvenG1KitTests"
        ),
    ]
)
