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
        .executable(name: "codex-account-core-tests", targets: ["CodexAccountCoreTests"]),
    ],
    targets: [
        .target(
            name: "CodexAccountCore",
            swiftSettings: faultInjectionSettings
        ),
        .executableTarget(
            name: "CodexAccountSpike",
            dependencies: ["CodexAccountCore"],
            swiftSettings: faultInjectionSettings
        ),
        .executableTarget(
            name: "CodexAccountCoreTests",
            dependencies: ["CodexAccountCore"],
            path: "Tests/CodexAccountCoreTests",
            swiftSettings: faultInjectionSettings
        ),
    ]
)
