// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "trolley",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CGhostty",
            path: "Sources/CGhostty"
        ),
        .executableTarget(
            name: "trolley",
            dependencies: ["CGhostty"],
            path: "Sources",
            exclude: ["CGhostty"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
