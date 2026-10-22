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
    // Command plugin only — never runs as part of a consumer's build.
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),

    // NOTE: SwiftLint is intentionally NOT a package dependency.
    // SPM resolves plugin dependencies for every consumer of this library,
    // which would force SwiftLint + SwiftSyntax downloads and a
    // "Trust & Enable Plugin" prompt on host applications. Linting runs as a
    // standalone tool in CI (`swiftlint lint --strict`) using `.swiftlint.yml`.
  ],
  targets: [
    // 📦 Core Library Target
    .target(
      name: "AuraKit",
      dependencies: [],
      path: "Sources/AuraKit",
      resources: [
        .process("PrivacyInfo.xcprivacy")
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
