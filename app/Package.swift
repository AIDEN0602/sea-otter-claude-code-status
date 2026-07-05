// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchOtter",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "NotchOtter",
            path: "Sources/NotchOtter"
        )
    ]
)
