// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "AuraKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1)
    ],
    products: [
        // AuraKit kütüphanesi. Statik/Dinamik ayrımı SPM'in otomatik kararına bırakılmıştır.
        .library(
            name: "AuraKit",
            targets: ["AuraKit"]
        ),
    ],
    dependencies: [
        // 📚 Apple DocC: Profesyonel framework dokümantasyonu oluşturmak için
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
        
        // 🛡️ SwiftLint: Kod kalitesini ve stil standartlarını zorunlu kılmak için
        .package(url: "https://github.com/realm/SwiftLint", from: "0.54.0")
    ],
    targets: [
        // 📦 Çekirdek Kütüphane Hedefi
        .target(
            name: "AuraKit",
            dependencies: [],
            path: "Sources/AuraKit",
            swiftSettings: [
                // Swift 6'nın Strict Concurrency kurallarını native olarak aktif ediyoruz.
                .swiftLanguageMode(.v6)
            ],
            plugins: [
                // Derleme aşamasında kod standartlarını denetleyen eklenti
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")
            ]
        ),
        // 🧪 Test Hedefi (Swift Testing kullanılacak)
        .testTarget(
            name: "AuraKitTests",
            dependencies: ["AuraKit"],
            path: "Tests/AuraKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
