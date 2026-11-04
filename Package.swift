// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyMacOS",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "EasyMacOS", targets: ["PasteMan"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PasteManCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "PasteMan", dependencies: ["PasteManCore"]),
        .testTarget(name: "PasteManCoreTests", dependencies: ["PasteManCore"]),
        .testTarget(name: "PasteManTests", dependencies: ["PasteMan", "PasteManCore"]),
    ]
)
