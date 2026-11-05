// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyMacOS",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "EasyMacOS", targets: ["PasteMan"]),
        .executable(name: "FinderExtension", targets: ["FinderExtension"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PasteManCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PasteMan", dependencies: ["PasteManCore", "FinderMenuCore"]),
        .target(name: "FinderMenuCore"),
        .executableTarget(name: "FinderExtension", dependencies: ["FinderMenuCore"]),
        .testTarget(name: "PasteManCoreTests", dependencies: ["PasteManCore"]),
        .testTarget(name: "PasteManTests", dependencies: ["PasteMan", "PasteManCore", "FinderMenuCore"]),
        .testTarget(name: "FinderMenuCoreTests", dependencies: ["FinderMenuCore"]),
        .testTarget(name: "FinderExtensionTests", dependencies: ["FinderExtension", "FinderMenuCore"]),
    ]
)
