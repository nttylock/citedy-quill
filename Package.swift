// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "quill",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // FluidAudio / Parakeet deliberately NOT linked: co-loading it in this
        // binary was observed to leave NSStatusItem with a height-0 frame on
        // macOS 26 (menu bar icon invisible). On-device transcription can be
        // reintroduced via a separate helper process later.
    ],
    targets: [
        .executableTarget(
            name: "quill",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist", "Transcription/ParakeetEngine.swift"]
        ),
    ]
)
