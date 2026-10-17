// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iFileSpan",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "iFileSpan", targets: ["iFileSpan"])],
    targets: [
        .target(name: "DeviceBridge", linkerSettings: [.linkedLibrary("dl")]),
        .target(name: "DeviceCore", dependencies: ["DeviceBridge"]),
        .executableTarget(name: "iFileSpan", dependencies: ["DeviceCore"]),
        .testTarget(name: "DeviceCoreTests", dependencies: ["DeviceCore"])
    ]
)
