// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "typeno",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TypeNo", targets: ["TypeNo"]),
        .executable(name: "TypeNoCoreChecks", targets: ["TypeNoCoreChecks"])
    ],
    targets: [
        .target(name: "TypeNoCore"),
        .executableTarget(
            name: "TypeNo",
            dependencies: ["TypeNoCore"],
            path: "Sources/Typeno",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "App/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "TypeNoCoreChecks",
            dependencies: ["TypeNoCore"],
            path: "Tests/TypeNoCoreChecks"
        )
    ]
)
