// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bible-data",
    platforms: [.macOS("15.0"), .iOS("27.0")],
    products: [
        .library(name: "BibleFormat", targets: ["BibleFormat"]),
        .executable(name: "bible-pack", targets: ["bible-pack"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "BibleFormat",
            resources: [.copy("Resources/versification")]
        ),
        .executableTarget(
            name: "bible-pack",
            dependencies: [
                "BibleFormat",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "BibleFormatTests", dependencies: ["BibleFormat"]),
        .testTarget(name: "BiblePackTests", dependencies: ["bible-pack", "BibleFormat"]),
    ],
    swiftLanguageModes: [.v6]
)
