// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macOCR",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "macOCRCore",
            targets: ["macOCRCore"]
        ),
        .executable(
            name: "macOCR",
            targets: ["macOCRCLI"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "macOCRCore",
            dependencies: [],
            path: "Sources/macOCRCore"
        ),
        .executableTarget(
            name: "macOCRCLI",
            dependencies: ["macOCRCore"],
            path: "Sources/macOCRCLI"
        ),
        .testTarget(
            name: "macOCRCoreTests",
            dependencies: ["macOCRCore"],
            path: "Tests/macOCRCoreTests"
        )
    ]
)
