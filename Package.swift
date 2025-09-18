// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macOCR",
    products: [
        .library(
            name: "macOCRCore",
            targets: ["macOCRCore"]
        ),
        .executable(
            name: "macocr",
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
