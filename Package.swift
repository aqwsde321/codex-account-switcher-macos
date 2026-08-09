// swift-tools-version: 6.0

import PackageDescription

let faultInjectionSettings: [SwiftSetting] = [
    .define("SPIKE_FAULT_INJECTION", .when(configuration: .debug)),
]

let package = Package(
    name: "CodexAccountSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodexAccountCore", targets: ["CodexAccountCore"]),
        .executable(name: "codex-account-spike", targets: ["CodexAccountSpike"]),
        .executable(name: "CodexAccountMenuBar", targets: ["CodexAccountMenuBar"]),
        .executable(name: "CodexSleepGuard", targets: ["CodexSleepGuard"]),
        .executable(name: "codex-account-core-tests", targets: ["CodexAccountCoreTests"]),
    ],
    targets: [
        .target(name: "CodexSleepGuardCore"),
        .target(
            name: "CodexAccountCore",
            dependencies: ["CodexSleepGuardCore"],
            swiftSettings: faultInjectionSettings
        ),
        .executableTarget(
            name: "CodexAccountSpike",
            dependencies: ["CodexAccountCore"],
            swiftSettings: faultInjectionSettings
        ),
        .target(
            name: "CodexAccountMenuBarModel",
            dependencies: ["CodexAccountCore", "CodexSleepGuardCore"]
        ),
        .executableTarget(
            name: "CodexAccountMenuBar",
            dependencies: [
                "CodexAccountCore",
                "CodexAccountMenuBarModel",
                "CodexSleepGuardCore",
            ]
        ),
        .executableTarget(
            name: "CodexSleepGuard",
            dependencies: ["CodexSleepGuardCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "CodexAccountCoreTests",
            dependencies: [
                "CodexAccountCore",
                "CodexAccountMenuBarModel",
                "CodexSleepGuardCore",
            ],
            path: "Tests/CodexAccountCoreTests",
            swiftSettings: faultInjectionSettings
        ),
    ]
)
