// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DirtyTestCLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DirtyTestCore", targets: ["DirtyTestCore"]),
        .executable(name: "dirtytest", targets: ["DirtyTestCLI"]),
        .executable(name: "dirtytest-gui", targets: ["DirtyTestGUI"])
    ],
    targets: [
        .target(
            name: "DirtyTestCore",
            path: "Sources/DirtyTestCore",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "DirtyTestCLI",
            dependencies: ["DirtyTestCore"],
            path: "Sources/DirtyTestCLI"
        ),
        .executableTarget(
            name: "DirtyTestGUI",
            dependencies: ["DirtyTestCore"],
            path: "Sources/DirtyTestGUI"
        )
    ]
)
