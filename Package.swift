// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-rtl2832u",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RTL2832U", targets: ["RTL2832U"]),
    ],
    targets: [
        .target(
            name: "RTL2832U",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RTL2832UTests",
            dependencies: ["RTL2832U"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
