// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "object-reconstruct",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "object-reconstruct",
            path: "Sources/object-reconstruct"
        )
    ]
)
