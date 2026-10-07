// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TrainingCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "TrainingCore", targets: ["TrainingCore"])],
    targets: [
        .target(name: "TrainingCore", resources: [.process("Resources")]),
        .testTarget(name: "TrainingCoreTests", dependencies: ["TrainingCore"], resources: [.process("Fixtures")])
    ]
)
