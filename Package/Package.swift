// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScannerKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ScannerKit", targets: ["ScannerKit"]),
        .executable(name: "scanr-cli", targets: ["scanr-cli"]),
    ],
    targets: [
        .target(name: "ScannerKit"),
        .executableTarget(name: "scanr-cli", dependencies: ["ScannerKit"]),
        .testTarget(name: "ScannerKitTests", dependencies: ["ScannerKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
