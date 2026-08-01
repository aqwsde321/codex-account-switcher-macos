import CodexAccountCore
import Foundation

func processClassifierTests() -> [TestCase] {
    [
        TestCase("ProcessClassifier fails closed for app and independent Codex writers") {
            let root = ProcessIdentity(pid: 10, startSeconds: 100, startMicroseconds: 1)
            let records = [
                ProcessRecord(
                    identity: root,
                    parentPID: 1,
                    executablePath: "/Applications/Codex.app/Contents/MacOS/ChatGPT",
                    nameHint: "ChatGPT"
                ),
                ProcessRecord(
                    identity: ProcessIdentity(pid: 11, startSeconds: 101, startMicroseconds: 1),
                    parentPID: 10,
                    executablePath: "/outside/child",
                    nameHint: "worker"
                ),
                ProcessRecord(
                    identity: ProcessIdentity(pid: 12, startSeconds: 102, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: "/opt/homebrew/bin/codex",
                    nameHint: "codex"
                ),
                ProcessRecord(
                    identity: ProcessIdentity(pid: 13, startSeconds: 103, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: "/Applications/Codex.app.evil/Contents/worker",
                    nameHint: "worker"
                ),
            ]
            let context = ProcessClassificationContext(
                bundleRootPath: "/Applications/Codex.app",
                mainExecutablePath: "/Applications/Codex.app/Contents/MacOS/ChatGPT",
                bundledCodexPath: "/Applications/Codex.app/Contents/Resources/codex",
                appRootIdentities: [root],
                helperOwnedIdentities: [],
                approvedResidents: []
            )

            let inventory = ProcessClassifier.classify(records, context: context)

            try expect(inventory.disposition(forPID: 10) == .appOwnedBlocker, "app root not blocked")
            try expect(inventory.disposition(forPID: 11) == .appOwnedBlocker, "app descendant not blocked")
            try expect(inventory.disposition(forPID: 12) == .independentCodexBlocker, "independent CLI not blocked")
            try expect(inventory.disposition(forPID: 13) == .irrelevant, "prefix-confusable path was treated as bundle path")
            try expect(!inventory.authMutationAllowed, "auth mutation allowed with blockers")
        },
        TestCase("ProcessClassifier fails closed instead of trapping on duplicate PIDs") {
            let duplicatePID: Int32 = 404
            let records = [
                ProcessRecord(
                    identity: ProcessIdentity(pid: duplicatePID, startSeconds: 100, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: "/usr/bin/true",
                    nameHint: "true"
                ),
                ProcessRecord(
                    identity: ProcessIdentity(pid: duplicatePID, startSeconds: 101, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: "/usr/bin/false",
                    nameHint: "false"
                ),
            ]
            let context = ProcessClassificationContext(
                bundleRootPath: "/Applications/Codex.app",
                mainExecutablePath: "/Applications/Codex.app/Contents/MacOS/ChatGPT",
                bundledCodexPath: "/Applications/Codex.app/Contents/Resources/codex",
                appRootIdentities: [],
                helperOwnedIdentities: [],
                approvedResidents: []
            )

            let inventory = ProcessClassifier.classify(records, context: context)

            try expect(!inventory.authMutationAllowed, "duplicate PID snapshot did not block mutation")
            try expect(
                inventory.processes.allSatisfy { $0.disposition == .unclassifiedRelevant },
                "duplicate PID records were not classified fail-closed"
            )
        },
        TestCase("ApprovedResidentRule resolves future Codex crashpad builds inside the signed bundle") {
            try withCrashpadFixture(frameworkVersion: "999.0.1") { bundleURL, helperURL, currentURL, rootURL in
                func futureDescriptor(
                    crashpadSigningIdentifier: String = "browser_crashpad_handler"
                ) -> CodexAppDescriptor {
                    CodexAppDescriptor(
                        bundleURL: bundleURL,
                        mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                        bundledCodexURL: bundleURL.appendingPathComponent("Contents/Resources/codex"),
                        bundleIdentifier: "com.openai.codex",
                        version: "99.999.99999",
                        build: "9999",
                        appSigningIdentifier: "com.openai.codex",
                        bundledCodexSigningIdentifier: "codex",
                        crashpadSigningIdentifier: crashpadSigningIdentifier,
                        teamIdentifier: "2DC432GLL2"
                    )
                }
                let future = futureDescriptor()
                let expected = ApprovedResidentRule(
                    executablePath: helperURL.path,
                    name: "browser_crashpad_handler",
                    signingIdentifier: "browser_crashpad_handler",
                    teamIdentifier: "2DC432GLL2"
                )

                try expect(
                    ApprovedResidentRule.codexCrashpad(for: future) == expected,
                    "official future app build was rejected only because its build number was unknown"
                )
                try expect(
                    ApprovedResidentRule.codexCrashpad(
                        for: futureDescriptor(crashpadSigningIdentifier: "other")
                    ) == nil,
                    "crashpad with an unexpected signing identifier was approved"
                )

                let outsideVersionURL = rootURL.appendingPathComponent("OutsideVersion", isDirectory: true)
                let outsideHelperURL = outsideVersionURL
                    .appendingPathComponent("Helpers/browser_crashpad_handler")
                try makeExecutableFixture(at: outsideHelperURL)
                try FileManager.default.removeItem(at: currentURL)
                try FileManager.default.createSymbolicLink(
                    atPath: currentURL.path,
                    withDestinationPath: outsideVersionURL.path
                )
                try expect(
                    ApprovedResidentRule.codexCrashpad(for: future) == expected,
                    "a validated descriptor followed a later Current symlink change"
                )
                try expect(
                    ApprovedResidentRule.codexCrashpad(for: futureDescriptor()) == nil,
                    "crashpad symlink escaping the signed bundle was approved"
                )
            }
        },
        TestCase("ProcessClassifier approves only the exact signed resident tuple") {
            let path = "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150.0.7871.128/Helpers/browser_crashpad_handler"
            let rule = ApprovedResidentRule(
                executablePath: path,
                name: "browser_crashpad_handler",
                signingIdentifier: "browser_crashpad_handler",
                teamIdentifier: "2DC432GLL2"
            )
            let exact = ProcessRecord(
                identity: ProcessIdentity(pid: 20, startSeconds: 100, startMicroseconds: 1),
                parentPID: 1,
                executablePath: path,
                nameHint: rule.name,
                signingIdentifier: rule.signingIdentifier,
                teamIdentifier: rule.teamIdentifier
            )
            let mismatches = [
                ProcessRecord(
                    identity: ProcessIdentity(pid: 21, startSeconds: 100, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: path + ".other",
                    nameHint: rule.name,
                    signingIdentifier: rule.signingIdentifier,
                    teamIdentifier: rule.teamIdentifier
                ),
                ProcessRecord(
                    identity: ProcessIdentity(pid: 22, startSeconds: 100, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: path,
                    nameHint: "other",
                    signingIdentifier: rule.signingIdentifier,
                    teamIdentifier: rule.teamIdentifier
                ),
                ProcessRecord(
                    identity: ProcessIdentity(pid: 23, startSeconds: 100, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: path,
                    nameHint: rule.name,
                    signingIdentifier: "other",
                    teamIdentifier: rule.teamIdentifier
                ),
                ProcessRecord(
                    identity: ProcessIdentity(pid: 24, startSeconds: 100, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: path,
                    nameHint: rule.name,
                    signingIdentifier: rule.signingIdentifier,
                    teamIdentifier: "OTHERTEAM"
                ),
            ]
            let context = ProcessClassificationContext(
                bundleRootPath: "/Applications/ChatGPT.app",
                mainExecutablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                bundledCodexPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                appRootIdentities: [],
                helperOwnedIdentities: [],
                approvedResidents: [rule]
            )

            let exactInventory = ProcessClassifier.classify([exact], context: context)
            try expect(
                exactInventory.disposition(forPID: exact.identity.pid) == .approvedNonAuthResident,
                "exact signed resident was not approved"
            )
            try expect(exactInventory.authMutationAllowed, "exact signed resident blocked mutation")

            let mismatchInventory = ProcessClassifier.classify(mismatches, context: context)
            try expect(
                mismatchInventory.processes.allSatisfy { $0.disposition == .appOwnedBlocker },
                "a resident tuple mismatch was approved"
            )
            try expect(!mismatchInventory.authMutationAllowed, "resident tuple mismatch allowed mutation")
        },
        TestCase("ProcessClassifier blocks an unresolved crashpad resident") {
            let record = ProcessRecord(
                identity: ProcessIdentity(pid: 25, startSeconds: 100, startMicroseconds: 1),
                parentPID: 1,
                executablePath: nil,
                nameHint: "browser_crashpad_handler"
            )
            let context = ProcessClassificationContext(
                bundleRootPath: "/Applications/ChatGPT.app",
                mainExecutablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                bundledCodexPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                appRootIdentities: [],
                helperOwnedIdentities: [],
                approvedResidents: []
            )

            let inventory = ProcessClassifier.classify([record], context: context)

            try expect(
                inventory.disposition(forPID: record.identity.pid) == .unclassifiedRelevant,
                "unresolved crashpad resident did not fail closed"
            )
            try expect(!inventory.authMutationAllowed, "unresolved crashpad resident allowed mutation")
        },
    ]
}

private func withCrashpadFixture(
    frameworkVersion: String,
    _ body: (URL, URL, URL, URL) throws -> Void
) throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-crashpad-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let bundleURL = rootURL.appendingPathComponent("ChatGPT.app", isDirectory: true)
    let versionsURL = bundleURL.appendingPathComponent(
        "Contents/Frameworks/Codex Framework.framework/Versions",
        isDirectory: true
    )
    let helperURL = versionsURL
        .appendingPathComponent(frameworkVersion, isDirectory: true)
        .appendingPathComponent("Helpers/browser_crashpad_handler")
    try makeExecutableFixture(at: helperURL)

    let currentURL = versionsURL.appendingPathComponent("Current")
    try FileManager.default.createSymbolicLink(
        atPath: currentURL.path,
        withDestinationPath: frameworkVersion
    )
    try body(bundleURL, helperURL, currentURL, rootURL)
}

private func makeExecutableFixture(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}
