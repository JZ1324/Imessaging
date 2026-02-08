// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImessageStatsMacApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ImessageStatsMacApp", targets: ["ImessageStatsMacApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "ImessageStatsMacApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Contacts")
            ]
        )
    ]
)
