// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Yoink",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Yoink",
            resources: [.copy("Sniffer.js")],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        )
    ]
)
