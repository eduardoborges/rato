// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MouseHIDpp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MouseHIDpp",
            path: "Sources/MouseHIDpp",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
