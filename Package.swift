// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "upd8er",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "upd8er", targets: ["upd8er"]),
        .executable(name: "UpdaterProbe", targets: ["UpdaterProbe"]),
        .executable(name: "BrowserBridge", targets: ["BrowserBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "UpdaterCore", dependencies: ["CSQLite", .product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "upd8er", dependencies: ["UpdaterCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "UpdaterProbe", dependencies: ["UpdaterCore"]),
        .executableTarget(name: "BrowserBridge", dependencies: ["UpdaterCore"]),
        .testTarget(name: "UpdaterCoreTests", dependencies: ["UpdaterCore"])
    ],
    swiftLanguageModes: [.v5]
)
