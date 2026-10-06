// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TidalDL",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "TidalDL",
            path: "Sources/TidalDL",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        )
    ],
    swiftLanguageModes: [.v5]
)
