// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rato",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Rato",
            path: "Sources/Rato",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
