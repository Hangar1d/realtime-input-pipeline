// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RealtimeInputPipeline",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TemporalPipeline", targets: ["TemporalPipeline"]),
        .library(name: "CameraMetadataAdapter", targets: ["CameraMetadataAdapter"]),
        .executable(name: "input-pipeline", targets: ["InputPipelineCLI"]),
    ],
    targets: [
        .target(name: "PipelineCore", publicHeadersPath: "include"),
        .target(name: "TemporalPipeline", dependencies: ["PipelineCore"]),
        .target(name: "CameraMetadataAdapter", dependencies: ["TemporalPipeline"]),
        .executableTarget(name: "InputPipelineCLI", dependencies: ["TemporalPipeline"]),
        .testTarget(name: "TemporalPipelineTests", dependencies: ["TemporalPipeline", "PipelineCore"]),
        .testTarget(name: "FixtureTests", dependencies: ["InputPipelineCLI"]),
        .testTarget(name: "CameraMetadataAdapterTests", dependencies: ["CameraMetadataAdapter", "TemporalPipeline"]),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
