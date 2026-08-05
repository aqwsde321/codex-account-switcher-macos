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
        TestCase("LibprocSnapshotProvider accepts only valid Developer ID crashpad kernel metadata") {
            let validFlags: UInt32 = 0x22010311
            try expect(
                LibprocSnapshotProvider.isTrustedKernelCrashpadSignature(
                    flags: validFlags,
                    validationCategory: 6,
                    identity: "browser_crashpad_handler",
                    teamIdentifier: "2DC432GLL2"
                ),
                "valid kernel crashpad metadata was rejected"
            )
            let rejectedMetadata: [(UInt32, UInt32, String?, String?)] = [
                (validFlags | 0x2, 6, "browser_crashpad_handler", "2DC432GLL2"),
                (validFlags | 0x10000000, 6, "browser_crashpad_handler", "2DC432GLL2"),
                (validFlags & ~0x1, 6, "browser_crashpad_handler", "2DC432GLL2"),
                (validFlags & ~0x10000, 6, "browser_crashpad_handler", "2DC432GLL2"),
                (validFlags & ~0x20000000, 6, "browser_crashpad_handler", "2DC432GLL2"),
                (validFlags, 5, "browser_crashpad_handler", "2DC432GLL2"),
                (validFlags, 6, "other", "2DC432GLL2"),
                (validFlags, 6, "browser_crashpad_handler", "OTHERTEAM"),
            ]
            try expect(
                rejectedMetadata.allSatisfy { flags, category, identity, teamIdentifier in
                    !LibprocSnapshotProvider.isTrustedKernelCrashpadSignature(
                        flags: flags,
                        validationCategory: category,
                        identity: identity,
                        teamIdentifier: teamIdentifier
                    )
                },
                "untrusted kernel crashpad metadata was accepted"
            )

            let identity = Array("browser_crashpad_handler".utf8)
            let totalLength = UInt32(identity.count + 9)
            let header: [UInt8] = [
                0, 0, 0, 0,
                UInt8((totalLength >> 24) & 0xff),
                UInt8((totalLength >> 16) & 0xff),
                UInt8((totalLength >> 8) & 0xff),
                UInt8(totalLength & 0xff),
            ]
            let encoded = header + identity + [0]
            try expect(
                LibprocSnapshotProvider.decodeCodeSigningText(encoded) == "browser_crashpad_handler",
                "csops identity header was decoded incorrectly"
            )
            try expect(
                LibprocSnapshotProvider.decodeCodeSigningText(Array(encoded.dropLast())) == nil,
                "truncated csops identity was accepted"
            )
        },
        TestCase("ProcessClassifier approves a kernel-validated crashpad after its executable is removed") {
            let rule = ApprovedResidentRule(
                executablePath: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/151.0.7922.71/Helpers/browser_crashpad_handler",
                name: "browser_crashpad_handler",
                signingIdentifier: "browser_crashpad_handler",
                teamIdentifier: "2DC432GLL2"
            )
            let resident = ProcessRecord(
                identity: ProcessIdentity(pid: 25, startSeconds: 100, startMicroseconds: 1),
                parentPID: 1,
                executablePath: nil,
                nameHint: rule.name,
                signingIdentifier: rule.signingIdentifier,
                teamIdentifier: rule.teamIdentifier
            )
            let context = ProcessClassificationContext(
                bundleRootPath: "/Applications/ChatGPT.app",
                mainExecutablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                bundledCodexPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                appRootIdentities: [],
                helperOwnedIdentities: [],
                approvedResidents: [rule]
            )

            let inventory = ProcessClassifier.classify([resident], context: context)

            try expect(
                inventory.disposition(forPID: resident.identity.pid) == .approvedNonAuthResident,
                "kernel-validated crashpad residue blocked account switching"
            )
            try expect(inventory.authMutationAllowed, "kernel-validated crashpad residue blocked auth mutation")

            let wrongParent = ProcessRecord(
                identity: ProcessIdentity(pid: 27, startSeconds: 100, startMicroseconds: 1),
                parentPID: 42,
                executablePath: nil,
                nameHint: rule.name,
                signingIdentifier: rule.signingIdentifier,
                teamIdentifier: rule.teamIdentifier
            )
            let wrongTeam = ProcessRecord(
                identity: ProcessIdentity(pid: 28, startSeconds: 100, startMicroseconds: 1),
                parentPID: 1,
                executablePath: nil,
                nameHint: rule.name,
                signingIdentifier: rule.signingIdentifier,
                teamIdentifier: "OTHERTEAM"
            )
            let invalidInventory = ProcessClassifier.classify([wrongParent, wrongTeam], context: context)
            try expect(
                invalidInventory.processes.allSatisfy { $0.disposition == .unclassifiedRelevant },
                "unverified pathless crashpad was approved"
            )
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
