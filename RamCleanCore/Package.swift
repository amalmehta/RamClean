// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RamCleanCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RamCleanCore", targets: ["RamCleanCore"])],
    targets: [
        .target(name: "RamCleanCore", path: "Sources/RamCleanCore"),
        .testTarget(name: "RamCleanCoreTests", dependencies: ["RamCleanCore"], path: "Tests/RamCleanCoreTests",
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
