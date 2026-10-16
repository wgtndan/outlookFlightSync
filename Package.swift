// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalendarSync",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CalendarSync", targets: ["CalendarSyncApp"])],
    targets: [
        .target(name: "CalendarSyncCore"),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .executableTarget(name: "CalendarSyncApp", dependencies: ["CalendarSyncCore", "CSQLite"]),
        .testTarget(name: "CalendarSyncCoreTests", dependencies: ["CalendarSyncCore"]),
        .testTarget(name: "CalendarSyncAppTests", dependencies: ["CalendarSyncApp", "CalendarSyncCore", "CSQLite"])
    ]
)
