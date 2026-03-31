// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppMoverNative",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "AppMoverNative",
            targets: ["AppMoverNative"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "AppMoverNative"
        ),
    ]
)
