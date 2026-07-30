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
        TestCase("ApprovedResidentRule pins the validated Codex crashpad build") {
            let current = CodexAppDescriptor(
                bundleURL: URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
                mainExecutableURL: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
                bundledCodexURL: URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                bundleIdentifier: "com.openai.codex",
                version: "26.721.41059",
                build: "5848",
                appSigningIdentifier: "com.openai.codex",
                bundledCodexSigningIdentifier: "codex",
                teamIdentifier: "2DC432GLL2"
            )
            let changedBuild = CodexAppDescriptor(
                bundleURL: current.bundleURL,
                mainExecutableURL: current.mainExecutableURL,
                bundledCodexURL: current.bundledCodexURL,
                bundleIdentifier: current.bundleIdentifier,
                version: current.version,
                build: "5849",
                appSigningIdentifier: current.appSigningIdentifier,
                bundledCodexSigningIdentifier: current.bundledCodexSigningIdentifier,
                teamIdentifier: current.teamIdentifier
            )
            let updated = CodexAppDescriptor(
                bundleURL: current.bundleURL,
                mainExecutableURL: current.mainExecutableURL,
                bundledCodexURL: current.bundledCodexURL,
                bundleIdentifier: current.bundleIdentifier,
                version: "26.721.81911",
                build: "5973",
                appSigningIdentifier: current.appSigningIdentifier,
                bundledCodexSigningIdentifier: current.bundledCodexSigningIdentifier,
                teamIdentifier: current.teamIdentifier
            )

            try expect(
                ApprovedResidentRule.codexCrashpad(for: current) == ApprovedResidentRule(
                    executablePath: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/150.0.7871.128/Helpers/browser_crashpad_handler",
                    name: "browser_crashpad_handler",
                    signingIdentifier: "browser_crashpad_handler",
                    teamIdentifier: "2DC432GLL2"
                ),
                "validated crashpad rule did not match the observed signed executable"
            )
            try expect(
                ApprovedResidentRule.codexCrashpad(for: updated) != nil,
                "validated updated app build was rejected"
            )
            try expect(
                ApprovedResidentRule.codexCrashpad(for: changedBuild) == nil,
                "unvalidated app build inherited the crashpad approval"
            )
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
