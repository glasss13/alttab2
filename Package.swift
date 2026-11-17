// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AltTab2",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "AltTab2", targets: ["AltTab2"])],
    targets: [
        .target(name: "WindowBridge", linkerSettings: [.linkedFramework("ApplicationServices")]),
        .executableTarget(
            name: "AltTab2", dependencies: ["WindowBridge"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit")]),
    ],
    swiftLanguageModes: [.v5]
)
