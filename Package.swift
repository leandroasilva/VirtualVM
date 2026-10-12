// swift-tools-version: 6.2
import PackageDescription

// The app. `swift run VirtualVM` builds it and opens a development copy; `scripts/build.sh` builds the app
// itself. Either way the product is only the app's program: `scripts/bundle-app.sh` makes an app of it.
//
// The `virtualvm` tool and the guest agent are built from `Packages/VirtualVMKit` in a build folder of their
// own. Products of one build share a folder, and on a disk that doesn't tell upper case from lower,
// `virtualvm` and `VirtualVM` would be one file.
let package = Package(
    name: "VirtualVM",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "VirtualVM", targets: ["VirtualVM"]),
    ],
    dependencies: [
        .package(path: "Packages/VirtualVMKit"),
        // Updates of the app. `scripts/bundle-app.sh` puts the framework into the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "VirtualVM",
            dependencies: [
                .product(name: "VMCore", package: "VirtualVMKit"),
                .product(name: "VZEngine", package: "VirtualVMKit"),
                .product(name: "VMNetworking", package: "VirtualVMKit"),
                .product(name: "SSHIntegration", package: "VirtualVMKit"),
                .product(name: "DiskTools", package: "VirtualVMKit"),
                .product(name: "Installers", package: "VirtualVMKit"),
                .product(name: "VMControl", package: "VirtualVMKit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "App",
            // Compiled by `scripts/bundle-app.sh`: the app's icon has to be in the app itself, not in
            // the bundle that a package's resources go to.
            exclude: ["AppIcon.icon", "Assets.xcassets"],
            swiftSettings: [
                // The app's code runs on the main actor unless it says otherwise.
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ],
            linkerSettings: [
                // The app runs on macOS 26 too, where these frameworks don't exist. Weak links let it
                // start there; every use of them sits behind an availability check.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "AccessoryAccess",
                              "-Xlinker", "-weak_framework", "-Xlinker", "DiskImageKit"]),
            ]
        ),
        .testTarget(
            name: "VirtualVMTests",
            dependencies: [
                "VirtualVM",
                .product(name: "VMCore", package: "VirtualVMKit"),
            ]
        ),
    ]
)
