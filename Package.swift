// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexAccountSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodexAccountCore", targets: ["CodexAccountCore"]),
        .executable(name: "codex-account-spike", targets: ["CodexAccountSpike"]),
        .executable(name: "codex-account-core-tests", targets: ["CodexAccountCoreTests"]),
    ],
    targets: [
        .target(name: "CodexAccountCore"),
        .executableTarget(
            name: "CodexAccountSpike",
            dependencies: ["CodexAccountCore"]
        ),
        .executableTarget(
            name: "CodexAccountCoreTests",
            dependencies: ["CodexAccountCore"],
            path: "Tests/CodexAccountCoreTests"
        ),
    ]
)
