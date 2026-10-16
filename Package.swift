// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Yoink",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Yoink",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Sniffer.js")],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "YoinkTests", dependencies: ["Yoink"], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
    ]
)
