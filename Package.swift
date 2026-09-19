// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowZones",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "WindowZones", targets: ["WindowZones"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "Geometry"),
        .target(name: "LayoutStorage", dependencies: ["Geometry"]),
        .executableTarget(name: "WindowZones", dependencies: ["Geometry", "LayoutStorage", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry"]),
        .testTarget(name: "LayoutStorageTests", dependencies: ["LayoutStorage", "Geometry"])
    ]
)
