import CodexAccountCore

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
    ]
}
