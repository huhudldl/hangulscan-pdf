// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HangulScan",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "HangulScan",
            path: "Sources/HangulScan"
        )
    ]
)
