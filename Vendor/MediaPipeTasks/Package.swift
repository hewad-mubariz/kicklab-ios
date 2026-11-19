// swift-tools-version: 5.8
import PackageDescription

// Pinned to the unmodified SDK used by the qualified Counter V2 builds.
let package = Package(
    name: "MediaPipeTasks",
    platforms: [.iOS(.v15)],
    products: [.library(name: "MediaPipeTasksVision", targets: ["MediaPipeTasksVision", "MediaPipeTasksCommon"])],
    targets: [
        .binaryTarget(name: "MediaPipeTasksCommonBinary",
            url: "https://dl.google.com/cpdc/20261102-135238/MediaPipeTasksCommon-1.2.2.xcframework.zip",
            checksum: "3ed9b3dab1008549c60cfe994a7601a3aa5f45e84dc4542c7996d840230bb47a"),
        .binaryTarget(name: "MediaPipeTaskGraphsBinary",
            url: "https://dl.google.com/cpdc/20261102-135238/MediaPipeTaskGraphs-1.2.2.xcframework.zip",
            checksum: "eaf541888b07d5e748d93c9d1d76ee3d2418281b0bd38973d1818fb2805c4723"),
        .binaryTarget(name: "MediaPipeTasksVision",
            url: "https://dl.google.com/cpdc/20261102-135238/MediaPipeTasksVision-1.2.2.xcframework.zip",
            checksum: "6432a8780c5147211181039b3f9e4e1925b405e0460d43665a5510d0a941b554"),
        .target(name: "MediaPipeTasksCommon",
            dependencies: ["MediaPipeTasksCommonBinary", "MediaPipeTaskGraphsBinary", "MediaPipeTasksVision"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-ObjC"]),
                .linkedLibrary("c++"), .linkedLibrary("sqlite3"),
                .linkedFramework("Accelerate"), .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"), .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"), .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo"), .linkedFramework("QuartzCore"),
                .linkedFramework("Metal"), .linkedFramework("MetalPerformanceShaders")
            ])
    ])
