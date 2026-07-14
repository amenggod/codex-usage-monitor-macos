// swift-tools-version: 6.0
import Foundation
import PackageDescription

let commandLineToolsTestingLibraryDirectory = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let commandLineToolsTestingInteropLibrary = "\(commandLineToolsTestingLibraryDirectory)/lib_TestingInterop.dylib"
let testingLinkerSettings: [LinkerSetting] = FileManager.default.fileExists(
    atPath: commandLineToolsTestingInteropLibrary
) ? [
    .unsafeFlags(
        [
            "-L\(commandLineToolsTestingLibraryDirectory)",
            "-Xlinker", "-rpath",
            "-Xlinker", commandLineToolsTestingLibraryDirectory
        ],
        .when(platforms: [.macOS])
    )
] : []

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
            resources: [.copy("Fixtures")],
            linkerSettings: testingLinkerSettings
        )
    ],
    swiftLanguageModes: [.v6]
)
