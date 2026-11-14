// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MFConnectKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MFConnectCore", targets: ["MFConnectCore"]),
        .library(name: "MFConnectServer", targets: ["MFConnectServer"]),
        .library(name: "MFConnectClient", targets: ["MFConnectClient"]),
        .executable(name: "mfconnect-devserver", targets: ["mfconnect-devserver"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
    ],
    targets: [
        // 資料模型、API 契約；所有平台共用，不依賴任何第三方套件。
        .target(name: "MFConnectCore"),
        // 僅 macOS 使用：HTTP 伺服器、佇列、列印、儲存。
        // 也能在 Linux 編譯（macOS 專屬 API 都以 canImport 隔開），方便在 CI 上跑測試。
        .target(
            name: "MFConnectServer",
            dependencies: [
                "MFConnectCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        // 給 iOS / iPadOS 主 App 與 Share Extension 使用：上傳用戶端、Bonjour 探索、共用設定。
        .target(name: "MFConnectClient", dependencies: ["MFConnectCore"]),
        // 開發用：不需 Xcode，以試跑模式啟動伺服器（swift run mfconnect-devserver）。
        .executableTarget(name: "mfconnect-devserver", dependencies: ["MFConnectServer", "MFConnectCore"]),
        .testTarget(name: "MFConnectCoreTests", dependencies: ["MFConnectCore"]),
        .testTarget(
            name: "MFConnectServerTests",
            dependencies: [
                "MFConnectServer", "MFConnectCore", "MFConnectClient",
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
