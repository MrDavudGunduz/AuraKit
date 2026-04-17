// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
  name: "AuraKit",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .visionOS(.v1),
  ],
  products: [
    // AuraKit library. SPM determines optimal linking strategy automatically.
    .library(
      name: "AuraKit",
      targets: ["AuraKit"]
    )
  ],
  dependencies: [
    // 📚 Apple DocC: For generating professional framework documentation.
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),

    // 🛡️ SwiftLint: Enforces code quality and style standards at build time.
    .package(url: "https://github.com/realm/SwiftLint", from: "0.54.0"),
  ],
  targets: [
    // 📦 Core Library Target
    .target(
      name: "AuraKit",
      dependencies: [],
      path: "Sources/AuraKit",
      plugins: [
        .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")
      ]
    ),
    // 🧪 Test Target — Swift Testing framework
    .testTarget(
      name: "AuraKitTests",
      dependencies: ["AuraKit"],
      path: "Tests/AuraKitTests"
    ),
  ],
  // Swift 6 strict concurrency applied package-wide.
  // Per-target swiftSettings overrides are intentionally omitted — this is the single source of truth.
  swiftLanguageModes: [.v6]
)
