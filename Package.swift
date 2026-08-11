// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wacomdri",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "IntuosCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Milestone 1 de-risking tool: dumps raw HID reports so we can pin down the
        // real byte layout before porting the Linux decoder.
        .executableTarget(
            name: "wacomdri-probe",
            dependencies: ["IntuosCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Milestone 1 de-risking tool: shows what actually arrives as NSEvent tablet
        // data, so injection can be verified without a third-party paint app.
        .executableTarget(
            name: "PressureScope",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Milestone 1 de-risking tool: posts synthetic tablet events, so the
        // output path can be proven without the tablet or root.
        .executableTarget(
            name: "wacomdri-inject-test",
            dependencies: ["IntuosCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The driver agent itself.
        .executableTarget(
            name: "wacomdrid",
            dependencies: ["IntuosCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "IntuosCoreTests",
            dependencies: ["IntuosCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
