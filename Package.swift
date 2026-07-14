// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsageMonitor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexUsageMonitor", targets: ["CodexUsageMonitor"])],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.3.2-RELEASE"
        )
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageMonitor",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "CodexUsageMonitorTests",
            dependencies: [
                "CodexUsageMonitor",
                .product(name: "Testing", package: "swift-testing")
            ],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
