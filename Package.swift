// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "typeno",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TypeNo", targets: ["TypeNo"])
    ],
    targets: [
        .executableTarget(
            name: "TypeNo",
            path: "Sources/Typeno",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "App/Info.plist"
                ])
            ]
        )
    ]
)
