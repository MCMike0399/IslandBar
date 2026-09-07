// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IslandBar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "IslandBar", targets: ["IslandBar"]),
    ],
    dependencies: [
        .package(path: "Vendor/MediaRemoteAdapter"),
    ],
    targets: [
        .executableTarget(
            name: "IslandBar",
            dependencies: [
                .product(name: "MediaRemoteAdapter", package: "MediaRemoteAdapter"),
            ],
            path: "Sources/IslandBar",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
