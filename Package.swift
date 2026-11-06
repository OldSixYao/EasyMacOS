// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyMacOS",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "EasyMacOS", targets: ["PasteMan"]),
        .executable(name: "FinderExtension", targets: ["FinderExtension"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PasteManCore", dependencies: ["CSQLite"]),
        .executableTarget(
            name: "PasteMan",
            dependencies: ["PasteManCore", "FinderMenuCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .target(name: "FinderMenuCore"),
        .executableTarget(name: "FinderExtension", dependencies: ["FinderMenuCore"]),
        .testTarget(name: "PasteManCoreTests", dependencies: ["PasteManCore"]),
        .testTarget(name: "PasteManTests", dependencies: ["PasteMan", "PasteManCore", "FinderMenuCore"]),
        .testTarget(name: "FinderMenuCoreTests", dependencies: ["FinderMenuCore"]),
        .testTarget(name: "FinderExtensionTests", dependencies: ["FinderExtension", "FinderMenuCore"]),
    ]
)
