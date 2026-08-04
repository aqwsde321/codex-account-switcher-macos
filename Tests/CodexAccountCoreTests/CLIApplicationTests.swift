import Darwin
import Foundation
import CodexAccountCore

func cliApplicationTests() -> [TestCase] {
    var tests = [
        TestCase("CodexAppLocator falls back to the installed ChatGPT bundle") {
            let candidates = CodexAppLocator.candidateURLs(
                discovered: [],
                fileExists: { $0 == "/Applications/ChatGPT.app" }
            )

            try expect(
                candidates.map(\.path) == ["/Applications/ChatGPT.app"],
                "ChatGPT fallback was not considered when Launch Services returned nothing"
            )
        },
        TestCase("CLIApplication lists profiles without exposing email text") {
            let profileID = ProfileID(UUID())
            let provider = StubCLIDataProvider(
                profiles: [
                    ProfileListItem(
                        id: profileID,
                        label: "personal",
                        email: "sensitive@private.example",
                        active: true,
                        needsRelogin: false
                    ),
                ]
            )
            let application = CLIApplication(provider: provider)

            let result = await application.run(arguments: ["profiles", "list"])

            try expect(result.exitCode == 0, "profiles list failed")
            try expect(result.standardOutput.contains("personal"), "profile label missing")
            try expect(result.standardOutput.contains("<email-redacted>"), "masked email missing")
            try expect(!result.standardOutput.contains("sensitive"), "email local part leaked")
            try expect(!result.standardOutput.contains("private.example"), "email domain leaked")
        },
        TestCase("CLIApplication never renders an arbitrary thrown error") {
            let provider = StubCLIDataProvider(profiles: [], failureCanary: "secret-error-canary")
            let application = CLIApplication(provider: provider)

            let result = await application.run(arguments: ["inspect"])

            try expect(result.exitCode != 0, "failing inspect returned success")
            try expect(!result.standardError.contains("secret-error-canary"), "raw error leaked")
            try expect(result.standardError == "error=operation_failed\n", "error output is not allow-listed")
        },
        TestCase("Local provider reads active and inactive usage without changing public auth") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory, activeAuthIsSource: true)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let availableTarget = ProfileMetadata(
                    id: fixture.target.id,
                    label: fixture.target.label,
                    email: fixture.target.email,
                    planType: fixture.target.planType,
                    needsRelogin: false,
                    createdAt: fixture.target.createdAt,
                    updatedAt: fixture.target.updatedAt
                )
                let registry = try ProfileRegistry(
                    activeProfileID: fixture.source.id,
                    profiles: [fixture.source, availableTarget]
                )
                _ = try store.saveRegistry(registry)
                let authBefore = try Data(contentsOf: fixture.authURL)
                let sourceBefore = try store.loadCredential(for: fixture.source.id)
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                let report = try await provider.profileUsage()
                let authAfter = try Data(contentsOf: fixture.authURL)
                let registryAfter = try store.loadRegistry()
                let sourceAfter = try store.loadCredential(for: fixture.source.id)
                let targetAfter = try store.loadCredential(for: fixture.target.id)

                try expect(
                    report.usageByProfileID.count == 2,
                    "inactive usage was not queried: loaded=\(report.usageByProfileID.count) failed=\(report.failedProfileIDs.count)"
                )
                try expect(report.failedProfileIDs.isEmpty, "successful account was marked failed")
                try expect(
                    report.usageByProfileID[fixture.source.id]?.planType == "pro",
                    "active plan type changed"
                )
                try expect(
                    report.usageByProfileID[fixture.target.id]?.planType == "team",
                    "inactive plan type changed"
                )
                try expect(
                    report.usageByProfileID[fixture.source.id]?.windows.map(\.windowDurationMinutes)
                        == [300, 10_080],
                    "dynamic main Codex windows changed"
                )
                try expect(authAfter == authBefore, "usage query changed public auth.json")
                try expect(registryAfter == registry, "usage query changed registry")
                try expect(sourceAfter == sourceBefore, "usage query changed source credential")
                try expect(targetAfter == targetBefore, "usage query changed target credential")
                try expect(
                    !FileManager.default.fileExists(
                        atPath: fixture.storeURL
                            .appendingPathComponent("credential-verification-workspace")
                            .path
                    ),
                    "usage workspace was not removed"
                )

                let targetURL = fixture.storeURL
                    .appendingPathComponent("credentials", isDirectory: true)
                    .appendingPathComponent("\(fixture.target.id).json", isDirectory: false)
                let files = DarwinDurableFileOperations()
                _ = try files.replace(
                    contents: SensitiveBytes(Data("{}".utf8)),
                    at: targetURL,
                    expecting: files.snapshot(at: targetURL)
                )
                let partial = try await provider.profileUsage()
                try expect(
                    Set(partial.usageByProfileID.keys) == [fixture.source.id]
                        && partial.failedProfileIDs == [fixture.target.id],
                    "one invalid credential hid another account's usage"
                )
            }
        },
        TestCase("CLIApplication keeps recovery status output stable") {
            let previousProfileID = ProfileID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            )
            let provider = StubCLIDataProvider(
                profiles: [],
                recoveryStatus: .pending(
                    transactionID: "00000000-0000-0000-0000-000000000010",
                    phase: .rollbackFailed,
                    previousProfileID: previousProfileID
                )
            )
            let application = CLIApplication(provider: provider)

            let result = await application.run(arguments: ["recovery", "status"])

            try expect(result.exitCode == 0, "recovery status failed")
            try expect(
                result.standardOutput
                    == "recovery=pending transaction_id=00000000-0000-0000-0000-000000000010 phase=rollbackFailed\n",
                "recovery CLI output changed"
            )
            try expect(
                !result.standardOutput.contains(previousProfileID.description),
                "menu-only previous profile ID leaked into CLI output"
            )
        },
        TestCase("Manual recovery reports a restored profile when app launch is unconfirmed") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeManualRecoveryFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let launches = await MainActor.run { AppLaunchRecorder() }
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    requestApplicationTermination: { _ in [] },
                    normalTerminationGracePolls: 0,
                    quiescenceSleep: { _ in },
                    launchApplication: { _ in
                        launches.record()
                        throw CodexAppLifecycleFailure.launchFailed
                    }
                )
                let application = CLIApplication(provider: provider)
                let registryBeforeStaleConfirmation = try store.loadRegistry()
                let authBeforeStaleConfirmation = try Data(contentsOf: fixture.authURL)
                let journalBeforeStaleConfirmation = try store.loadJournalIfPresent()

                do {
                    _ = try await provider.restoreRecoveryProfile(
                        target: fixture.previous.id.description,
                        expectedTransactionID: "00000000-0000-0000-0000-000000000099"
                    )
                    throw TestFailure(description: "stale recovery transaction was accepted")
                } catch let failure as LocalCLIDataProviderFailure {
                    try expect(
                        failure == .manualRecoveryUnavailable,
                        "stale recovery transaction returned another failure"
                    )
                }
                let registryAfterStaleConfirmation = try store.loadRegistry()
                let authAfterStaleConfirmation = try Data(contentsOf: fixture.authURL)
                let journalAfterStaleConfirmation = try store.loadJournalIfPresent()

                let result = await application.run(
                    arguments: ["recovery", "restore", "--profile", fixture.previous.label],
                    mutationConfirmed: true
                )
                let registry = try store.loadRegistry()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedPrevious = try store.loadCredential(for: fixture.previous.id)
                let journal = try store.loadJournalIfPresent()
                let launchCount = await MainActor.run { launches.count }

                try expect(
                    registryAfterStaleConfirmation == registryBeforeStaleConfirmation
                        && authAfterStaleConfirmation == authBeforeStaleConfirmation
                        && journalAfterStaleConfirmation == journalBeforeStaleConfirmation,
                    "stale recovery confirmation mutated state"
                )
                try expect(result.exitCode == 1, "unconfirmed app launch returned full success")
                try expect(
                    result.standardOutput.contains("recovery=restored application_launch=unconfirmed"),
                    "durable recovery was hidden after app launch failure"
                )
                try expect(
                    result.standardOutput.contains("active=true label=A"),
                    "launch uncertainty lost the restored profile payload"
                )
                try expect(
                    result.standardError == "error=application_launch_unconfirmed\n",
                    "app launch failure was not typed"
                )
                try expect(registry.activeProfileID == fixture.previous.id, "recovery did not commit previous")
                try expect(active == storedPrevious, "recovery did not restore previous auth")
                try expect(journal == nil, "durable recovery left a journal")
                try expect(launchCount == 1, "app launch was not attempted exactly once")
            }
        },
        TestCase("Manual recovery stops when journal finalization durability is unknown") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeManualRecoveryFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let launches = await MainActor.run { AppLaunchRecorder() }
                let syncFailure = DurableFileFailure(
                    mutation: .remove,
                    stage: .syncParent,
                    errno: EIO,
                    certainty: .durabilityUnknown
                )
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    requestApplicationTermination: { _ in [] },
                    normalTerminationGracePolls: 0,
                    quiescenceSleep: { _ in },
                    removeJournalFile: {
                        _ = try SpikeStore.openExisting(at: fixture.storeURL).removeJournal()
                        throw syncFailure
                    },
                    syncStoreDirectory: { throw syncFailure },
                    launchApplication: { _ in
                        launches.record()
                        return 301
                    }
                )
                let application = CLIApplication(provider: provider)

                let result = await application.run(
                    arguments: ["recovery", "restore", "--profile", fixture.previous.label],
                    mutationConfirmed: true
                )
                let recovery = await application.run(arguments: ["recovery", "status"])
                let blockedSwitch = await application.run(
                    arguments: ["switch", "--target", "B"],
                    mutationConfirmed: true
                )
                let blockedCapture = await application.run(
                    arguments: ["profile", "capture", "--label", "C"],
                    mutationConfirmed: true
                )
                let blockedSync = await application.run(
                    arguments: ["profile", "sync-active"],
                    mutationConfirmed: true
                )
                let restartedApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [] },
                        syncStoreDirectory: { throw syncFailure }
                    )
                )
                let restartedRecovery = await restartedApplication.run(arguments: ["recovery", "status"])
                let restoredRegistry = try store.loadRegistry()
                let restoredAuthData = try Data(contentsOf: fixture.authURL)
                let evidenceBeforeMismatch = try store.loadJournalFinalizationEvidenceIfPresent()
                _ = try store.saveRegistry(
                    ProfileRegistry(
                        activeProfileID: fixture.target.id,
                        profiles: restoredRegistry.profiles
                    )
                )
                let mismatchedApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [] }
                    )
                )
                let mismatchedRecovery = await mismatchedApplication.run(arguments: ["recovery", "status"])
                let evidenceAfterMismatch = try store.loadJournalFinalizationEvidenceIfPresent()
                _ = try store.saveRegistry(restoredRegistry)
                let files = DarwinDurableFileOperations()
                _ = try files.replace(
                    contents: SensitiveBytes(fixture.targetAuthData),
                    at: fixture.authURL,
                    expecting: files.snapshot(at: fixture.authURL)
                )
                let authMismatchedApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [] }
                    )
                )
                let authMismatchedRecovery = await authMismatchedApplication.run(
                    arguments: ["recovery", "status"]
                )
                let evidenceAfterAuthMismatch = try store.loadJournalFinalizationEvidenceIfPresent()
                _ = try files.replace(
                    contents: SensitiveBytes(restoredAuthData),
                    at: fixture.authURL,
                    expecting: files.snapshot(at: fixture.authURL)
                )
                let reconciledApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [] }
                    )
                )
                let reconciledRecovery = await reconciledApplication.run(arguments: ["recovery", "status"])
                let registry = try store.loadRegistry()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedPrevious = try store.loadCredential(for: fixture.previous.id)
                let visibleJournal = try store.loadJournalIfPresent()
                let evidenceAfterReconciliation = try store.loadJournalFinalizationEvidenceIfPresent()
                let captureProfileID = try store.loadCaptureProfileIDIfPresent()
                let launchCount = await MainActor.run { launches.count }

                try expect(result.exitCode == 1, "unknown journal durability returned success")
                try expect(result.standardOutput.isEmpty, "unknown durability reported restored output")
                try expect(
                    result.standardError == "error=recovery_uncertain\n",
                    "unknown journal durability was not typed"
                )
                try expect(recovery.standardOutput == "recovery=blocked\n", "uncertain recovery gate reopened")
                try expect(
                    restartedRecovery.standardOutput == "recovery=blocked\n",
                    "restarted provider lost the uncertain recovery gate"
                )
                try expect(
                    evidenceBeforeMismatch?.expectedActiveProfileID == fixture.previous.id,
                    "journal finalization evidence lost the expected active profile"
                )
                try expect(
                    mismatchedRecovery.standardOutput == "recovery=blocked\n"
                        && evidenceAfterMismatch == evidenceBeforeMismatch,
                    "registry mismatch cleared journal finalization evidence"
                )
                try expect(
                    authMismatchedRecovery.standardOutput == "recovery=blocked\n"
                        && evidenceAfterAuthMismatch == evidenceBeforeMismatch,
                    "active auth mismatch cleared journal finalization evidence"
                )
                try expect(
                    reconciledRecovery.standardOutput == "recovery=none\n",
                    "verified state and directory fsync did not reconcile journal absence"
                )
                try expect(
                    [blockedSwitch, blockedCapture, blockedSync].allSatisfy { $0.exitCode == 1 },
                    "uncertain recovery allowed a mutation"
                )
                try expect(registry.activeProfileID == fixture.previous.id, "recovery lost previous registry commit")
                try expect(active == storedPrevious, "recovery lost previous auth verification")
                try expect(visibleJournal == nil, "fault did not cover the visible-unlink window")
                try expect(evidenceAfterReconciliation == nil, "reconciled finalization evidence remained")
                try expect(captureProfileID == nil, "uncertain recovery created capture state")
                try expect(launchCount == 0, "uncertain journal finalization launched the app")
            }
        },
        TestCase("Journal finalization resumes through the shared mutation gate") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeManualRecoveryFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let unlinkFailure = DurableFileFailure(
                    mutation: .remove,
                    stage: .unlink,
                    errno: EIO,
                    certainty: .destinationUnchanged
                )
                let interruptedApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [] },
                        requestApplicationTermination: { _ in [] },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in },
                        removeJournalFile: { throw unlinkFailure }
                    )
                )

                let interrupted = await interruptedApplication.run(
                    arguments: ["recovery", "restore", "--profile", fixture.previous.label],
                    mutationConfirmed: true
                )
                let journalBeforeResume = try store.loadJournalIfPresent()
                let evidenceBeforeResume = try store.loadJournalFinalizationEvidenceIfPresent()
                guard let evidenceBeforeResume else {
                    throw TestFailure(description: "interrupted finalization lost durable evidence")
                }
                let evidenceURL = fixture.storeURL.appendingPathComponent("journal-finalization.json")
                let mismatchedEvidence = Data(
                    """
                    {
                      "schemaVersion": 1,
                      "transactionId": "\(evidenceBeforeResume.transactionID.uuidString)",
                      "journalPhase": "targetVerified",
                      "expectedActiveProfileId": "\(evidenceBeforeResume.expectedActiveProfileID)",
                      "expectedActiveAuthSha256": "\(evidenceBeforeResume.expectedActiveAuthSHA256)"
                    }
                    """.utf8
                )
                let files = DarwinDurableFileOperations()
                _ = try files.replace(
                    contents: SensitiveBytes(mismatchedEvidence),
                    at: evidenceURL,
                    expecting: files.snapshot(at: evidenceURL)
                )
                let blockedApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [] }
                    )
                )
                let blocked = await blockedApplication.run(arguments: ["recovery", "status"])
                let journalAfterMismatch = try store.loadJournalIfPresent()
                let evidenceAfterMismatch = try store.loadJournalFinalizationEvidenceIfPresent()
                let matchingEvidence = Data(
                    """
                    {
                      "schemaVersion": 1,
                      "transactionId": "\(evidenceBeforeResume.transactionID.uuidString)",
                      "journalPhase": "rollbackStarted",
                      "expectedActiveProfileId": "\(evidenceBeforeResume.expectedActiveProfileID)",
                      "expectedActiveAuthSha256": "\(evidenceBeforeResume.expectedActiveAuthSHA256)"
                    }
                    """.utf8
                )
                _ = try files.replace(
                    contents: SensitiveBytes(matchingEvidence),
                    at: evidenceURL,
                    expecting: files.snapshot(at: evidenceURL)
                )
                let resumedApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [301] },
                        activateApplication: { _ in true }
                    )
                )
                let resumed = await resumedApplication.run(
                    arguments: ["switch", "--target", fixture.previous.label],
                    mutationConfirmed: true
                )
                let journalAfterResume = try store.loadJournalIfPresent()
                let evidenceAfterResume = try store.loadJournalFinalizationEvidenceIfPresent()

                try expect(interrupted.exitCode == 1, "interrupted journal unlink returned success")
                try expect(
                    journalBeforeResume?.phase == .rollbackFailed,
                    "interrupted finalization lost its journal"
                )
                try expect(
                    blocked.standardOutput == "recovery=blocked\n"
                        && journalAfterMismatch == journalBeforeResume
                        && evidenceAfterMismatch?.journalPhase == .targetVerified,
                    "phase-mismatched evidence was accepted"
                )
                try expect(resumed.exitCode == 0, "shared mutation gate did not resume finalization")
                try expect(journalAfterResume == nil, "resumed finalization left journal")
                try expect(evidenceAfterResume == nil, "resumed finalization left evidence")
            }
        },
        TestCase("CLIApplication reports an incompatible installed application") {
            let provider = StubCLIDataProvider(
                profiles: [],
                switchFailure: .invalidSignature
            )
            let application = CLIApplication(provider: provider)

            let result = await application.run(
                arguments: ["switch", "--target", "B"],
                mutationConfirmed: true
            )

            try expect(result.exitCode != 0, "invalid application switch returned success")
            try expect(
                result.standardError == "error=incompatible_application\n",
                "invalid application was hidden as a generic failure"
            )
        },
        TestCase("CLIApplication captures a profile only after confirmation and redacts identity") {
            let provider = StubCLIDataProvider(
                profiles: [],
                capturedProfile: ProfileListItem(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "capture-secret@private.example",
                    active: true,
                    needsRelogin: false
                )
            )
            let application = CLIApplication(provider: provider)
            let arguments = ["profile", "capture", "--label", "A"]

            let denied = await application.run(arguments: arguments)
            let captured = await application.run(arguments: arguments, mutationConfirmed: true)
            let capturedLabels = await provider.capturedLabels

            try expect(denied.exitCode == 77, "unconfirmed capture was not rejected")
            try expect(denied.standardError == "error=confirmation_required\n", "confirmation error changed")
            try expect(captured.exitCode == 0, "confirmed capture failed")
            try expect(captured.standardOutput.contains("label=A"), "captured label missing")
            try expect(captured.standardOutput.contains("email=<email-redacted>"), "captured email was not masked")
            try expect(!captured.standardOutput.contains("capture-secret"), "captured identity leaked")
            try expect(capturedLabels == ["A"], "capture was dispatched before confirmation")
        },
        TestCase("CLIApplication switches only after confirmation") {
            let provider = StubCLIDataProvider(
                profiles: [],
                capturedProfile: ProfileListItem(
                    id: ProfileID(UUID()),
                    label: "B",
                    email: "switch-secret@private.example",
                    active: true,
                    needsRelogin: false
                )
            )
            let application = CLIApplication(provider: provider)
            let arguments = ["switch", "--target", "B"]

            let denied = await application.run(arguments: arguments)
            let switched = await application.run(arguments: arguments, mutationConfirmed: true)
            let switchedTargets = await provider.switchedTargets

            try expect(denied.exitCode == 77, "unconfirmed switch was not rejected")
            try expect(denied.standardError == "error=confirmation_required\n", "switch confirmation error changed")
            try expect(switched.exitCode == 0, "confirmed switch failed")
            try expect(switched.standardOutput.contains("active=true label=B"), "switched profile output changed")
            try expect(!switched.standardOutput.contains("switch-secret"), "switched identity leaked")
            try expect(switchedTargets == ["B"], "switch was dispatched before confirmation")
        },
        TestCase("CLI capture persists the refreshed first active profile") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: codexHome.path
                )
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let auth = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"fixture-id","access_token":"fixture-access","refresh_token":"fixture-refresh"}}"#.utf8
                )
                try auth.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let executable = try makeCaptureAppServer(in: directory, rotateToOtherAccount: false)
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.81911",
                    build: "5973",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let processes = TerminableProcessSnapshotProvider()
                let appRoot = ProcessRecord(
                    identity: ProcessIdentity(pid: 75, startSeconds: 98, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: descriptor.mainExecutableURL.path,
                    nameHint: "ChatGPT"
                )
                processes.install(appRoot)
                let confirmations = TerminationConfirmationRecorder()
                let launches = await MainActor.run { AppLaunchRecorder() }
                let provider = LocalCLIDataProvider(
                    storeURL: directory.appendingPathComponent("store", isDirectory: true),
                    activeAuthURL: authURL,
                    processProvider: processes,
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in
                        processes.contains(pid: appRoot.identity.pid) ? [appRoot.identity.pid] : []
                    },
                    requestApplicationTermination: { _ in
                        processes.install([])
                        return [appRoot.identity.pid]
                    },
                    confirmAppOwnedTermination: confirmations.confirm,
                    requestProcessTermination: { processes.terminate($0) },
                    normalTerminationGracePolls: 0,
                    quiescenceSleep: { _ in },
                    launchApplication: { _ in
                        launches.record()
                        return 42
                    }
                )
                let application = CLIApplication(provider: provider)

                let captured = await application.run(
                    arguments: ["profile", "capture", "--label", "A"],
                    mutationConfirmed: true
                )
                let listed = await application.run(arguments: ["profiles", "list"])
                let authAfter = try Data(contentsOf: authURL)
                let store = try SpikeStore.openExisting(
                    at: directory.appendingPathComponent("store", isDirectory: true)
                )
                let registry = try store.loadRegistry()
                let storedCredential = try store.loadCredential(for: registry.profiles[0].id)
                let activeCredential = try CredentialBlob(validating: authAfter)
                let launchCount = await MainActor.run { launches.count }

                try expect(captured.exitCode == 0, "local capture failed")
                try expect(listed.exitCode == 0, "captured profile could not be listed")
                try expect(listed.standardOutput.contains("active=true"), "captured profile is not active")
                try expect(listed.standardOutput.contains("label=A"), "captured profile label missing")
                try expect(listed.standardOutput.contains("email=<email-redacted>"), "identity was not redacted")
                try expect(!listed.standardOutput.contains("person@example.invalid"), "identity leaked")
                try expect(authAfter != auth, "refresh did not update the active auth file")
                try expect(storedCredential == activeCredential, "refreshed credential was not captured")
                try expect(launchCount == 1, "first capture did not reopen the app")
                try expect(confirmations.counts.isEmpty, "normal app quit requested SIGTERM approval")
                try expect(processes.terminatedPIDs.isEmpty, "normal app quit sent SIGTERM")
            }
        },
        TestCase("CLI capture stores a second profile without changing the active profile") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeA = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                )
                try activeA.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let profileA = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "person@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
                let credentialA = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(credentialA, for: profileA.id)
                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileA.id, profiles: [profileA])
                )

                let executable = try makeCaptureAppServer(
                    in: directory,
                    rotateToOtherAccount: false,
                    loginAccount: "b"
                )
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let launches = await MainActor.run { AppLaunchRecorder() }
                let lingeringProcesses = TerminableProcessSnapshotProvider()
                let lingeringConfirmations = TerminationConfirmationRecorder()
                let appRootIdentity = ProcessIdentity(pid: 76, startSeconds: 99, startMicroseconds: 1)
                let lingeringIdentity = ProcessIdentity(pid: 77, startSeconds: 100, startMicroseconds: 1)
                let appRoot = ProcessRecord(
                    identity: appRootIdentity,
                    parentPID: 1,
                    executablePath: descriptor.mainExecutableURL.path,
                    nameHint: "ChatGPT"
                )
                let appChild = ProcessRecord(
                    identity: lingeringIdentity,
                    parentPID: appRootIdentity.pid,
                    executablePath: "/bin/zsh",
                    nameHint: "zsh"
                )
                let orphanedAppChild = ProcessRecord(
                    identity: lingeringIdentity,
                    parentPID: 1,
                    executablePath: appChild.executablePath,
                    nameHint: appChild.nameHint
                )
                let launchedApp = ProcessRecord(
                    identity: ProcessIdentity(pid: 42, startSeconds: 101, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: descriptor.mainExecutableURL.path,
                    nameHint: "ChatGPT"
                )
                lingeringProcesses.install([appRoot, appChild])
                let provider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: lingeringProcesses,
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in
                        if lingeringProcesses.contains(pid: appRootIdentity.pid) {
                            return [appRootIdentity.pid]
                        }
                        return lingeringProcesses.contains(pid: launchedApp.identity.pid)
                            ? [launchedApp.identity.pid]
                            : []
                    },
                    requestApplicationTermination: { _ in
                        if lingeringProcesses.contains(pid: appRootIdentity.pid) {
                            lingeringProcesses.install(orphanedAppChild)
                            return [appRootIdentity.pid]
                        }
                        if lingeringProcesses.contains(pid: launchedApp.identity.pid) {
                            lingeringProcesses.install([])
                            return [launchedApp.identity.pid]
                        }
                        return []
                    },
                    confirmAppOwnedTermination: lingeringConfirmations.confirm,
                    requestProcessTermination: { lingeringProcesses.terminate($0) },
                    normalTerminationGracePolls: 0,
                    quiescenceSleep: { _ in },
                    launchApplication: { _ in
                        launches.record()
                        lingeringProcesses.install(launchedApp)
                        return launchedApp.identity.pid
                    }
                )
                let application = CLIApplication(provider: provider)

                let captured = await application.run(
                    arguments: ["profile", "capture", "--label", "B"],
                    mutationConfirmed: true
                )
                let listed = await application.run(arguments: ["profiles", "list"])
                let recovery = await application.run(arguments: ["recovery", "status"])
                let registry = try store.loadRegistry()
                let restoredActive = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedA = try store.loadCredential(for: profileA.id)
                guard let profileB = registry.profiles.first(where: { $0.label == "B" }) else {
                    throw TestFailure(description: "second profile B missing")
                }
                let launchCount = await MainActor.run { launches.count }
                let confirmationCountsAfterCapture = lingeringConfirmations.counts

                let files = DarwinDurableFileOperations()
                let activeBeforeSwitchTests = try files.read(at: authURL)
                _ = try files.replace(
                    contents: SensitiveBytes(Data(
                        #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id-rotated","access_token":"b-access-rotated","refresh_token":"b-refresh-rotated"}}"#.utf8
                    )),
                    at: authURL,
                    expecting: .exact(activeBeforeSwitchTests.identity)
                )
                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileB.id, profiles: registry.profiles)
                )

#if SPIKE_FAULT_INJECTION
                let faultProcesses = TerminableProcessSnapshotProvider()
                let faultLaunches = await MainActor.run { AppLaunchRecorder() }
                let faultConfirmations = TerminationConfirmationRecorder()
                let faultInitialRoot = ProcessRecord(
                    identity: ProcessIdentity(pid: 105, startSeconds: 304, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: descriptor.mainExecutableURL.path,
                    nameHint: "ChatGPT"
                )
                let faultTargetRoot = ProcessRecord(
                    identity: ProcessIdentity(pid: 103, startSeconds: 302, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: descriptor.mainExecutableURL.path,
                    nameHint: "ChatGPT"
                )
                let faultTransientChild = ProcessRecord(
                    identity: ProcessIdentity(pid: 106, startSeconds: 305, startMicroseconds: 1),
                    parentPID: faultTargetRoot.identity.pid,
                    executablePath: bundleURL.appendingPathComponent("Contents/Helpers/Codex Service").path,
                    nameHint: "Codex Service"
                )
                let faultSourceRoot = ProcessRecord(
                    identity: ProcessIdentity(pid: 104, startSeconds: 303, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: descriptor.mainExecutableURL.path,
                    nameHint: "ChatGPT"
                )
                faultProcesses.install(faultInitialRoot)
                let faultRunningPIDs = await MainActor.run {
                    RootExitDuringSnapshotPIDs(
                        processes: faultProcesses,
                        roots: [faultInitialRoot, faultTargetRoot, faultSourceRoot]
                    )
                }
                let faultApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: faultProcesses,
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in faultRunningPIDs.current() },
                        requestApplicationTermination: { _ in
                            let running = [faultInitialRoot, faultTargetRoot, faultSourceRoot]
                                .filter { faultProcesses.contains(pid: $0.identity.pid) }
                            if running.contains(faultInitialRoot) {
                                faultRunningPIDs.requestRootExit()
                            } else if running.contains(faultTargetRoot) {
                                faultProcesses.install([faultTargetRoot, faultTransientChild])
                            } else if running.contains(faultSourceRoot) {
                                running.forEach(faultProcesses.terminate)
                            }
                            return running.map(\.identity.pid)
                        },
                        confirmAppOwnedTermination: faultConfirmations.confirm,
                        requestProcessTermination: { process in
                            faultProcesses.terminate(process)
                        },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in
                            if faultProcesses.contains(pid: faultTransientChild.identity.pid) {
                                faultProcesses.install(faultTargetRoot)
                            }
                        },
                        launchApplication: { _ in
                            faultLaunches.record()
                            let root = faultLaunches.count == 1 ? faultTargetRoot : faultSourceRoot
                            if faultLaunches.count == 1 {
                                let files = DarwinDurableFileOperations()
                                let current = try files.read(at: authURL)
                                _ = try files.replace(
                                    contents: current.contents,
                                    at: authURL,
                                    expecting: .exact(current.identity)
                                )
                            }
                            faultProcesses.install(root)
                            return root.identity.pid
                        }
                    )
                )
                let faultAuthBefore = try Data(contentsOf: authURL)
                let faultRegistryBefore = try store.loadRegistry()
                let faultResult = await faultApplication.run(
                    arguments: ["switch", "--target", "A", "--test-post-launch-rollback"],
                    mutationConfirmed: true
                )
                let faultAuthAfter = try Data(contentsOf: authURL)
                let faultRegistryAfter = try store.loadRegistry()
                let faultRecovery = await faultApplication.run(arguments: ["recovery", "status"])
                let faultLaunchCount = await MainActor.run { faultLaunches.count }

                try expect(
                    faultResult.exitCode == 0,
                    "B-011 rollback test failed: \(faultResult.standardError) recovery=\(faultRecovery.standardOutput) launches=\(faultLaunchCount)"
                )
                try expect(faultResult.standardOutput.contains("rollback_test=passed"), "B-011 PASS missing")
                try expect(faultResult.standardOutput.contains("active=true label=B"), "B was not restored")
                try expect(faultAuthAfter == faultAuthBefore, "B-011 did not restore active auth")
                try expect(faultRegistryAfter == faultRegistryBefore, "B-011 changed active registry")
                try expect(faultRecovery.standardOutput == "recovery=none\n", "B-011 left recovery state")
                try expect(faultLaunchCount == 2, "B-011 did not launch target and restored source")
                try expect(faultConfirmations.counts == [1], "rollback survivor confirmation changed")
                try expect(
                    !faultProcesses.terminatedPIDs.contains(faultTransientChild.identity.pid),
                    "transient child received SIGTERM"
                )
                try expect(!faultProcesses.contains(pid: faultTargetRoot.identity.pid), "target app remained running")
                try expect(faultProcesses.contains(pid: faultSourceRoot.identity.pid), "source app was not relaunched")
#endif

                lingeringProcesses.install([appRoot, appChild])
                let switchedToA = await application.run(
                    arguments: ["switch", "--target", "A"],
                    mutationConfirmed: true
                )
                let registryAfterSwitchToA = try store.loadRegistry()
                let activeAfterSwitchToA = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedAAfterSwitchToA = try store.loadCredential(for: profileA.id)

                let switchArguments = ["switch", "--target", "B"]
                let deniedSwitch = await application.run(arguments: switchArguments)
                let switched = await application.run(
                    arguments: switchArguments,
                    mutationConfirmed: true
                )
                let switchedRegistry = try store.loadRegistry()
                let switchedActive = try CredentialBlob(validating: Data(contentsOf: authURL))
                let switchedStoredB = try store.loadCredential(for: profileB.id)
                let switchedList = await application.run(arguments: ["profiles", "list"])
                let switchedRecovery = await application.run(arguments: ["recovery", "status"])
                let switchedLaunchCount = await MainActor.run { launches.count }

                let independentProcesses = TerminableProcessSnapshotProvider()
                let independentConfirmations = TerminationConfirmationRecorder()
                let independentAppRoot = ProcessRecord(
                    identity: ProcessIdentity(pid: 87, startSeconds: 199, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: descriptor.mainExecutableURL.path,
                    nameHint: "ChatGPT"
                )
                let independentCodex = ProcessRecord(
                    identity: ProcessIdentity(pid: 88, startSeconds: 200, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: "/opt/homebrew/bin/codex",
                    nameHint: "codex"
                )
                independentProcesses.install(independentAppRoot)
                let blockedApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: independentProcesses,
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in
                            independentProcesses.contains(pid: independentAppRoot.identity.pid)
                                ? [independentAppRoot.identity.pid]
                                : []
                        },
                        requestApplicationTermination: { _ in
                            independentProcesses.install(independentCodex)
                            return [independentAppRoot.identity.pid]
                        },
                        confirmAppOwnedTermination: independentConfirmations.confirm,
                        requestProcessTermination: { independentProcesses.terminate($0) },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in }
                    )
                )
                let blockedAuthBefore = try Data(contentsOf: authURL)
                let blockedRegistryBefore = try store.loadRegistry()
                let blockedSwitch = await blockedApplication.run(
                    arguments: ["switch", "--target", "A"],
                    mutationConfirmed: true
                )
                let blockedAuthAfter = try Data(contentsOf: authURL)
                let blockedRegistryAfter = try store.loadRegistry()
                let blockedRecovery = await blockedApplication.run(arguments: ["recovery", "status"])

                let newlyDiscoveredProcesses = TerminableProcessSnapshotProvider()
                let newlyDiscoveredConfirmations = TerminationConfirmationRecorder()
                let newlyDiscoveredAppProcess = ProcessRecord(
                    identity: ProcessIdentity(pid: 90, startSeconds: 202, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: bundleURL.appendingPathComponent("Contents/Helpers/late-worker").path,
                    nameHint: "late-worker"
                )
                let newlyDiscoveredApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: newlyDiscoveredProcesses,
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in [] },
                        requestApplicationTermination: { _ in
                            newlyDiscoveredProcesses.install(newlyDiscoveredAppProcess)
                            return []
                        },
                        confirmAppOwnedTermination: newlyDiscoveredConfirmations.confirm,
                        requestProcessTermination: { newlyDiscoveredProcesses.terminate($0) },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in },
                        launchApplication: { _ in 42 }
                    )
                )
                let newlyDiscoveredAuthBefore = try Data(contentsOf: authURL)
                let newlyDiscoveredRegistryBefore = try store.loadRegistry()
                let newlyDiscoveredSwitch = await newlyDiscoveredApplication.run(
                    arguments: ["switch", "--target", "A"],
                    mutationConfirmed: true
                )
                let newlyDiscoveredAuthAfter = try Data(contentsOf: authURL)
                let newlyDiscoveredRegistryAfter = try store.loadRegistry()
                let newlyDiscoveredRecovery = await newlyDiscoveredApplication.run(
                    arguments: ["recovery", "status"]
                )

                let declinedProcesses = TerminableProcessSnapshotProvider()
                let declinedConfirmations = AsyncTerminationConfirmationRecorder(result: false)
                declinedProcesses.install(
                    ProcessRecord(
                        identity: ProcessIdentity(pid: 89, startSeconds: 201, startMicroseconds: 1),
                        parentPID: 1,
                        executablePath: bundleURL.appendingPathComponent("Contents/Helpers/declined-worker").path,
                        nameHint: "declined-worker"
                    )
                )
                let declinedApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: declinedProcesses,
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in [] },
                        requestApplicationTermination: { _ in [] },
                        confirmAppOwnedTermination: { count in
                            await declinedConfirmations.confirm(count)
                        },
                        requestProcessTermination: { declinedProcesses.terminate($0) },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in }
                    )
                )
                let declinedAuthBefore = try Data(contentsOf: authURL)
                let declinedRegistryBefore = try store.loadRegistry()
                let declinedSwitch = await declinedApplication.run(
                    arguments: ["switch", "--target", "A"],
                    mutationConfirmed: true
                )
                let declinedAuthAfter = try Data(contentsOf: authURL)
                let declinedRegistryAfter = try store.loadRegistry()
                let declinedRecovery = await declinedApplication.run(arguments: ["recovery", "status"])
                let declinedConfirmationCounts = await declinedConfirmations.counts

                let snapshotRacePIDs = await MainActor.run {
                    RunningPIDSequence([[], [42], []])
                }
                let snapshotRaceApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in snapshotRacePIDs.next() }
                    )
                )
                let snapshotRaceAuthBefore = try Data(contentsOf: authURL)
                let snapshotRaceRegistryBefore = try store.loadRegistry()
                let snapshotRaceSwitch = await snapshotRaceApplication.run(
                    arguments: ["switch", "--target", "A"],
                    mutationConfirmed: true
                )
                let snapshotRaceAuthAfter = try Data(contentsOf: authURL)
                let snapshotRaceRegistryAfter = try store.loadRegistry()
                let snapshotRaceRecovery = await snapshotRaceApplication.run(arguments: ["recovery", "status"])

                let rollbackProcesses = TerminableProcessSnapshotProvider()
                let forwardSurvivor = ProcessIdentity(pid: 101, startSeconds: 300, startMicroseconds: 1)
                let rollbackSurvivor = ProcessIdentity(pid: 102, startSeconds: 301, startMicroseconds: 1)
                rollbackProcesses.install(
                    ProcessRecord(
                        identity: forwardSurvivor,
                        parentPID: 1,
                        executablePath: bundleURL.appendingPathComponent("Contents/Helpers/forward-worker").path,
                        nameHint: "forward-worker"
                    )
                )
                let rollbackLaunches = await MainActor.run { AppLaunchRecorder() }
                let rollbackApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: rollbackProcesses,
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in [] },
                        requestApplicationTermination: { _ in [] },
                        confirmAppOwnedTermination: { _ in true },
                        requestProcessTermination: { rollbackProcesses.terminate($0) },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in },
                        launchApplication: { _ in
                            rollbackLaunches.record()
                            if rollbackLaunches.count == 1 {
                                rollbackProcesses.install(
                                    ProcessRecord(
                                        identity: rollbackSurvivor,
                                        parentPID: 1,
                                        executablePath: bundleURL
                                            .appendingPathComponent("Contents/Helpers/rollback-worker").path,
                                        nameHint: "rollback-worker"
                                    )
                                )
                                throw CodexAppLifecycleFailure.launchFailed
                            }
                            return 42
                        }
                    )
                )
                let rollbackAuthBefore = try Data(contentsOf: authURL)
                let rollbackRegistryBefore = try store.loadRegistry()
                let rolledBackSwitch = await rollbackApplication.run(
                    arguments: ["switch", "--target", "A"],
                    mutationConfirmed: true
                )
                let rollbackAuthAfter = try Data(contentsOf: authURL)
                let rollbackRegistryAfter = try store.loadRegistry()
                let rollbackRecovery = await rollbackApplication.run(arguments: ["recovery", "status"])

                try expect(
                    captured.exitCode == 0,
                    "second capture failed: \(captured.standardError) profiles=\(registry.profiles.count) activeA=\(registry.activeProfileID == profileA.id) recovery=\(recovery.standardOutput) launches=\(launchCount)"
                )
                try expect(captured.standardOutput.contains("active=false"), "second profile was reported active")
                try expect(registry.profiles.count == 2, "second profile was not registered")
                try expect(registry.activeProfileID == profileA.id, "second profile changed the active profile")
                try expect(profileB.email == "b@example.invalid", "second identity changed")
                try expect(restoredActive == storedA, "registration changed the active auth")
                try expect(storedA == credentialA, "capture changed the stored first profile")
                try expect(listed.standardOutput.contains("active=true label=A"), "first profile did not remain active")
                try expect(listed.standardOutput.contains("active=false label=B"), "second profile was reported active")
                try expect(recovery.standardOutput == "recovery=none\n", "second capture left recovery state")
                try expect(launchCount == 0, "second capture relaunched the app")
                try expect(confirmationCountsAfterCapture.isEmpty, "second capture requested termination approval")
                try expect(switchedToA.exitCode == 0, "B to A switch failed: \(switchedToA.standardError)")
                try expect(registryAfterSwitchToA.activeProfileID == profileA.id, "switch did not activate A")
                try expect(activeAfterSwitchToA == storedAAfterSwitchToA, "active auth does not match A")
                try expect(deniedSwitch.standardError == "error=confirmation_required\n", "switch ran without confirmation")
                try expect(switched.exitCode == 0, "A to B switch failed: \(switched.standardError)")
                try expect(switched.standardOutput.contains("active=true label=B"), "switch output did not activate B")
                try expect(switchedRegistry.activeProfileID == profileB.id, "registry did not activate B")
                try expect(switchedActive == switchedStoredB, "active auth does not match stored B")
                try expect(switchedList.standardOutput.contains("active=false label=A"), "A remained active")
                try expect(switchedList.standardOutput.contains("active=true label=B"), "B is not active")
                try expect(switchedRecovery.standardOutput == "recovery=none\n", "switch left recovery state")
                try expect(switchedLaunchCount == 2, "round-trip did not launch each target once")
                try expect(
                    lingeringProcesses.terminatedPIDs == [lingeringIdentity.pid],
                    "round-trip did not SIGTERM only the captured app-owned survivor"
                )
                try expect(
                    lingeringConfirmations.counts == [1],
                    "round-trip confirmation counts changed"
                )
                try expect(blockedSwitch.standardError == "error=process_blocked\n", "independent Codex was not blocked")
                try expect(independentConfirmations.counts.isEmpty, "independent Codex requested SIGTERM approval")
                try expect(independentProcesses.terminatedPIDs.isEmpty, "independent Codex received SIGTERM")
                try expect(blockedAuthAfter == blockedAuthBefore, "blocked switch changed active auth")
                try expect(blockedRegistryAfter == blockedRegistryBefore, "blocked switch changed the registry")
                try expect(blockedRecovery.standardOutput == "recovery=none\n", "blocked switch left recovery state")
                try expect(
                    newlyDiscoveredSwitch.standardError == "error=process_blocked\n",
                    "new app-owned process was not blocked"
                )
                try expect(
                    newlyDiscoveredConfirmations.counts.isEmpty,
                    "new app-owned process requested SIGTERM approval"
                )
                try expect(
                    newlyDiscoveredProcesses.terminatedPIDs.isEmpty,
                    "new app-owned process received SIGTERM"
                )
                try expect(
                    newlyDiscoveredAuthAfter == newlyDiscoveredAuthBefore,
                    "new app-owned process changed active auth"
                )
                try expect(
                    newlyDiscoveredRegistryAfter == newlyDiscoveredRegistryBefore,
                    "new app-owned process changed the registry"
                )
                try expect(
                    newlyDiscoveredRecovery.standardOutput == "recovery=none\n",
                    "new app-owned process left recovery state"
                )
                try expect(declinedSwitch.standardError == "error=process_blocked\n", "declined SIGTERM was not blocked")
                try expect(declinedConfirmationCounts == [1], "declined SIGTERM did not await one confirmation")
                try expect(declinedProcesses.terminatedPIDs.isEmpty, "declined SIGTERM still killed a process")
                try expect(declinedAuthAfter == declinedAuthBefore, "declined SIGTERM changed active auth")
                try expect(declinedRegistryAfter == declinedRegistryBefore, "declined SIGTERM changed the registry")
                try expect(declinedRecovery.standardOutput == "recovery=none\n", "declined SIGTERM left recovery state")
                try expect(snapshotRaceSwitch.standardError == "error=process_blocked\n", "snapshot race was hidden")
                try expect(snapshotRaceAuthAfter == snapshotRaceAuthBefore, "snapshot race changed active auth")
                try expect(snapshotRaceRegistryAfter == snapshotRaceRegistryBefore, "snapshot race changed the registry")
                try expect(snapshotRaceRecovery.standardOutput == "recovery=none\n", "snapshot race left recovery state")
                try expect(rolledBackSwitch.standardError == "error=operation_failed\n", "launch failure did not roll back")
                try expect(
                    rollbackProcesses.terminatedPIDs == [forwardSurvivor.pid, rollbackSurvivor.pid],
                    "rollback quit did not get its own SIGTERM attempt"
                )
                try expect(rollbackAuthAfter == rollbackAuthBefore, "rollback did not restore active auth")
                try expect(rollbackRegistryAfter == rollbackRegistryBefore, "rollback changed the active registry")
                try expect(rollbackRecovery.standardOutput == "recovery=none\n", "successful rollback left recovery state")

                let profileC = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "C",
                    email: "c@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
                let credentialC = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"c","tokens":{"id_token":"c-id","access_token":"c-access","refresh_token":"c-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(credentialC, for: profileC.id)
                let manualRegistry = try ProfileRegistry(
                    activeProfileID: profileA.id,
                    profiles: try store.loadRegistry().profiles + [profileC]
                )
                _ = try store.saveRegistry(manualRegistry)
                let manualCurrentAuth = try CredentialBlob(validating: Data(contentsOf: authURL))
                let manualStoredB = try store.loadCredential(for: profileB.id)
                try expect(
                    manualCurrentAuth == manualStoredB,
                    "manual recovery fixture does not have target B auth"
                )
                let manualStartedAt = Date(timeIntervalSince1970: 1_700_000_100)
                _ = try store.createJournalIfAbsent(
                    SwitchJournalRecord(
                        transactionID: UUID(),
                        phase: .rollbackFailed,
                        previousProfileID: profileA.id,
                        targetProfileID: profileB.id,
                        startedAt: manualStartedAt,
                        updatedAt: manualStartedAt
                    )
                )
                let staleVerificationHome = storeURL.appendingPathComponent(
                    "credential-verification-workspace",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: staleVerificationHome,
                    withIntermediateDirectories: false
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: staleVerificationHome.path
                )
                let staleEvidence = Data("stale verifier evidence".utf8)
                let staleEvidenceURL = staleVerificationHome.appendingPathComponent("auth.json")
                try staleEvidence.write(to: staleEvidenceURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: staleEvidenceURL.path
                )
                let staleCaptureVerificationHome = storeURL.appendingPathComponent(
                    "capture-verification-workspace",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: staleCaptureVerificationHome,
                    withIntermediateDirectories: false
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: staleCaptureVerificationHome.path
                )
                let manualBlockedProcesses = TerminableProcessSnapshotProvider()
                manualBlockedProcesses.install(
                    ProcessRecord(
                        identity: ProcessIdentity(pid: 203, startSeconds: 306, startMicroseconds: 1),
                        parentPID: 1,
                        executablePath: "/opt/homebrew/bin/codex",
                        nameHint: "codex"
                    )
                )
                let blockedManualApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: manualBlockedProcesses,
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in [] },
                        requestApplicationTermination: { _ in [] },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in }
                    )
                )
                let manualLaunches = await MainActor.run { AppLaunchRecorder() }
                let manualApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in manualLaunches.count > 0 ? [201] : [] },
                        requestApplicationTermination: { _ in [] },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in },
                        launchApplication: { _ in
                            manualLaunches.record()
                            return 201
                        }
                    )
                )
                let manualArguments = ["recovery", "restore", "--profile", "A"]
                let deniedManualRecovery = await manualApplication.run(arguments: manualArguments)
                let wrongManualRecovery = await manualApplication.run(
                    arguments: ["recovery", "restore", "--profile", "B"],
                    mutationConfirmed: true
                )
                let blockedManualRecovery = await blockedManualApplication.run(
                    arguments: manualArguments,
                    mutationConfirmed: true
                )
                let journalAfterWrongManualRecovery = try store.loadJournalIfPresent()
                let authAfterWrongManualRecovery = try CredentialBlob(validating: Data(contentsOf: authURL))
                let staleWorkspacePreserved = FileManager.default.fileExists(
                    atPath: staleVerificationHome.path
                ) && FileManager.default.fileExists(atPath: staleCaptureVerificationHome.path)
                let restoredManualRecovery = await manualApplication.run(
                    arguments: manualArguments,
                    mutationConfirmed: true
                )
                let manualRecoveryStatus = await manualApplication.run(arguments: ["recovery", "status"])
                let restoredManualRegistry = try store.loadRegistry()
                let restoredManualAuth = try CredentialBlob(validating: Data(contentsOf: authURL))
                let manualStoredA = try store.loadCredential(for: profileA.id)
                let manualStoredC = try store.loadCredential(for: profileC.id)
                let manualLaunchCount = await MainActor.run { manualLaunches.count }
                let recoveryEvidenceURL = storeURL.appendingPathComponent(
                    "recovery-evidence",
                    isDirectory: true
                )
                let recoveryEvidenceHomes = try FileManager.default.contentsOfDirectory(
                    at: recoveryEvidenceURL,
                    includingPropertiesForKeys: nil
                )
                let staleEvidencePreserved = recoveryEvidenceHomes.contains {
                    (try? Data(contentsOf: $0.appendingPathComponent("auth.json"))) == staleEvidence
                }

                try expect(
                    deniedManualRecovery.standardError == "error=confirmation_required\n",
                    "manual recovery ran without confirmation"
                )
                try expect(
                    wrongManualRecovery.standardError == "error=recovery_unavailable\n",
                    "manual recovery accepted the journal target"
                )
                try expect(
                    journalAfterWrongManualRecovery?.phase == .rollbackFailed,
                    "rejected manual recovery removed the journal"
                )
                try expect(authAfterWrongManualRecovery == manualStoredB, "rejected manual recovery changed auth")
                try expect(
                    staleWorkspacePreserved,
                    "rejected manual recovery removed the stale workspace"
                )
                try expect(
                    blockedManualRecovery.standardError == "error=process_blocked\n",
                    "manual recovery ignored an independent Codex process"
                )
                try expect(
                    restoredManualRecovery.exitCode == 0,
                    "manual recovery failed: \(restoredManualRecovery.standardError)"
                )
                try expect(
                    restoredManualRecovery.standardOutput.contains("active=true label=A"),
                    "manual recovery did not report A"
                )
                try expect(restoredManualRegistry.activeProfileID == profileA.id, "manual recovery did not restore registry A")
                try expect(restoredManualRegistry.profiles == manualRegistry.profiles, "manual recovery dropped profile C")
                try expect(
                    restoredManualAuth == manualStoredA,
                    "manual recovery did not restore auth A"
                )
                try expect(manualStoredC == credentialC, "manual recovery changed profile C")
                try expect(manualRecoveryStatus.standardOutput == "recovery=none\n", "manual recovery left journal")
                try expect(manualLaunchCount == 1, "manual recovery did not relaunch A")
                try expect(
                    !FileManager.default.fileExists(atPath: staleVerificationHome.path),
                    "manual recovery left the stale workspace"
                )
                try expect(
                    !FileManager.default.fileExists(atPath: staleCaptureVerificationHome.path),
                    "manual recovery left the stale capture workspace"
                )
                try expect(recoveryEvidenceHomes.count == 2, "manual recovery lost verifier evidence")
                try expect(staleEvidencePreserved, "manual recovery changed verifier evidence")
            }
        },
        TestCase("CLI additional capture rejects an unverified active source") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeB = Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
                )
                try activeB.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let profileA = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "person@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
                let credentialA = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(credentialA, for: profileA.id)
                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileA.id, profiles: [profileA])
                )

                let verificationHome = storeURL.appendingPathComponent(
                    "credential-verification-workspace",
                    isDirectory: true
                )
                let probeCountURL = directory.appendingPathComponent("probe-count")
                let executable = try makeCaptureAppServer(
                    in: directory,
                    rotateToOtherAccount: false,
                    failProbeHomeURL: verificationHome,
                    probeCountURL: probeCountURL,
                    requiredJournalURL: storeURL.appendingPathComponent("switch-journal.json")
                )
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let launches = await MainActor.run { AppLaunchRecorder() }
                let application = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in [] },
                        launchApplication: { _ in
                            launches.record()
                            return 42
                        }
                    )
                )

                let captured = await application.run(
                    arguments: ["profile", "capture", "--label", "B"],
                    mutationConfirmed: true
                )
                let registry = try store.loadRegistry()
                let journal = try store.loadJournalIfPresent()
                let captureProfileID = try store.loadCaptureProfileIDIfPresent()
                let activeCredential = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedA = try store.loadCredential(for: profileA.id)
                let launchCount = await MainActor.run { launches.count }
                let captureProbeCount = try String(contentsOf: probeCountURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                try expect(captured.exitCode == 1, "unverified source was accepted")
                try expect(captureProbeCount == "1", "source verification did not fail at the first probe")
                try expect(registry.profiles == [profileA], "failed capture changed the registry")
                try expect(registry.activeProfileID == profileA.id, "failed capture changed the active profile")
                try expect(journal == nil, "failed capture left recovery evidence")
                try expect(captureProfileID == nil, "failed capture left the capture marker")
                try expect(activeCredential != storedA, "fixture unexpectedly matched the active source")
                try expect(storedA == credentialA, "failed capture changed stored A")
                try expect(launchCount == 0, "failed capture launched the app")
                try expect(
                    !FileManager.default.fileExists(atPath: verificationHome.path),
                    "failed capture left the verifier workspace"
                )
            }
        },
        TestCase("Local provider finishes committed capture crash windows forward") {
            try await withCaptureTemporaryDirectory { directory in
                for phase in [SwitchPhase.targetValidated, .targetVerified] {
                    let phaseDirectory = directory.appendingPathComponent(phase.rawValue, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: phaseDirectory,
                        withIntermediateDirectories: false
                    )
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o700],
                        ofItemAtPath: phaseDirectory.path
                    )
                    let fixture = try makeCommittedCaptureRecoveryFixture(
                        in: phaseDirectory,
                        phase: phase
                    )
                    let store = try SpikeStore.openExisting(at: fixture.storeURL)
                    let sourceBefore = try store.loadCredential(for: fixture.previous.id)
                    let targetBefore = try store.loadCredential(for: fixture.target.id)
                    let launches = await MainActor.run { AppLaunchRecorder() }
                    let provider = LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [] },
                        launchApplication: { _ in
                            launches.record()
                            return 42
                        }
                    )

                    let outcome = try await provider.recoverPendingTransaction()
                    let registry = try store.loadRegistry()
                    let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                    let sourceAfter = try store.loadCredential(for: fixture.previous.id)
                    let targetAfter = try store.loadCredential(for: fixture.target.id)
                    let marker = try store.loadCaptureProfileIDIfPresent()
                    let journal = try store.loadJournalIfPresent()
                    let evidence = try store.loadJournalFinalizationEvidenceIfPresent()
                    let launchCount = await MainActor.run { launches.count }

                    try expect(
                        outcome == .completed(.commitVerifiedTarget),
                        "\(phase.rawValue) capture did not recover forward"
                    )
                    try expect(registry.activeProfileID == fixture.target.id, "capture lost active B")
                    try expect(active == targetBefore && targetAfter == targetBefore, "capture changed B")
                    try expect(sourceAfter == sourceBefore, "capture changed stored A")
                    try expect(marker == nil && journal == nil && evidence == nil, "capture left recovery state")
                    try expect(launchCount == 0, "capture recovery launched the app")
                }

                let raceDirectory = directory.appendingPathComponent("targetValidated-race", isDirectory: true)
                try FileManager.default.createDirectory(at: raceDirectory, withIntermediateDirectories: false)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: raceDirectory.path
                )
                let raceFixture = try makeCommittedCaptureRecoveryFixture(
                    in: raceDirectory,
                    phase: .targetValidated
                )
                let raceStore = try SpikeStore.openExisting(at: raceFixture.storeURL)
                let changedBData = Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"changed-b-id","access_token":"changed-b-access","refresh_token":"changed-b-refresh"}}"#.utf8
                )
                let changedB = try CredentialBlob(validating: changedBData)
                let storedTargetBefore = try raceStore.loadCredential(for: raceFixture.target.id)
                let racedProvider = LocalCLIDataProvider(
                    storeURL: raceFixture.storeURL,
                    activeAuthURL: raceFixture.authURL,
                    processProvider: MutatingProcessSnapshotProvider(
                        mutationCall: 3,
                        url: raceFixture.authURL,
                        contents: changedBData
                    ),
                    locateApp: { raceFixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                do {
                    _ = try await racedProvider.recoverPendingTransaction()
                    throw TestFailure(description: "capture auth race was committed")
                } catch let failure as RecoveryCoordinatorFailure {
                    try expect(failure == .executionFailed, "capture auth race returned the wrong STOP")
                }
                let racedRegistry = try raceStore.loadRegistry()
                let racedActive = try CredentialBlob(validating: Data(contentsOf: raceFixture.authURL))
                let racedStoredTarget = try raceStore.loadCredential(for: raceFixture.target.id)
                let racedMarker = try raceStore.loadCaptureProfileIDIfPresent()
                let racedJournal = try raceStore.loadJournalIfPresent()
                let racedEvidence = try raceStore.loadJournalFinalizationEvidenceIfPresent()

                try expect(racedRegistry.activeProfileID == raceFixture.target.id, "race changed registry")
                try expect(racedActive == changedB, "race fixture did not replace active auth")
                try expect(racedStoredTarget == storedTargetBefore, "race changed stored target")
                try expect(racedMarker == raceFixture.target.id, "race removed capture provenance")
                try expect(racedJournal?.phase == .targetValidated, "race advanced the commit point")
                try expect(racedEvidence == nil, "race created finalization evidence")
            }
        },
        TestCase("Local provider never rolls back a targetVerified capture") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeBData = Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
                )
                let activeB = try CredentialBlob(validating: activeBData)
                try activeBData.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let profileA = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "person@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
                let storedA = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(storedA, for: profileA.id)
                _ = try store.saveRegistry(ProfileRegistry(activeProfileID: profileA.id, profiles: [profileA]))

                let executable = try makeCaptureAppServer(in: directory, rotateToOtherAccount: false)
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let unlinkFailure = DurableFileFailure(
                    mutation: .remove,
                    stage: .unlink,
                    errno: EIO,
                    certainty: .destinationUnchanged
                )
                let provider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] },
                    removeJournalFile: { throw unlinkFailure }
                )
                let profileBID = try await provider.prepareCapture()
                let capturedB = try await provider.readActiveCredential()
                let profileB = ProfileMetadata(
                    id: profileBID,
                    label: "B",
                    email: "b@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
                var commitFailed = false
                do {
                    try await provider.commit(profile: profileB, credential: capturedB)
                } catch {
                    commitFailed = true
                }
                var abortFailed = false
                do {
                    try await provider.abortCapture()
                } catch {
                    abortFailed = true
                }

                let registry = try store.loadRegistry()
                let activeAfter = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedAAfter = try store.loadCredential(for: profileA.id)
                let storedBAfter = try store.loadCredential(for: profileB.id)
                let journalBeforeRestart = try store.loadJournalIfPresent()
                let evidenceBeforeRestart = try store.loadJournalFinalizationEvidenceIfPresent()
                let restarted = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let status = try await restarted.recoveryStatus()
                let journalAfterRestart = try store.loadJournalIfPresent()
                let evidenceAfterRestart = try store.loadJournalFinalizationEvidenceIfPresent()

                try expect(commitFailed, "injected journal failure did not interrupt capture")
                try expect(!abortFailed, "targetVerified capture attempted rollback")
                try expect(registry.activeProfileID == profileB.id, "finalization failure rolled registry back")
                try expect(activeAfter == activeB && storedBAfter == activeB, "finalization failure changed B")
                try expect(storedAAfter == storedA, "finalization failure changed stored A")
                try expect(journalBeforeRestart?.phase == .targetVerified, "commit point was downgraded")
                try expect(evidenceBeforeRestart?.journalPhase == .targetVerified, "commit evidence changed")
                try expect(status == .none, "restart did not finish targetVerified finalization")
                try expect(
                    journalAfterRestart == nil && evidenceAfterRestart == nil,
                    "restart left finalization evidence"
                )
            }
        },
        TestCase("CLI capture stores a third profile inactive and rejects a fourth") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeB = Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
                )
                try activeB.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
                let profileA = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "person@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
                let profileB = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "B",
                    email: "b@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
                let credentialA = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                ))
                let credentialB = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(credentialA, for: profileA.id)
                _ = try store.saveCredential(credentialB, for: profileB.id)
                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileB.id, profiles: [profileA, profileB])
                )

                let executable = try makeCaptureAppServer(
                    in: directory,
                    rotateToOtherAccount: false,
                    loginAccount: "c"
                )
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let launches = await MainActor.run { AppLaunchRecorder() }
                let application = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in [] },
                        launchApplication: { _ in
                            launches.record()
                            return 42
                        }
                    )
                )

                let captured = await application.run(
                    arguments: ["profile", "capture", "--label", "C"],
                    mutationConfirmed: true
                )
                let registry = try store.loadRegistry()
                guard let profileC = registry.profiles.first(where: { $0.label == "C" }) else {
                    throw TestFailure(description: "third profile C missing")
                }
                let activeAfterCapture = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedA = try store.loadCredential(for: profileA.id)
                let storedB = try store.loadCredential(for: profileB.id)
                let storedC = try store.loadCredential(for: profileC.id)
                let recoveryAfterCapture = await application.run(arguments: ["recovery", "status"])
                let launchCountAfterCapture = await MainActor.run { launches.count }

                let externalD = Data(
                    #"{"auth_mode":"chatgpt","test_account":"d","tokens":{"id_token":"d-id","access_token":"d-access","refresh_token":"d-refresh"}}"#.utf8
                )
                try externalD.write(to: authURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
                let authBeforeRejection = try CredentialBlob(validating: externalD)
                let rejected = await application.run(
                    arguments: ["profile", "capture", "--label", "D"],
                    mutationConfirmed: true
                )
                let registryAfterRejection = try store.loadRegistry()
                let authAfterRejection = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedAAfterRejection = try store.loadCredential(for: profileA.id)
                let storedBAfterRejection = try store.loadCredential(for: profileB.id)
                let storedCAfterRejection = try store.loadCredential(for: profileC.id)
                let recoveryAfterRejection = await application.run(arguments: ["recovery", "status"])
                let launchCountAfterRejection = await MainActor.run { launches.count }

                try expect(captured.exitCode == 0, "third capture failed: \(captured.standardError)")
                try expect(captured.standardOutput.contains("active=false label=C"), "third profile was reported active")
                try expect(registry.profiles.map(\.label) == ["A", "B", "C"], "third profile order changed")
                try expect(registry.activeProfileID == profileB.id, "third profile changed active B")
                try expect(activeAfterCapture == storedB, "third capture changed active B auth")
                try expect(storedA == credentialA, "third capture changed profile A")
                try expect(storedB == credentialB, "third capture changed profile B")
                try expect(storedC != credentialB, "third credential was not isolated")
                try expect(recoveryAfterCapture.standardOutput == "recovery=none\n", "third capture left recovery state")
                try expect(launchCountAfterCapture == 0, "third capture launched the app")
                try expect(rejected.standardError == "error=profile_already_exists\n", "fourth profile was accepted")
                try expect(registryAfterRejection == registry, "fourth capture changed the registry")
                try expect(authAfterRejection == authBeforeRejection, "fourth capture changed active auth")
                try expect(storedAAfterRejection == storedA, "fourth capture changed profile A")
                try expect(storedBAfterRejection == storedB, "fourth capture changed profile B")
                try expect(storedCAfterRejection == storedC, "fourth capture changed profile C")
                try expect(recoveryAfterRejection.standardOutput == "recovery=none\n", "fourth capture left recovery state")
                try expect(launchCountAfterRejection == launchCountAfterCapture, "fourth capture launched the app")
            }
        },
        TestCase("CLI marks an identity-invalid switch target for relogin") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeA = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                )
                try activeA.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let profileA = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "person@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
                let profileB = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "B",
                    email: "b@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
                let invalidB = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"stale-id","access_token":"stale-access","refresh_token":"stale-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(try CredentialBlob(validating: activeA), for: profileA.id)
                _ = try store.saveCredential(invalidB, for: profileB.id)
                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileA.id, profiles: [profileA, profileB])
                )

                let executable = try makeCaptureAppServer(in: directory, rotateToOtherAccount: false)
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let provider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                let result = await CLIApplication(provider: provider).run(
                    arguments: ["switch", "--target", "B"],
                    mutationConfirmed: true
                )
                let registry = try store.loadRegistry()
                let active = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedA = try store.loadCredential(for: profileA.id)
                let storedB = try store.loadCredential(for: profileB.id)
                let journal = try store.loadJournalIfPresent()

                try expect(result.standardError == "error=operation_failed\n", "identity failure changed")
                try expect(registry.activeProfileID == profileA.id, "identity failure activated B")
                try expect(
                    registry.profiles.first(where: { $0.id == profileB.id })?.needsRelogin == true,
                    "identity-invalid B was not marked for relogin"
                )
                try expect(storedB == invalidB, "invalid B was overwritten")
                try expect(active == storedA, "active A was not recovered")
                try expect(journal == nil, "identity failure left recovery pending")
            }
        },
        TestCase("CLI switch waits for delayed application PID visibility") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let target = ProfileMetadata(
                    id: fixture.target.id,
                    label: fixture.target.label,
                    email: fixture.target.email,
                    planType: fixture.target.planType,
                    needsRelogin: false,
                    createdAt: fixture.target.createdAt,
                    updatedAt: fixture.target.updatedAt
                )
                _ = try store.saveRegistry(
                    ProfileRegistry(
                        activeProfileID: fixture.source.id,
                        profiles: [fixture.source, target]
                    )
                )
                try fixture.sourceAuthData.write(to: fixture.authURL)

                let launchVisibility = await MainActor.run {
                    DelayedLaunchPIDVisibility(pid: 42)
                }
                let application = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in launchVisibility.current() },
                        requestApplicationTermination: { _ in [] },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in },
                        launchApplication: { _ in launchVisibility.launch() }
                    )
                )

                let result = await application.run(
                    arguments: ["switch", "--target", target.label],
                    mutationConfirmed: true
                )
                let registry = try store.loadRegistry()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedTarget = try store.loadCredential(for: target.id)
                let journal = try store.loadJournalIfPresent()
                let launchCount = await MainActor.run { launchVisibility.launchCount }
                let observations = await MainActor.run { launchVisibility.observations }

                try expect(result.exitCode == 0, "delayed PID visibility failed: \(result.standardError)")
                try expect(registry.activeProfileID == target.id, "delayed launch did not activate B")
                try expect(active == storedTarget, "delayed launch left the wrong active credential")
                try expect(journal == nil, "delayed launch left recovery pending")
                try expect(launchCount == 1, "delayed launch retried the application")
                try expect(
                    Array(observations.prefix(3)) == [[], [], [42]],
                    "launch PID visibility was not delayed for two checks"
                )
            }
        },
        TestCase("Local provider repairs a pending registered profile with a credential") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let authBefore = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let quitRequests = await MainActor.run { AppLaunchRecorder() }
                let launches = await MainActor.run { AppLaunchRecorder() }
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [42] },
                    requestApplicationTermination: { _ in
                        quitRequests.record()
                        return [42]
                    },
                    launchApplication: { _ in
                        launches.record()
                        return 42
                    }
                )

                _ = try await provider.reloginProfile(target: fixture.target.id.description)

                let registry = try store.loadRegistry()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let storedTarget = try store.loadCredential(for: fixture.target.id)
                let journal = try store.loadJournalIfPresent()
                let authAfter = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let quitCount = await MainActor.run { quitRequests.count }
                let launchCount = await MainActor.run { launches.count }

                try expect(registry.activeProfileID == fixture.source.id, "relogin changed the active profile")
                try expect(
                    registry.profiles.first(where: { $0.id == fixture.target.id })?.needsRelogin == false,
                    "relogin target kept its marker"
                )
                try expect(active == fixture.sourceCredential, "relogin changed the public active auth data")
                try expect(authAfter == authBefore, "relogin rewrote the public active auth file")
                try expect(storedSource == fixture.sourceCredential, "relogin changed the source credential")
                try expect(storedTarget == fixture.refreshedTargetCredential, "relogin stored unexpected target bytes")
                try expect(journal == nil, "relogin left recovery pending")
                try expect(quitCount == 0, "relogin terminated the running official app")
                try expect(launchCount == 0, "relogin relaunched the running official app")
            }
        },
        TestCase("Local provider repairs a pending registered profile without a credential") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory, activeAuthIsSource: true)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                _ = try store.removeCredential(for: fixture.target.id)
                let authBefore = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [42] }
                )

                _ = try await provider.reloginProfile(target: fixture.target.id.description)

                let registry = try store.loadRegistry()
                let storedTarget = try store.loadCredential(for: fixture.target.id)
                let authAfter = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                try expect(registry.activeProfileID == fixture.source.id, "pending repair changed active A")
                try expect(
                    registry.profiles.first(where: { $0.id == fixture.target.id })?.needsRelogin == false,
                    "pending repair kept the relogin marker"
                )
                try expect(storedTarget == fixture.refreshedTargetCredential, "pending repair stored wrong bytes")
                try expect(authAfter == authBefore, "pending repair changed public auth")
            }
        },
        TestCase("Local provider registers an isolated account without changing active source") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true,
                    isolatedLoginAccount: "c"
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let sourceBefore = try store.loadCredential(for: fixture.source.id)
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let authBefore = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let processes = TerminableProcessSnapshotProvider()
                let app = ProcessRecord(
                    identity: ProcessIdentity(pid: 42, startSeconds: 101, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: fixture.descriptor.mainExecutableURL.path,
                    nameHint: "ChatGPT"
                )
                processes.install(app)
                let quitRequests = await MainActor.run { AppLaunchRecorder() }
                let launches = await MainActor.run { AppLaunchRecorder() }
                let credentials = RegistrationIntentCredentialStore(storeURL: fixture.storeURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    credentialStore: credentials,
                    processProvider: processes,
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in processes.contains(pid: app.identity.pid) ? [42] : [] },
                    requestApplicationTermination: { _ in
                        quitRequests.record()
                        processes.install([])
                        return [42]
                    },
                    launchApplication: { _ in
                        launches.record()
                        processes.install(app)
                        return 42
                    }
                )

                let captured = try await provider.captureProfile(label: "C")

                let registry = try store.loadRegistry()
                guard let profileC = registry.profiles.first(where: { $0.label == "C" }) else {
                    throw TestFailure(description: "isolated profile C missing")
                }
                let expectedC = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"c","tokens":{"id_token":"c-id-rotated","access_token":"c-access-rotated","refresh_token":"c-refresh-rotated"}}"#.utf8
                ))
                let storedC = try store.loadCredential(for: profileC.id)
                let sourceAfter = try store.loadCredential(for: fixture.source.id)
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                let authAfter = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let journal = try store.loadJournalIfPresent()
                let captureProfileID = try store.loadCaptureProfileIDIfPresent()
                let quitCount = await MainActor.run { quitRequests.count }
                let launchCount = await MainActor.run { launches.count }

                try expect(captured.id == profileC.id && !captured.active, "isolated capture reported C active")
                try expect(registry.profiles.map(\.label) == ["A", "B", "C"], "isolated capture changed order")
                try expect(registry.activeProfileID == fixture.source.id, "isolated capture changed active profile")
                try expect(sourceAfter == sourceBefore, "isolated capture changed A")
                try expect(targetAfter == targetBefore, "isolated capture changed B")
                try expect(storedC == expectedC, "isolated capture stored unexpected C bytes")
                try expect(authAfter == authBefore, "isolated capture rewrote public auth")
                try expect(journal == nil, "isolated capture created a switch journal")
                try expect(captureProfileID == nil, "isolated capture left a capture marker")
                try expect(!FileManager.default.fileExists(atPath: fixture.storeURL.appendingPathComponent("isolated-login-workspace").path), "isolated capture left its workspace")
                try expect(quitCount == 0, "isolated capture terminated the official app")
                try expect(launchCount == 0, "isolated capture relaunched the official app")
                try expect(processes.contains(pid: app.identity.pid), "isolated capture disturbed the official app")
                try expect(registryBefore.profiles == Array(registry.profiles.prefix(2)), "isolated capture changed existing metadata")
                try expect(credentials.pendingProfileIDs == [profileC.id], "C credential preceded its durable intent")
            }
        },
        TestCase("Local provider replaces a file-less inactive profile through isolated registration") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true,
                    isolatedLoginAccount: "b"
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                _ = try store.removeCredential(for: fixture.source.id)
                _ = try store.removeCredential(for: fixture.target.id)
                let authBefore = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [42] }
                )

                let removed = try await provider.removeProfile(fixture.target.id)
                let captured = try await provider.captureProfile(label: "B")

                let registry = try store.loadRegistry()
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let storedTarget = try store.loadCredential(for: captured.id)
                let authAfter = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                try expect(removed.id == fixture.target.id, "file-less B was not removed")
                try expect(registry.activeProfileID == fixture.source.id, "registration changed active A")
                try expect(registry.profiles.map(\.label) == ["A", "B"], "B was not re-registered")
                try expect(!captured.active, "registration activated B")
                try expect(storedSource == fixture.sourceCredential, "current A auth was not seeded")
                try expect(storedTarget == fixture.refreshedTargetCredential, "B credential changed")
                try expect(authAfter == authBefore, "registration rewrote public auth")
            }
        },
        TestCase("Local provider rolls back isolated credential commits after an active auth race") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true,
                    isolatedLoginAccount: "c"
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let sourceBefore = try store.loadCredential(for: fixture.source.id)
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let externalAuth = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"external-id","access_token":"external-access","refresh_token":"external-refresh"}}"#.utf8
                )
                let credentials = RegistrationIntentCredentialStore(
                    storeURL: fixture.storeURL,
                    onSave: { try externalAuth.write(to: fixture.authURL) }
                )
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    credentialStore: credentials,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [42] }
                )

                do {
                    _ = try await provider.captureProfile(label: "C")
                    throw TestFailure(description: "active auth race completed registration")
                } catch let failure as TestFailure {
                    throw failure
                } catch {}

                let registryAfter = try store.loadRegistry()
                let sourceAfter = try store.loadCredential(for: fixture.source.id)
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                let pendingIDs = credentials.pendingProfileIDs
                let authAfter = try Data(contentsOf: fixture.authURL)
                try expect(registryAfter == registryBefore, "active auth race kept pending C metadata")
                try expect(sourceAfter == sourceBefore, "active auth race changed A credential")
                try expect(targetAfter == targetBefore, "active auth race changed B credential")
                try expect(authAfter == externalAuth, "active auth race was overwritten")
                try expect(pendingIDs.count == 1, "active auth race did not reach the C credential boundary")
                try expect(
                    (try? credentials.loadCredential(for: pendingIDs[0])) == nil,
                    "active auth race left an orphan C credential"
                )
            }
        },
        TestCase("Local provider rolls relogin credential back after an active auth race") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory, activeAuthIsSource: true)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let sourceBefore = try store.loadCredential(for: fixture.source.id)
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let externalAuth = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"external-id","access_token":"external-access","refresh_token":"external-refresh"}}"#.utf8
                )
                let credentials = RegistrationIntentCredentialStore(
                    storeURL: fixture.storeURL,
                    onSave: { try externalAuth.write(to: fixture.authURL) }
                )
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    credentialStore: credentials,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [42] }
                )

                do {
                    _ = try await provider.reloginProfile(target: fixture.target.id.description)
                    throw TestFailure(description: "active auth race completed relogin")
                } catch let failure as TestFailure {
                    throw failure
                } catch {}

                let registryAfter = try store.loadRegistry()
                let sourceAfter = try store.loadCredential(for: fixture.source.id)
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                let authAfter = try Data(contentsOf: fixture.authURL)
                try expect(registryAfter == registryBefore, "active auth race cleared the B marker")
                try expect(sourceAfter == sourceBefore, "active auth race changed A credential")
                try expect(targetAfter == targetBefore, "active auth race did not restore B credential")
                try expect(authAfter == externalAuth, "active auth race was overwritten")
            }
        },
        TestCase("Local provider does not carry an idle cancellation into registration") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true,
                    isolatedLoginAccount: "c"
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let authBefore = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [42] }
                )

                await provider.cancelProfileLogin()
                let captured = try await provider.captureProfile(label: "C")

                let registryAfter = try store.loadRegistry()
                let authAfter = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                try expect(captured.label == "C" && !captured.active, "idle cancellation reached registration")
                try expect(registryAfter.profiles.count == registryBefore.profiles.count + 1, "registration was lost")
                try expect(authAfter == authBefore, "registration changed public auth")
                try expect(
                    !FileManager.default.fileExists(
                        atPath: fixture.storeURL.appendingPathComponent("isolated-login-workspace").path
                    ),
                    "registration left a login workspace"
                )
            }
        },
        TestCase("Local provider preserves all account state when isolated login exits unsuccessfully") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true,
                    isolatedLoginExitCode: 23
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let sourceBefore = try store.loadCredential(for: fixture.source.id)
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let authBefore = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [42] }
                )

                do {
                    _ = try await provider.reloginProfile(target: fixture.target.id.description)
                    throw TestFailure(description: "failed isolated login was accepted")
                } catch let failure as CodexLoginFailure {
                    try expect(failure.code == .abnormalExit, "failed login returned the wrong code")
                    try expect(failure.exitCode == 23, "failed login lost its exit code")
                    try expect(
                        failure.childDisposition == .confirmedExited,
                        "failed login child exit was not confirmed"
                    )
                }

                let registryAfter = try store.loadRegistry()
                let sourceAfter = try store.loadCredential(for: fixture.source.id)
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                let authAfter = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let journalAfter = try store.loadJournalIfPresent()
                try expect(registryAfter == registryBefore, "failed login changed registry")
                try expect(sourceAfter == sourceBefore, "failed login changed A")
                try expect(targetAfter == targetBefore, "failed login changed B")
                try expect(authAfter == authBefore, "failed login changed public auth")
                try expect(journalAfter == nil, "failed login created a journal")
                try expect(
                    !FileManager.default.fileExists(
                        atPath: fixture.storeURL.appendingPathComponent("isolated-login-workspace").path
                    ),
                    "failed login left its private workspace"
                )
            }
        },
        TestCase("Local provider completes targetVerified relogin after restart") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(
                    fixture,
                    phase: .targetVerified
                )
                let launches = await MainActor.run { AppLaunchRecorder() }
                let restarted = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    launchApplication: { _ in
                        await MainActor.run { launches.record() }
                        return 501
                    }
                )

                let pending = try await restarted.recoveryStatus()
                let registryBeforeRecovery = try store.loadRegistry()
                let activeBeforeRecovery = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let journalBeforeRecovery = try store.loadJournalIfPresent()
                let outcome = try await restarted.recoverPendingTransaction()
                let status = try await restarted.recoveryStatus()
                let registry = try store.loadRegistry()
                let journal = try store.loadJournalIfPresent()
                let evidence = try store.loadJournalFinalizationEvidenceIfPresent()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let storedTarget = try store.loadCredential(for: fixture.target.id)
                let launchCount = await MainActor.run { launches.count }

                try expect(
                    pending == .pending(
                        transactionID: crash.journal.transactionID.uuidString,
                        phase: .targetVerified,
                        previousProfileID: fixture.source.id
                    ),
                    "read-only status changed targetVerified relogin"
                )
                try expect(
                    registryBeforeRecovery.activeProfileID == fixture.source.id,
                    "read-only status activated B"
                )
                try expect(activeBeforeRecovery == crash.activeTarget, "read-only status changed active auth")
                try expect(journalBeforeRecovery == crash.journal, "read-only status changed journal")
                try expect(
                    outcome == .completed(.commitVerifiedTarget),
                    "restart chose the wrong targetVerified recovery"
                )
                try expect(status == .none, "restart did not finish targetVerified relogin")
                try expect(registry.activeProfileID == fixture.target.id, "restart did not activate B")
                try expect(
                    registry.profiles.first(where: { $0.id == fixture.target.id })?.needsRelogin == false,
                    "restart restored B marker"
                )
                try expect(journal == nil && evidence == nil, "restart left targetVerified evidence")
                try expect(active == storedTarget, "restart lost exact B auth")
                try expect(storedSource == fixture.sourceCredential, "restart changed A credential")
                try expect(storedTarget == crash.activeTarget, "restart changed verified B")
                try expect(launchCount == 0, "restart launched the app")
            }
        },
        TestCase("Local provider finalizes an already active targetVerified relogin") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(fixture, phase: .targetVerified)
                let preparedRegistry = try store.loadRegistry()
                _ = try store.saveRegistry(
                    ProfileRegistry(
                        activeProfileID: fixture.target.id,
                        profiles: preparedRegistry.profiles
                    )
                )
                let sourceBefore = try store.loadCredential(for: fixture.source.id)
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let launches = await MainActor.run { AppLaunchRecorder() }
                let restarted = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    launchApplication: { _ in
                        await MainActor.run { launches.record() }
                        return 504
                    }
                )

                let outcome = try await restarted.recoverPendingTransaction()
                let registry = try store.loadRegistry()
                let status = try await restarted.recoveryStatus()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let sourceAfter = try store.loadCredential(for: fixture.source.id)
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                let journal = try store.loadJournalIfPresent()
                let evidence = try store.loadJournalFinalizationEvidenceIfPresent()
                let launchCount = await MainActor.run { launches.count }

                try expect(
                    outcome == .completed(.commitVerifiedTarget),
                    "restart did not finish an already committed B"
                )
                try expect(registry.activeProfileID == fixture.target.id, "restart moved active B")
                try expect(status == .none, "restart left committed B recovery pending")
                try expect(active == crash.activeTarget, "restart changed active B auth")
                try expect(sourceAfter == sourceBefore, "restart changed configured A")
                try expect(targetAfter == targetBefore, "restart changed configured B")
                try expect(journal == nil && evidence == nil, "restart left finalization evidence")
                try expect(launchCount == 0, "restart launched the app")
            }
        },
        TestCase("Local provider restores A when targetVerified auth changes") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                _ = try prepareReloginCrash(fixture, phase: .targetVerified)
                let changedTarget = Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"changed-b-id","access_token":"changed-b-access","refresh_token":"changed-b-refresh"}}"#.utf8
                )
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: MutatingProcessSnapshotProvider(
                        mutationCall: 2,
                        url: fixture.authURL,
                        contents: changedTarget
                    ),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                let outcome = try await provider.recoverPendingTransaction()
                let registry = try store.loadRegistry()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let journal = try store.loadJournalIfPresent()

                try expect(outcome == .completed(.restorePrevious), "changed B did not roll back")
                try expect(registry.activeProfileID == fixture.source.id, "changed B activated target")
                try expect(active == storedSource, "changed B did not restore exact A")
                try expect(journal == nil, "changed B left recovery pending")
            }
        },
        TestCase("Local provider does not overwrite a concurrent active profile change") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(fixture, phase: .targetVerified)
                let preparedRegistry = try store.loadRegistry()
                let profileC = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "C",
                    email: "c@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_002),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_002)
                )
                let registryA = try ProfileRegistry(
                    activeProfileID: fixture.source.id,
                    profiles: preparedRegistry.profiles + [profileC]
                )
                let registryC = try ProfileRegistry(
                    activeProfileID: profileC.id,
                    profiles: registryA.profiles
                )
                _ = try store.saveRegistry(registryA)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: MutatingProcessSnapshotProvider(
                        mutationCall: 3,
                        url: fixture.storeURL.appendingPathComponent("profiles.json"),
                        contents: try RegistryCodec.encode(registryC)
                    ),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                do {
                    _ = try await provider.recoverPendingTransaction()
                    throw TestFailure(description: "concurrent active profile change was overwritten")
                } catch let failure as RecoveryCoordinatorFailure {
                    try expect(failure == .executionFailed, "registry race returned the wrong STOP")
                }

                let registryAfter = try store.loadRegistry()
                let activeAfter = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let journalAfter = try store.loadJournalIfPresent()
                try expect(registryAfter == registryC, "recovery overwrote concurrent active C")
                try expect(activeAfter == crash.activeTarget, "registry race changed active auth")
                try expect(journalAfter == crash.journal, "registry race changed journal")
            }
        },
        TestCase("Local provider stops targetVerified with a relogin marker") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(
                    fixture,
                    phase: .targetVerified,
                    targetPrepared: false
                )
                let registryBefore = try store.loadRegistry()
                let targetBefore = try store.loadCredential(for: fixture.target.id)

                do {
                    _ = try await LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [] }
                    ).recoverPendingTransaction()
                    throw TestFailure(description: "marked target was committed")
                } catch let failure as RecoveryCoordinatorFailure {
                    try expect(failure == .snapshotInvalid, "marked target returned the wrong STOP")
                }

                let registryAfter = try store.loadRegistry()
                let activeAfter = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                let journalAfter = try store.loadJournalIfPresent()
                try expect(registryAfter == registryBefore, "marked target changed registry")
                try expect(activeAfter == crash.activeTarget, "marked target changed active auth")
                try expect(targetAfter == targetBefore, "marked target changed configured B")
                try expect(journalAfter == crash.journal, "marked target changed journal")
            }
        },
        TestCase("Local provider stops an early phase with target registry active") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(fixture, phase: .preparing)
                let preparedRegistry = try store.loadRegistry()
                let contradictoryRegistry = try ProfileRegistry(
                    activeProfileID: fixture.target.id,
                    profiles: preparedRegistry.profiles
                )
                _ = try store.saveRegistry(contradictoryRegistry)
                let sourceData = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                )
                try sourceData.write(to: fixture.authURL)
                let sourceBefore = try CredentialBlob(validating: sourceData)

                do {
                    _ = try await LocalCLIDataProvider(
                        storeURL: fixture.storeURL,
                        activeAuthURL: fixture.authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { fixture.descriptor },
                        runningApplicationPIDs: { _ in [] }
                    ).recoverPendingTransaction()
                    throw TestFailure(description: "contradictory registry was repaired")
                } catch let failure as RecoveryCoordinatorFailure {
                    try expect(failure == .snapshotInvalid, "registry contradiction returned the wrong STOP")
                }

                let registryAfter = try store.loadRegistry()
                let activeAfter = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let journalAfter = try store.loadJournalIfPresent()
                try expect(registryAfter == contradictoryRegistry, "registry contradiction was mutated")
                try expect(activeAfter == sourceBefore, "registry contradiction changed active auth")
                try expect(journalAfter == crash.journal, "registry contradiction changed journal")
            }
        },
        TestCase("Local provider leaves rollbackFailed recovery untouched") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeManualRecoveryFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let activeBefore = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let journalBefore = try store.loadJournalIfPresent()
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { throw CodexAppLocatorFailure.notFound },
                    runningApplicationPIDs: { _ in [] }
                )

                let outcome = try await provider.recoverPendingTransaction()
                let registryAfter = try store.loadRegistry()
                let activeAfter = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let journalAfter = try store.loadJournalIfPresent()

                try expect(
                    outcome == .stopped(.rollbackPreviouslyFailed),
                    "rollbackFailed did not remain terminal"
                )
                try expect(registryAfter == registryBefore, "rollbackFailed changed registry")
                try expect(activeAfter == activeBefore, "rollbackFailed changed active auth")
                try expect(journalAfter == journalBefore, "rollbackFailed changed journal")
            }
        },
        TestCase("Local provider explicitly quiesces the app before retrying recovery") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(fixture, phase: .quiescent)
                try fixture.sourceAuthData.write(to: fixture.authURL)

                let processes = TerminableProcessSnapshotProvider()
                let root = ProcessRecord(
                    identity: ProcessIdentity(pid: 601, startSeconds: 701, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: fixture.descriptor.mainExecutableURL.path,
                    nameHint: "ChatGPT"
                )
                let child = ProcessRecord(
                    identity: ProcessIdentity(pid: 602, startSeconds: 702, startMicroseconds: 1),
                    parentPID: root.identity.pid,
                    executablePath: "/bin/zsh",
                    nameHint: "zsh"
                )
                let orphanedChild = ProcessRecord(
                    identity: child.identity,
                    parentPID: 1,
                    executablePath: child.executablePath,
                    nameHint: child.nameHint
                )
                processes.install([root, child])
                let confirmations = TerminationConfirmationRecorder()
                let launches = await MainActor.run { AppLaunchRecorder() }
                let lockStoreURL = fixture.storeURL
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: processes,
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in
                        processes.contains(pid: root.identity.pid) ? [root.identity.pid] : []
                    },
                    requestApplicationTermination: { _ in
                        let lockStore = try SpikeStore.openExisting(at: lockStoreURL)
                        if let unexpectedLock = try lockStore.tryAcquireTransactionLock() {
                            unexpectedLock.release()
                            throw TestFailure(description: "explicit recovery quit without the transaction lock")
                        }
                        processes.install(orphanedChild)
                        return [root.identity.pid]
                    },
                    confirmAppOwnedTermination: confirmations.confirm,
                    requestProcessTermination: { processes.terminate($0) },
                    normalTerminationGracePolls: 0,
                    quiescenceSleep: { _ in },
                    launchApplication: { _ in
                        launches.record()
                        return 603
                    }
                )

                let automatic = try await provider.recoverPendingTransaction()
                let journalAfterAutomatic = try store.loadJournalIfPresent()
                let explicit = try await provider.retryPendingRecovery(
                    expectedTransactionID: crash.journal.transactionID.uuidString
                )
                let registry = try store.loadRegistry()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let journal = try store.loadJournalIfPresent()
                let launchCount = await MainActor.run { launches.count }

                try expect(
                    automatic == .stopped(.processBlockerPresent),
                    "automatic recovery terminated a running app"
                )
                try expect(journalAfterAutomatic == crash.journal, "automatic recovery changed the journal")
                try expect(explicit == .completed(.cancelBeforeMutation), "explicit retry did not recover A")
                try expect(confirmations.counts == [1], "explicit retry did not confirm the exact survivor")
                try expect(processes.terminatedPIDs == [child.identity.pid], "explicit retry terminated another process")
                try expect(registry.activeProfileID == fixture.source.id, "explicit retry changed active profile")
                try expect(active == fixture.sourceCredential, "explicit retry changed active auth")
                try expect(journal == nil, "explicit retry left recovery pending")
                try expect(launchCount == 0, "explicit retry relaunched the app")
            }
        },
        TestCase("Local provider finalizes quiescent recovery after same-account credential rotation") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(fixture, phase: .quiescent)
                let rotatedSourceData = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"rotated-a-id","access_token":"rotated-a-access","refresh_token":"rotated-a-refresh"}}"#.utf8
                )
                let rotatedSource = try CredentialBlob(validating: rotatedSourceData)
                let refreshedSource = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"fixture-id-rotated","access_token":"fixture-access-rotated","refresh_token":"fixture-refresh-rotated"}}"#.utf8
                ))
                try rotatedSourceData.write(to: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    requestApplicationTermination: { _ in [] }
                )

                let outcome = try await provider.retryPendingRecovery(
                    expectedTransactionID: crash.journal.transactionID.uuidString
                )
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let journal = try store.loadJournalIfPresent()

                try expect(outcome == .completed(.repairCurrentThenCancel), "rotated A was not repaired")
                try expect(active == refreshedSource, "recovery did not refresh the rotated active A")
                try expect(
                    storedSource == refreshedSource,
                    "recovery did not retain the refreshed A"
                )
                try expect(storedSource != rotatedSource, "recovery stored identity-only A evidence")
                try expect(journal == nil, "rotated A left recovery pending")
            }
        },
        TestCase("Local provider restores configured source when active credential refresh fails") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory, failActiveRefresh: true)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(fixture, phase: .quiescent)
                let rotatedSourceData = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"untrusted-a-id","access_token":"untrusted-a-access","refresh_token":"untrusted-a-refresh"}}"#.utf8
                )
                let rotatedSource = try CredentialBlob(validating: rotatedSourceData)
                try rotatedSourceData.write(to: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    requestApplicationTermination: { _ in [] }
                )

                let outcome = try await provider.retryPendingRecovery(
                    expectedTransactionID: crash.journal.transactionID.uuidString
                )
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let journal = try store.loadJournalIfPresent()

                try expect(outcome == .completed(.repairCurrentThenCancel), "failed refresh was not repaired")
                try expect(active == storedSource, "failed refresh did not restore configured A")
                try expect(storedSource != rotatedSource, "failed refresh stored identity-only A evidence")
                try expect(journal == nil, "restored A left recovery pending")
            }
        },
        TestCase("Local provider resumes an interrupted changed source repair") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory, failConfiguredRefresh: true)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(fixture, phase: .rollbackStarted)
                let rotatedSourceData = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"resumable-a-id","access_token":"resumable-a-access","refresh_token":"resumable-a-refresh"}}"#.utf8
                )
                let rotatedSource = try CredentialBlob(validating: rotatedSourceData)
                let refreshedSource = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"fixture-id-rotated","access_token":"fixture-access-rotated","refresh_token":"fixture-refresh-rotated"}}"#.utf8
                ))
                try rotatedSourceData.write(to: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    requestApplicationTermination: { _ in [] }
                )

                let outcome = try await provider.retryPendingRecovery(
                    expectedTransactionID: crash.journal.transactionID.uuidString
                )
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let journal = try store.loadJournalIfPresent()

                try expect(outcome == .completed(.repairCurrentThenCancel), "interrupted repair was not resumed")
                try expect(active == refreshedSource, "interrupted repair did not refresh active A")
                try expect(storedSource == refreshedSource, "interrupted repair did not save refreshed A")
                try expect(storedSource != rotatedSource, "interrupted repair stored identity-only A evidence")
                try expect(journal == nil, "interrupted repair left recovery pending")
            }
        },
        TestCase("Local provider rejects a stale explicit recovery transaction") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(fixture, phase: .quiescent)
                try fixture.sourceAuthData.write(to: fixture.authURL)
                let registryBefore = try store.loadRegistry()
                let authBefore = try Data(contentsOf: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                do {
                    _ = try await provider.retryPendingRecovery(expectedTransactionID: UUID().uuidString)
                    throw TestFailure(description: "stale explicit recovery was accepted")
                } catch let failure as RecoveryCoordinatorFailure {
                    try expect(failure == .snapshotInvalid, "stale retry returned the wrong failure")
                }

                let registryAfter = try store.loadRegistry()
                let authAfter = try Data(contentsOf: fixture.authURL)
                let journalAfter = try store.loadJournalIfPresent()
                try expect(registryAfter == registryBefore, "stale retry changed registry")
                try expect(authAfter == authBefore, "stale retry changed auth")
                try expect(journalAfter == crash.journal, "stale retry changed journal")
            }
        },
        TestCase("Local provider makes a failed refreshingCurrent recovery terminal") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                _ = try prepareReloginCrash(
                    fixture,
                    phase: .refreshingCurrent,
                    targetPrepared: false
                )
                _ = try store.saveCredential(fixture.staleTargetCredential, for: fixture.source.id)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                do {
                    _ = try await provider.recoverPendingTransaction()
                    throw TestFailure(description: "invalid source repair completed")
                } catch let failure as RecoveryCoordinatorFailure {
                    try expect(failure == .rollbackFailed, "source repair returned the wrong failure")
                }
                let journalAfterFailure = try store.loadJournalIfPresent()
                let retry = try await provider.recoverPendingTransaction()
                let journalAfterRetry = try store.loadJournalIfPresent()

                try expect(journalAfterFailure?.phase == .rollbackFailed, "source repair was not terminal")
                try expect(
                    retry == .stopped(.rollbackPreviouslyFailed),
                    "terminal source repair was retried"
                )
                try expect(journalAfterRetry == journalAfterFailure, "terminal retry changed journal")
            }
        },
        TestCase("Local provider rolls validatingTarget relogin back after restart") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let crash = try prepareReloginCrash(
                    fixture,
                    phase: .validatingTarget
                )
                let launches = await MainActor.run { AppLaunchRecorder() }
                let restarted = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    launchApplication: { _ in
                        await MainActor.run { launches.record() }
                        return 502
                    }
                )

                let outcome = try await restarted.recoverPendingTransaction()
                let status = try await restarted.recoveryStatus()
                let registry = try store.loadRegistry()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let storedTarget = try store.loadCredential(for: fixture.target.id)
                let journal = try store.loadJournalIfPresent()
                let evidence = try store.loadJournalFinalizationEvidenceIfPresent()
                let launchCount = await MainActor.run { launches.count }

                try expect(
                    outcome == .completed(.cleanupTargetThenRestorePrevious),
                    "restart chose the wrong validatingTarget recovery"
                )
                try expect(status == .none, "restart left validatingTarget recovery pending")
                try expect(registry.activeProfileID == fixture.source.id, "restart did not restore A")
                try expect(
                    registry.profiles.first(where: { $0.id == fixture.target.id })?.needsRelogin == false,
                    "restart lost the verified B marker"
                )
                try expect(active == storedSource, "restart did not restore exact A auth")
                try expect(storedTarget == crash.activeTarget, "restart discarded verified B")
                try expect(journal == nil && evidence == nil, "restart left validatingTarget evidence")
                try expect(launchCount == 0, "restart launched the app")
            }
        },
        TestCase("Local provider identifies unstored relogin auth before restart rollback") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                _ = try prepareReloginCrash(
                    fixture,
                    phase: .validatingTarget,
                    targetPrepared: false
                )
                let launches = await MainActor.run { AppLaunchRecorder() }
                let restarted = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    launchApplication: { _ in
                        await MainActor.run { launches.record() }
                        return 503
                    }
                )

                let outcome = try await restarted.recoverPendingTransaction()
                let registry = try store.loadRegistry()
                let active = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let storedTarget = try store.loadCredential(for: fixture.target.id)
                let journal = try store.loadJournalIfPresent()
                let launchCount = await MainActor.run { launches.count }

                try expect(
                    outcome == .completed(.cleanupTargetThenRestorePrevious),
                    "restart did not identify unstored B auth"
                )
                try expect(registry.activeProfileID == fixture.source.id, "restart did not restore A")
                try expect(
                    registry.profiles.first(where: { $0.id == fixture.target.id })?.needsRelogin == true,
                    "restart cleared an unverified B marker"
                )
                try expect(active == storedSource, "restart did not restore exact A auth")
                try expect(storedTarget == fixture.staleTargetCredential, "restart overwrote stale B")
                try expect(journal == nil, "restart left unstored relogin recovery pending")
                try expect(launchCount == 0, "restart launched the app")
            }
        },
        TestCase("Local provider rejects a wrong isolated relogin identity without mutation") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true,
                    isolatedLoginAccount: "c"
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let sourceBefore = try store.loadCredential(for: fixture.source.id)
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let authBefore = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                do {
                    _ = try await provider.reloginProfile(target: fixture.target.id.description)
                    throw TestFailure(description: "wrong relogin identity was accepted")
                } catch is ProfileCaptureFailure {
                }

                let registryAfter = try store.loadRegistry()
                let sourceAfter = try store.loadCredential(for: fixture.source.id)
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                let authAfter = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let journalAfter = try store.loadJournalIfPresent()
                try expect(registryAfter == registryBefore, "identity mismatch changed registry")
                try expect(sourceAfter == sourceBefore, "identity mismatch changed A")
                try expect(targetAfter == targetBefore, "identity mismatch changed B")
                try expect(authAfter == authBefore, "identity mismatch changed public auth")
                try expect(journalAfter == nil, "identity mismatch created a journal")
                try expect(
                    !FileManager.default.fileExists(
                        atPath: fixture.storeURL.appendingPathComponent("isolated-login-workspace").path
                    ),
                    "identity mismatch left an isolated login workspace"
                )
            }
        },
        TestCase("Local provider blocks isolated relogin on pending recovery") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory, activeAuthIsSource: true)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let now = Date(timeIntervalSince1970: 1_700_000_010)
                let pending = SwitchJournalRecord(
                    transactionID: UUID(),
                    phase: .preparing,
                    previousProfileID: fixture.source.id,
                    targetProfileID: fixture.target.id,
                    startedAt: now,
                    updatedAt: now
                )
                _ = try store.createJournalIfAbsent(pending)
                let recoveryBlockedProvider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                do {
                    _ = try await recoveryBlockedProvider.reloginProfile(target: fixture.target.id.description)
                    throw TestFailure(description: "pending recovery did not block relogin")
                } catch let failure as LocalCLIDataProviderFailure {
                    try expect(failure == .pendingRecovery, "recovery gate returned the wrong failure")
                }

                let registryAfter = try store.loadRegistry()
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                let journalAfter = try store.loadJournalIfPresent()
                try expect(registryAfter == registryBefore, "relogin gate changed registry")
                try expect(targetAfter == targetBefore, "relogin gate changed B credential")
                try expect(journalAfter == pending, "relogin gate changed pending recovery")
            }
        },
        TestCase("Local provider preserves isolated relogin workspace after an unconfirmed verifier") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true,
                    holdVerifierPipesOpen: true
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let sourceBefore = try store.loadCredential(for: fixture.source.id)
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let authBefore = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                do {
                    _ = try await provider.reloginProfile(target: fixture.target.id.description)
                    throw TestFailure(description: "unconfirmed verifier completed relogin")
                } catch let failure as AppServerProbeFailure {
                    try expect(
                        failure.childDisposition == .unconfirmed,
                        "unconfirmed verifier returned the wrong failure"
                    )
                }
                let journal = try store.loadJournalIfPresent()
                let recovery = try await provider.recoveryStatus()
                let registryAfter = try store.loadRegistry()
                let sourceAfter = try store.loadCredential(for: fixture.source.id)
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                let authAfter = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)

                try expect(journal == nil, "isolated relogin created a switch journal")
                try expect(registryAfter == registryBefore, "unconfirmed verifier changed registry")
                try expect(sourceAfter == sourceBefore, "unconfirmed verifier changed A")
                try expect(targetAfter == targetBefore, "unconfirmed verifier changed B")
                try expect(authAfter == authBefore, "unconfirmed verifier changed public auth")
                try expect(
                    FileManager.default.fileExists(
                        atPath: fixture.storeURL.appendingPathComponent("isolated-login-workspace").path
                    ),
                    "unconfirmed verifier removed live login evidence"
                )
                try expect(recovery == .blocked, "unconfirmed verifier did not block account mutations")
            }
        },
        TestCase("Local provider removes an abandoned login workspace only after its child exits") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory, activeAuthIsSource: true)
                let loginHome = fixture.storeURL.appendingPathComponent(
                    "isolated-login-workspace",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: loginHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: loginHome.path)
                let loginAuth = loginHome.appendingPathComponent("auth.json", isDirectory: false)
                try fixture.sourceAuthData.write(to: loginAuth, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: loginAuth.path)
                _ = try DarwinDurableFileOperations().replace(
                    contents: SensitiveBytes(Data("pid=801\n".utf8)),
                    at: loginHome.appendingPathComponent("helper-child", isDirectory: false),
                    expecting: .absent
                )
                let child = ProcessRecord(
                    identity: ProcessIdentity(pid: 801, startSeconds: 901, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: fixture.descriptor.bundledCodexURL.path,
                    nameHint: "codex"
                )
                let processes = TerminableProcessSnapshotProvider()
                processes.install(child)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: processes,
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    verificationChildIsAlive: { processes.contains(pid: $0) }
                )

                do {
                    _ = try await provider.recoverPendingTransaction()
                    throw TestFailure(description: "live login child workspace was removed")
                } catch let failure as LocalCLIDataProviderFailure {
                    try expect(failure == .pendingRecovery, "live login child returned the wrong failure")
                }
                try expect(FileManager.default.fileExists(atPath: loginHome.path), "live workspace disappeared")

                processes.terminate(child)
                let outcome = try await provider.recoverPendingTransaction()
                let recovery = try await provider.recoveryStatus()
                try expect(outcome == .none, "abandoned workspace cleanup reported recovery work")
                try expect(!FileManager.default.fileExists(atPath: loginHome.path), "abandoned workspace remained")
                try expect(recovery == .none, "cleanup left recovery blocked")
            }
        },
        TestCase("Local provider removes a login workspace abandoned before child launch") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory, activeAuthIsSource: true)
                let loginHome = fixture.storeURL.appendingPathComponent(
                    "isolated-login-workspace",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: loginHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: loginHome.path)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    verificationChildIsAlive: { _ in
                        throw TestFailure(description: "markerless workspace queried child liveness")
                    }
                )

                let outcome = try await provider.recoverPendingTransaction()
                let recovery = try await provider.recoveryStatus()
                try expect(outcome == .none, "pre-launch workspace cleanup reported recovery work")
                try expect(!FileManager.default.fileExists(atPath: loginHome.path), "pre-launch workspace remained")
                try expect(recovery == .none, "pre-launch cleanup left recovery blocked")
            }
        },
        TestCase("Local provider preserves a login workspace without a durable child PID") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(in: directory, activeAuthIsSource: true)
                let loginHome = fixture.storeURL.appendingPathComponent(
                    "isolated-login-workspace",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: loginHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: loginHome.path)
                _ = try DarwinDurableFileOperations().replace(
                    contents: SensitiveBytes(Data("launching\n".utf8)),
                    at: loginHome.appendingPathComponent("helper-child", isDirectory: false),
                    expecting: .absent
                )
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    verificationChildIsAlive: { _ in false }
                )

                do {
                    _ = try await provider.recoverPendingTransaction()
                    throw TestFailure(description: "workspace without a child PID was removed")
                } catch let failure as LocalCLIDataProviderFailure {
                    try expect(failure == .pendingRecovery, "missing child PID returned the wrong failure")
                }
                let recovery = try await provider.recoveryStatus()
                try expect(FileManager.default.fileExists(atPath: loginHome.path), "unsafe workspace disappeared")
                try expect(recovery == .blocked, "unsafe workspace did not STOP")
            }
        },
        TestCase("Local provider rejects an isolated refresh identity change without public rollback") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true,
                    rotateActiveToOtherAccount: true
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let sourceBefore = try store.loadCredential(for: fixture.source.id)
                let targetBefore = try store.loadCredential(for: fixture.target.id)
                let authBefore = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                do {
                    _ = try await provider.reloginProfile(target: fixture.target.id.description)
                    throw TestFailure(description: "changed refreshed identity was accepted")
                } catch is ProfileCaptureFailure {
                }
                let registry = try store.loadRegistry()
                let authAfter = try DarwinDurableFileOperations().snapshot(at: fixture.authURL)
                let storedSource = try store.loadCredential(for: fixture.source.id)
                let storedTarget = try store.loadCredential(for: fixture.target.id)
                let journal = try store.loadJournalIfPresent()

                try expect(registry == registryBefore, "failed refresh changed registry")
                try expect(storedSource == sourceBefore, "failed refresh changed A")
                try expect(storedTarget == targetBefore, "failed refresh changed B")
                try expect(authAfter == authBefore, "failed refresh changed public auth")
                try expect(journal == nil, "failed isolated refresh created a journal")
            }
        },
        TestCase("CLI sync-active validates and stores only the registered active profile") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeA = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"current-id","access_token":"current-access","refresh_token":"current-refresh"}}"#.utf8
                )
                let wrongB = Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"wrong-id","access_token":"wrong-access","refresh_token":"wrong-refresh"}}"#.utf8
                )
                try wrongB.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let profileA = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "person@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
                let profileB = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "B",
                    email: "b@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
                let storedA = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"old-id","access_token":"old-access","refresh_token":"old-refresh"}}"#.utf8
                ))
                let storedB = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(storedA, for: profileA.id)
                _ = try store.saveCredential(storedB, for: profileB.id)
                let originalRegistry = try ProfileRegistry(
                    activeProfileID: profileA.id,
                    profiles: [profileA, profileB]
                )
                _ = try store.saveRegistry(originalRegistry)

                let executable = try makeCaptureAppServer(in: directory, rotateToOtherAccount: false)
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.81911",
                    build: "5973",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let provider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let application = CLIApplication(provider: provider)

                let mismatched = await application.run(
                    arguments: ["profile", "sync-active"],
                    mutationConfirmed: true
                )
                let storedAAfterMismatch = try store.loadCredential(for: profileA.id)
                let storedBAfterMismatch = try store.loadCredential(for: profileB.id)
                let registryAfterMismatch = try store.loadRegistry()
                let authAfterMismatch = try Data(contentsOf: authURL)
                try activeA.write(to: authURL)
                let denied = await application.run(arguments: ["profile", "sync-active"])
                let runningPIDs = await MainActor.run { RunningPIDSequence([[], [42]]) }
                let blockedProvider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in runningPIDs.next() }
                )
                let processBlocked = await CLIApplication(provider: blockedProvider).run(
                    arguments: ["profile", "sync-active"],
                    mutationConfirmed: true
                )
                let now = Date(timeIntervalSince1970: 1_700_000_002)
                _ = try store.createJournalIfAbsent(
                    SwitchJournalRecord(
                        transactionID: UUID(),
                        phase: .preparing,
                        previousProfileID: profileA.id,
                        targetProfileID: profileB.id,
                        startedAt: now,
                        updatedAt: now
                    )
                )
                let recoveryBlocked = await application.run(
                    arguments: ["profile", "sync-active"],
                    mutationConfirmed: true
                )
                _ = try store.removeJournal()
                let storedAAfterGuards = try store.loadCredential(for: profileA.id)
                let storedBAfterGuards = try store.loadCredential(for: profileB.id)
                let authAfterGuards = try Data(contentsOf: authURL)
                let synced = await application.run(
                    arguments: ["profile", "sync-active"],
                    mutationConfirmed: true
                )
                let refreshedActive = try CredentialBlob(validating: Data(contentsOf: authURL))
                let refreshedStoredA = try store.loadCredential(for: profileA.id)
                let preservedStoredB = try store.loadCredential(for: profileB.id)
                let registryAfter = try store.loadRegistry()
                let journalAfter = try store.loadJournalIfPresent()
                let authAfterSuccess = try Data(contentsOf: authURL)
                let captureMarkerAfterSuccess = try store.loadCaptureProfileIDIfPresent()

                _ = try store.saveCredential(storedA, for: profileA.id)
                let racedProvider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: MutatingProcessSnapshotProvider(
                        mutationCall: 3,
                        url: authURL,
                        contents: wrongB
                    ),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let raced = await CLIApplication(provider: racedProvider).run(
                    arguments: ["profile", "sync-active"],
                    mutationConfirmed: true
                )
                let storedAAfterRace = try store.loadCredential(for: profileA.id)
                let storedBAfterRace = try store.loadCredential(for: profileB.id)
                let registryAfterRace = try store.loadRegistry()
                let authAfterRace = try Data(contentsOf: authURL)
                let captureMarkerAfterRace = try store.loadCaptureProfileIDIfPresent()

                try activeA.write(to: authURL)
                let pipeDirectory = directory.appendingPathComponent("pipe", isDirectory: true)
                try FileManager.default.createDirectory(at: pipeDirectory, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pipeDirectory.path)
                let pipeExecutable = try makeCaptureAppServer(
                    in: pipeDirectory,
                    rotateToOtherAccount: false,
                    holdPipesOpen: true
                )
                let pipeDescriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: descriptor.mainExecutableURL,
                    bundledCodexURL: pipeExecutable,
                    bundleIdentifier: descriptor.bundleIdentifier,
                    version: descriptor.version,
                    build: descriptor.build,
                    appSigningIdentifier: descriptor.appSigningIdentifier,
                    bundledCodexSigningIdentifier: descriptor.bundledCodexSigningIdentifier,
                    teamIdentifier: descriptor.teamIdentifier
                )
                let pipeProvider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { pipeDescriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let unconfirmed = await CLIApplication(provider: pipeProvider).run(
                    arguments: ["profile", "sync-active"],
                    mutationConfirmed: true
                )
                let recoveryProvider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { pipeDescriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let unconfirmedRecovery = await CLIApplication(provider: recoveryProvider).run(
                    arguments: ["recovery", "status"]
                )
                let verificationWorkspace = storeURL.appendingPathComponent(
                    "credential-verification-workspace",
                    isDirectory: true
                )
                let storedAAfterUnconfirmed = try store.loadCredential(for: profileA.id)
                let storedBAfterUnconfirmed = try store.loadCredential(for: profileB.id)
                let registryAfterUnconfirmed = try store.loadRegistry()
                let authAfterUnconfirmed = try Data(contentsOf: authURL)

                try expect(mismatched.standardError == "error=identity_mismatch\n", "wrong account was synced")
                try expect(storedAAfterMismatch == storedA, "mismatch changed the active profile")
                try expect(storedBAfterMismatch == storedB, "mismatch changed the inactive profile")
                try expect(registryAfterMismatch == originalRegistry, "mismatch changed the registry")
                try expect(authAfterMismatch == wrongB, "mismatch changed active auth")
                try expect(denied.standardError == "error=confirmation_required\n", "sync ran without confirmation")
                try expect(processBlocked.standardError == "error=process_blocked\n", "process gate allowed sync")
                try expect(recoveryBlocked.standardError == "error=recovery_required\n", "recovery gate allowed sync")
                try expect(storedAAfterGuards == storedA, "a guard changed the active profile")
                try expect(storedBAfterGuards == storedB, "a guard changed the inactive profile")
                try expect(authAfterGuards == activeA, "a guard changed active auth")
                try expect(synced.exitCode == 0, "active profile sync failed: \(synced.standardError)")
                try expect(synced.standardOutput.contains("active=true label=A"), "synced profile output changed")
                try expect(refreshedStoredA == refreshedActive, "active profile did not store refreshed auth")
                try expect(authAfterSuccess == activeA, "sync changed active auth bytes")
                try expect(refreshedStoredA != storedA, "active profile kept stale auth")
                try expect(preservedStoredB == storedB, "inactive profile changed")
                try expect(registryAfter == originalRegistry, "sync changed the registry")
                try expect(journalAfter == nil, "sync left a recovery journal")
                try expect(captureMarkerAfterSuccess == nil, "sync left a backup marker")
                try expect(raced.standardError == "error=active_auth_changed\n", "post-save auth race was not detected")
                try expect(storedAAfterRace == storedA, "post-save failure did not restore stored A")
                try expect(storedBAfterRace == storedB, "post-save failure changed stored B")
                try expect(registryAfterRace == originalRegistry, "post-save failure changed the registry")
                try expect(authAfterRace == wrongB, "sync overwrote externally changed active auth")
                try expect(captureMarkerAfterRace == nil, "successful rollback left a backup marker")
                try expect(unconfirmed.standardError == "error=account_probe_failed\n", "unconfirmed verifier child was accepted")
                try expect(
                    FileManager.default.fileExists(atPath: verificationWorkspace.path),
                    "unconfirmed verifier workspace was not retained in the private store"
                )
                try expect(unconfirmedRecovery.standardOutput == "recovery=blocked\n", "new provider lost verifier recovery state")
                try expect(storedAAfterUnconfirmed == storedA, "unconfirmed verifier changed stored A")
                try expect(storedBAfterUnconfirmed == storedB, "unconfirmed verifier changed stored B")
                try expect(registryAfterUnconfirmed == originalRegistry, "unconfirmed verifier changed the registry")
                try expect(authAfterUnconfirmed == activeA, "unconfirmed verifier changed active auth")
            }
        },
        TestCase("CLI second capture rejects the registered account before isolated refresh") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeA = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                )
                try activeA.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let profileA = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "person@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
                _ = try store.saveCredential(
                    CredentialBlob(validating: activeA),
                    for: profileA.id
                )
                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileA.id, profiles: [profileA])
                )

                let executable = try makeCaptureAppServer(
                    in: directory,
                    rotateToOtherAccount: false,
                    failRefreshHomeURL: storeURL.appendingPathComponent(
                        "isolated-login-workspace",
                        isDirectory: true
                    ),
                    loginAccount: "a"
                )
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let provider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let application = CLIApplication(provider: provider)

                let captured = await application.run(
                    arguments: ["profile", "capture", "--label", "B"],
                    mutationConfirmed: true
                )
                let registry = try store.loadRegistry()
                let recovery = await application.run(arguments: ["recovery", "status"])
                let activeCredential = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedCredential = try store.loadCredential(for: profileA.id)

                try expect(
                    captured.standardError == "error=account_already_registered\n",
                    "registered account reached isolated refresh: \(captured.standardError)"
                )
                try expect(registry.profiles == [profileA], "duplicate profile was registered")
                try expect(registry.activeProfileID == profileA.id, "first profile stopped being active")
                try expect(activeCredential == storedCredential, "first credential was not restored")
                try expect(recovery.standardOutput == "recovery=none\n", "duplicate rejection left recovery")
            }
        },
        TestCase("CLI third capture preserves the active profile after isolated identity mismatch") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeB = Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
                )
                try activeB.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let profileA = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "person@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
                let profileB = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "B",
                    email: "b@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
                let credentialA = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                ))
                let credentialB = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(credentialA, for: profileA.id)
                _ = try store.saveCredential(credentialB, for: profileB.id)
                let originalRegistry = try ProfileRegistry(
                    activeProfileID: profileB.id,
                    profiles: [profileA, profileB]
                )
                _ = try store.saveRegistry(originalRegistry)

                let executable = try makeCaptureAppServer(
                    in: directory,
                    rotateToOtherAccount: true,
                    rotateToOtherAccountHomeURL: storeURL.appendingPathComponent(
                        "isolated-login-workspace",
                        isDirectory: true
                    ),
                    loginAccount: "c"
                )
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let provider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let application = CLIApplication(provider: provider)
                let credentialDirectory = storeURL.appendingPathComponent("credentials", isDirectory: true)
                let credentialFilesBeforeCapture = try FileManager.default
                    .contentsOfDirectory(atPath: credentialDirectory.path)
                    .sorted()

                let captured = await application.run(
                    arguments: ["profile", "capture", "--label", "C"],
                    mutationConfirmed: true
                )
                let registry = try store.loadRegistry()
                let recovery = await application.run(arguments: ["recovery", "status"])
                let activeCredential = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedA = try store.loadCredential(for: profileA.id)
                let storedB = try store.loadCredential(for: profileB.id)
                let credentialFilesAfterCapture = try FileManager.default
                    .contentsOfDirectory(atPath: credentialDirectory.path)
                    .sorted()

                try expect(captured.standardError == "error=identity_mismatch\n", "mismatch error changed")
                try expect(registry == originalRegistry, "mismatched third profile changed the registry")
                try expect(activeCredential == storedB, "active profile B changed")
                try expect(storedA == credentialA, "third capture failure changed profile A")
                try expect(storedB == credentialB, "third capture failure changed profile B")
                try expect(
                    credentialFilesAfterCapture == credentialFilesBeforeCapture,
                    "third capture failure left a temporary credential"
                )
                try expect(recovery.standardOutput == "recovery=none\n", "identity rejection left recovery")
            }
        },
        TestCase("CLI manually restores a failed capture rollback") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeB = Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
                )
                try activeB.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let profileA = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "A",
                    email: "person@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
                let credentialA = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                ))
                let profileB = ProfileMetadata(
                    id: try store.createCaptureProfileID(),
                    label: "B",
                    email: "b@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
                let storedB = try CredentialBlob(validating: activeB)
                _ = try store.saveCredential(credentialA, for: profileA.id)
                _ = try store.saveCredential(storedB, for: profileB.id)
                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileB.id, profiles: [profileA, profileB])
                )
                let rollbackStartedAt = Date(timeIntervalSince1970: 1_700_000_010)
                _ = try store.createJournalIfAbsent(
                    SwitchJournalRecord(
                        transactionID: UUID(),
                        phase: .rollbackFailed,
                        previousProfileID: profileA.id,
                        targetProfileID: profileB.id,
                        startedAt: rollbackStartedAt,
                        updatedAt: rollbackStartedAt
                    )
                )

                let executable = try makeCaptureAppServer(in: directory, rotateToOtherAccount: false)
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let recoveryLaunches = await MainActor.run { AppLaunchRecorder() }
                let recoveryApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in recoveryLaunches.count > 0 ? [202] : [] },
                        requestApplicationTermination: { _ in [] },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in },
                        launchApplication: { _ in
                            recoveryLaunches.record()
                            return 202
                        }
                    )
                )
                let restored = await recoveryApplication.run(
                    arguments: ["recovery", "restore", "--profile", "A"],
                    mutationConfirmed: true
                )
                let restoredRegistry = try store.loadRegistry()
                let restoredAuth = try CredentialBlob(validating: Data(contentsOf: authURL))
                let restoredStatus = await recoveryApplication.run(arguments: ["recovery", "status"])
                let restoredStoredA = try store.loadCredential(for: profileA.id)
                let restoredStoredB = try store.loadCredential(for: profileB.id)
                let restoredCaptureID = try store.loadCaptureProfileIDIfPresent()
                let recoveryLaunchCount = await MainActor.run { recoveryLaunches.count }

                try expect(restored.exitCode == 0, "capture manual recovery failed: \(restored.standardError)")
                try expect(restoredRegistry.activeProfileID == profileA.id, "capture recovery did not activate A")
                try expect(restoredRegistry.profiles.contains(profileB), "capture recovery removed B")
                try expect(restoredAuth == restoredStoredA, "capture recovery did not restore verified A auth")
                try expect(restoredStoredB == storedB, "capture recovery changed stored B")
                try expect(restoredCaptureID == nil, "capture recovery left marker")
                try expect(restoredStatus.standardOutput == "recovery=none\n", "capture recovery left journal")
                try expect(recoveryLaunchCount == 1, "capture recovery did not relaunch A")

                let profileC = ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "C",
                    email: "c@example.invalid",
                    planType: "plus",
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
                let storedC = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"c","tokens":{"id_token":"c-id","access_token":"c-access","refresh_token":"c-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(storedC, for: profileC.id)
                let impossibleRegistry = try ProfileRegistry(
                    activeProfileID: profileA.id,
                    profiles: [profileA, profileB, profileC]
                )
                _ = try store.saveRegistry(impossibleRegistry)
                let impossibleTargetID = try store.createCaptureProfileID()
                let impossibleTargetCredential = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","test_account":"d","tokens":{"id_token":"d-id","access_token":"d-access","refresh_token":"d-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(impossibleTargetCredential, for: impossibleTargetID)
                let impossibleJournal = SwitchJournalRecord(
                    transactionID: UUID(),
                    phase: .rollbackFailed,
                    previousProfileID: profileA.id,
                    targetProfileID: impossibleTargetID,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_150),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_150)
                )
                _ = try store.createJournalIfAbsent(impossibleJournal)
                let authBeforeImpossibleRecovery = try CredentialBlob(validating: Data(contentsOf: authURL))

                let impossibleRecovery = await recoveryApplication.run(
                    arguments: ["recovery", "restore", "--profile", "A"],
                    mutationConfirmed: true
                )
                let registryAfterImpossibleRecovery = try store.loadRegistry()
                let authAfterImpossibleRecovery = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedAAfterImpossibleRecovery = try store.loadCredential(for: profileA.id)
                let storedBAfterImpossibleRecovery = try store.loadCredential(for: profileB.id)
                let storedCAfterImpossibleRecovery = try store.loadCredential(for: profileC.id)
                let targetAfterImpossibleRecovery = try store.loadCredential(for: impossibleTargetID)
                let markerAfterImpossibleRecovery = try store.loadCaptureProfileIDIfPresent()
                let journalAfterImpossibleRecovery = try store.loadJournalIfPresent()

                try expect(
                    impossibleRecovery.standardError == "error=recovery_unavailable\n",
                    "full pre-commit registry was treated as recoverable"
                )
                try expect(registryAfterImpossibleRecovery == impossibleRegistry, "rejected recovery changed registry")
                try expect(authAfterImpossibleRecovery == authBeforeImpossibleRecovery, "rejected recovery changed active auth")
                try expect(storedAAfterImpossibleRecovery == restoredStoredA, "rejected recovery changed A")
                try expect(storedBAfterImpossibleRecovery == storedB, "rejected recovery changed B")
                try expect(storedCAfterImpossibleRecovery == storedC, "rejected recovery changed C")
                try expect(targetAfterImpossibleRecovery == impossibleTargetCredential, "rejected recovery changed pending target")
                try expect(markerAfterImpossibleRecovery == impossibleTargetID, "rejected recovery removed marker")
                try expect(journalAfterImpossibleRecovery == impossibleJournal, "rejected recovery removed journal")

                _ = try store.removeJournal()
                _ = try store.removeCaptureProfileID()
                _ = try store.removeCredential(for: impossibleTargetID)
                _ = try store.removeCredential(for: profileC.id)
                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileB.id, profiles: [profileA, profileB])
                )
                let precommitTargetID = try store.createCaptureProfileID()
                _ = try store.saveCredential(storedC, for: precommitTargetID)
                _ = try store.createJournalIfAbsent(
                    SwitchJournalRecord(
                        transactionID: UUID(),
                        phase: .rollbackFailed,
                        previousProfileID: profileB.id,
                        targetProfileID: precommitTargetID,
                        startedAt: Date(timeIntervalSince1970: 1_700_000_200),
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
                    )
                )
                let precommitLaunches = await MainActor.run { AppLaunchRecorder() }
                let precommitApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: EmptyProcessSnapshotProvider(),
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in precommitLaunches.count > 0 ? [204] : [] },
                        requestApplicationTermination: { _ in [] },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in },
                        launchApplication: { _ in
                            precommitLaunches.record()
                            return 204
                        }
                    )
                )
                let precommitRestored = await precommitApplication.run(
                    arguments: ["recovery", "restore", "--profile", "B"],
                    mutationConfirmed: true
                )
                let precommitRegistry = try store.loadRegistry()
                let precommitAuth = try CredentialBlob(validating: Data(contentsOf: authURL))
                let precommitStoredA = try store.loadCredential(for: profileA.id)
                let precommitStoredB = try store.loadCredential(for: profileB.id)
                let precommitCredentialURL = storeURL
                    .appendingPathComponent("credentials", isDirectory: true)
                    .appendingPathComponent("\(precommitTargetID).json", isDirectory: false)
                let precommitCaptureID = try store.loadCaptureProfileIDIfPresent()
                let precommitJournal = try store.loadJournalIfPresent()
                let precommitLaunchCount = await MainActor.run { precommitLaunches.count }

                try expect(precommitRestored.exitCode == 0, "pre-commit capture recovery failed")
                try expect(precommitRegistry.profiles == [profileA, profileB], "pre-commit recovery changed profiles")
                try expect(precommitRegistry.activeProfileID == profileB.id, "pre-commit recovery did not activate B")
                try expect(precommitAuth == precommitStoredB, "pre-commit recovery did not restore B auth")
                try expect(precommitStoredA == restoredStoredA, "pre-commit recovery changed A")
                try expect(precommitStoredB != storedB, "pre-commit recovery did not refresh B")
                try expect(
                    !FileManager.default.fileExists(atPath: precommitCredentialURL.path),
                    "pre-commit recovery left temporary target credential"
                )
                try expect(precommitCaptureID == nil, "pre-commit recovery left marker")
                try expect(precommitJournal == nil, "pre-commit recovery left journal")
                try expect(precommitLaunchCount == 1, "pre-commit recovery did not relaunch B")
            }
        },
        TestCase("CLI capture preserves an interrupted capture backup") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let activeAuth = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"active-id","access_token":"active-access","refresh_token":"active-refresh"}}"#.utf8
                )
                try activeAuth.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let storeURL = directory.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: storeURL)
                let pendingProfileID = try store.createCaptureProfileID()
                let backup = try CredentialBlob(validating: Data(
                    #"{"auth_mode":"chatgpt","tokens":{"id_token":"backup-id","access_token":"backup-access","refresh_token":"backup-refresh"}}"#.utf8
                ))
                _ = try store.saveCredential(backup, for: pendingProfileID)

                let executable = try makeCaptureAppServer(in: directory, rotateToOtherAccount: false)
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let provider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let application = CLIApplication(provider: provider)

                let recovery = await application.run(arguments: ["recovery", "status"])
                let capture = await application.run(
                    arguments: ["profile", "capture", "--label", "A"],
                    mutationConfirmed: true
                )
                let preservedBackup = try store.loadCredential(for: pendingProfileID)
                let registry = try store.loadRegistryIfPresent()

                try expect(recovery.standardOutput == "recovery=blocked\n", "interrupted capture was not reported")
                try expect(capture.standardError == "error=recovery_required\n", "interrupted capture was resumed")
                try expect(preservedBackup == backup, "capture backup was overwritten")
                try expect(registry == nil, "interrupted capture was committed")
            }
        },
        TestCase("CLI capture rolls back when refreshed bytes identify as another account") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let originalAuth = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"fixture-id","access_token":"fixture-access","refresh_token":"fixture-refresh"}}"#.utf8
                )
                try originalAuth.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let executable = try makeCaptureAppServer(in: directory, rotateToOtherAccount: true)
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let provider = LocalCLIDataProvider(
                    storeURL: directory.appendingPathComponent("store", isDirectory: true),
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let application = CLIApplication(provider: provider)

                let captured = await application.run(
                    arguments: ["profile", "capture", "--label", "A"],
                    mutationConfirmed: true
                )
                let listed = await application.run(arguments: ["profiles", "list"])
                let recovery = await application.run(arguments: ["recovery", "status"])
                let authAfter = try Data(contentsOf: authURL)

                try expect(captured.exitCode == 1, "mismatched refreshed bytes were captured")
                try expect(captured.standardError == "error=identity_mismatch\n", "mismatch error changed")
                try expect(listed.standardOutput == "profiles=none\n", "mismatched profile was registered")
                try expect(recovery.standardOutput == "recovery=none\n", "completed rollback left capture recovery")
                try expect(authAfter == originalAuth, "mismatched refresh did not restore original auth")
            }
        },
        TestCase("CLIApplication returns an allow-listed capture blocker") {
            let provider = StubCLIDataProvider(
                profiles: [],
                captureFailure: .processBlocked
            )
            let application = CLIApplication(provider: provider)

            let result = await application.run(
                arguments: ["profile", "capture", "--label", "A"],
                mutationConfirmed: true
            )

            try expect(result.exitCode == 1, "blocked capture returned success")
            try expect(result.standardError == "error=process_blocked\n", "capture blocker was not allow-listed")
        },
        TestCase("CLI isolated capture leaves unrelated processes alone") {
            try await withCaptureTemporaryDirectory { directory in
                let fixture = try makeReloginFixture(
                    in: directory,
                    activeAuthIsSource: true,
                    isolatedLoginAccount: "c"
                )
                let independentCodex = ProcessRecord(
                    identity: ProcessIdentity(pid: 301, startSeconds: 401, startMicroseconds: 1),
                    parentPID: 1,
                    executablePath: "/opt/homebrew/bin/codex",
                    nameHint: "codex"
                )
                let processes = CallTriggeredProcessSnapshotProvider(
                    triggerCall: 3,
                    record: independentCodex
                )
                let confirmations = TerminationConfirmationRecorder()
                let quitRequests = await MainActor.run { AppLaunchRecorder() }
                let launches = await MainActor.run { AppLaunchRecorder() }
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let authBefore = try Data(contentsOf: fixture.authURL)
                let sourceCredentialBefore = try store.loadCredential(for: fixture.source.id)
                let targetCredentialBefore = try store.loadCredential(for: fixture.target.id)
                let credentialsURL = fixture.storeURL.appendingPathComponent("credentials", isDirectory: true)
                let credentialFilesBefore = Set(
                    try FileManager.default.contentsOfDirectory(atPath: credentialsURL.path)
                )
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: processes,
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] },
                    requestApplicationTermination: { _ in
                        quitRequests.record()
                        return []
                    },
                    confirmAppOwnedTermination: confirmations.confirm,
                    requestProcessTermination: processes.terminate,
                    normalTerminationGracePolls: 0,
                    quiescenceSleep: { _ in },
                    launchApplication: { _ in
                        launches.record()
                        return 42
                    }
                )

                let result = await CLIApplication(provider: provider).run(
                    arguments: ["profile", "capture", "--label", "C"],
                    mutationConfirmed: true
                )
                let registryAfter = try store.loadRegistry()
                let authAfter = try Data(contentsOf: fixture.authURL)
                let sourceCredentialAfter = try store.loadCredential(for: fixture.source.id)
                let targetCredentialAfter = try store.loadCredential(for: fixture.target.id)
                let credentialFilesAfter = Set(
                    try FileManager.default.contentsOfDirectory(atPath: credentialsURL.path)
                )
                let marker = try store.loadCaptureProfileIDIfPresent()
                let journal = try store.loadJournalIfPresent()
                let quitRequestCount = await MainActor.run { quitRequests.count }
                let launchCount = await MainActor.run { launches.count }

                try expect(result.exitCode == 0, "isolated capture was blocked: \(result.standardError)")
                try expect(registryAfter.profiles.map(\.label) == ["A", "B", "C"], "isolated capture missed C")
                try expect(registryAfter.activeProfileID == registryBefore.activeProfileID, "isolated capture changed active profile")
                try expect(authAfter == authBefore, "isolated capture changed active auth")
                try expect(sourceCredentialAfter == sourceCredentialBefore, "isolated capture changed source credential")
                try expect(targetCredentialAfter == targetCredentialBefore, "isolated capture changed target credential")
                try expect(credentialFilesAfter.count == credentialFilesBefore.count + 1, "isolated capture missed C credential")
                try expect(marker == nil, "isolated capture left a capture marker")
                try expect(journal == nil, "isolated capture created a capture journal")
                try expect(quitRequestCount == 0, "isolated capture sent a quit request")
                try expect(confirmations.counts.isEmpty, "independent process requested SIGTERM approval")
                try expect(processes.terminatedPIDs.isEmpty, "independent process received SIGTERM")
                try expect(launchCount == 0, "isolated capture launched the app")
            }
        },
        TestCase("CLI capture blocks an app launch during the process snapshot") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let auth = Data(
                    #"{"auth_mode":"chatgpt","tokens":{"id_token":"id","access_token":"access","refresh_token":"refresh"}}"#.utf8
                )
                try auth.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: URL(fileURLWithPath: "/usr/bin/true"),
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let runningPIDs = await MainActor.run {
                    RunningPIDSequence([[], [42]])
                }
                let provider = LocalCLIDataProvider(
                    storeURL: directory.appendingPathComponent("store", isDirectory: true),
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in runningPIDs.next() }
                )

                let result = await CLIApplication(provider: provider).run(
                    arguments: ["profile", "capture", "--label", "A"],
                    mutationConfirmed: true
                )

                try expect(result.standardError == "error=process_blocked\n", "snapshot race allowed capture")
            }
        },
        TestCase("CLI capture detects an auth replacement after identity verification") {
            try await withCaptureTemporaryDirectory { directory in
                let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
                try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
                let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
                let originalAuth = Data(
                    #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"fixture-id","access_token":"fixture-access","refresh_token":"fixture-refresh"}}"#.utf8
                )
                try originalAuth.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
                let replacement = Data(
                    #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"other-id","access_token":"other-access","refresh_token":"other-refresh"}}"#.utf8
                )
                let executable = try makeCaptureAppServer(in: directory, rotateToOtherAccount: false)
                let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
                let descriptor = CodexAppDescriptor(
                    bundleURL: bundleURL,
                    mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
                    bundledCodexURL: executable,
                    bundleIdentifier: "com.openai.codex",
                    version: "26.721.41059",
                    build: "5848",
                    appSigningIdentifier: "com.openai.codex",
                    bundledCodexSigningIdentifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
                let provider = LocalCLIDataProvider(
                    storeURL: directory.appendingPathComponent("store", isDirectory: true),
                    activeAuthURL: authURL,
                    processProvider: MutatingProcessSnapshotProvider(
                        mutationCall: 6,
                        url: authURL,
                        contents: replacement
                    ),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in [] }
                )
                let application = CLIApplication(provider: provider)

                let captured = await application.run(
                    arguments: ["profile", "capture", "--label", "A"],
                    mutationConfirmed: true
                )
                let listed = await application.run(arguments: ["profiles", "list"])
                let authAfter = try Data(contentsOf: authURL)

                try expect(captured.standardError == "error=active_auth_changed\n", "auth race was not detected")
                try expect(listed.standardOutput == "profiles=none\n", "raced auth was registered")
                try expect(authAfter == originalAuth, "auth race did not restore the original")
            }
        },
    ]
#if SPIKE_FAULT_INJECTION
    tests.append(rollbackTestConfirmationTest())
#endif
    return tests
}

#if SPIKE_FAULT_INJECTION
private func rollbackTestConfirmationTest() -> TestCase {
    TestCase("CLIApplication rollback test requires explicit confirmation") {
        let provider = StubCLIDataProvider(
            profiles: [],
            capturedProfile: ProfileListItem(
                id: ProfileID(UUID()),
                label: "A",
                email: "rollback-secret@private.example",
                active: true,
                needsRelogin: false
            )
        )
        let application = CLIApplication(provider: provider)
        let arguments = ["switch", "--target", "B", "--test-post-launch-rollback"]

        let denied = await application.run(arguments: arguments)
        let tested = await application.run(arguments: arguments, mutationConfirmed: true)
        let mistyped = await application.run(
            arguments: ["switch", "--target", "B", "--test-post-launch-rollbac"],
            mutationConfirmed: true
        )
        let targets = await provider.rollbackTestTargets

        try expect(denied.exitCode == 77, "unconfirmed rollback test was not rejected")
        try expect(denied.standardError == "error=confirmation_required\n", "rollback confirmation changed")
        try expect(tested.exitCode == 0, "confirmed rollback test failed")
        try expect(tested.standardOutput.contains("rollback_test=passed"), "rollback PASS output missing")
        try expect(tested.standardOutput.contains("active=true label=A"), "restored source profile missing")
        try expect(!tested.standardOutput.contains("rollback-secret"), "rollback source identity leaked")
        try expect(mistyped.standardError == "error=invalid_command\n", "mistyped fault flag was accepted")
        try expect(targets == ["B"], "rollback test was dispatched before confirmation")
    }
}

#endif

private struct EmptyProcessSnapshotProvider: ProcessSnapshotProviding {
    func snapshot() throws -> [ProcessRecord] { [] }
}

private final class TerminableProcessSnapshotProvider: ProcessSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var records = [ProcessRecord]()
    private var terminated = [Int32]()

    var terminatedPIDs: [Int32] {
        lock.withLock { terminated }
    }

    func snapshot() throws -> [ProcessRecord] {
        lock.withLock { records }
    }

    func install(_ record: ProcessRecord) {
        lock.withLock { records = [record] }
    }

    func install(_ newRecords: [ProcessRecord]) {
        lock.withLock { records = newRecords }
    }

    func contains(pid: Int32) -> Bool {
        lock.withLock { records.contains(where: { $0.identity.pid == pid }) }
    }

    func terminate(_ record: ProcessRecord) {
        lock.withLock {
            guard records.contains(record) else { return }
            records.removeAll { $0.identity == record.identity }
            terminated.append(record.identity.pid)
        }
    }
}

private final class CallTriggeredProcessSnapshotProvider: ProcessSnapshotProviding, @unchecked Sendable {
    private let triggerCall: Int
    private let record: ProcessRecord
    private let lock = NSLock()
    private var callCount = 0
    private var terminated = [Int32]()

    init(triggerCall: Int, record: ProcessRecord) {
        self.triggerCall = triggerCall
        self.record = record
    }

    var terminatedPIDs: [Int32] {
        lock.withLock { terminated }
    }

    func snapshot() throws -> [ProcessRecord] {
        lock.withLock {
            callCount += 1
            return callCount >= triggerCall ? [record] : []
        }
    }

    func terminate(_ process: ProcessRecord) {
        lock.withLock { terminated.append(process.identity.pid) }
    }
}

private final class RegistrationIntentCredentialStore: CredentialStoring, @unchecked Sendable {
    private let base: FileCredentialStore
    private let storeURL: URL
    private let onSave: () throws -> Void
    private let lock = NSLock()
    private var recordedProfileIDs = [ProfileID]()

    init(storeURL: URL, onSave: @escaping () throws -> Void = {}) {
        self.storeURL = storeURL
        self.onSave = onSave
        base = FileCredentialStore(rootURL: storeURL)
    }

    var pendingProfileIDs: [ProfileID] {
        lock.withLock { recordedProfileIDs }
    }

    func saveCredential(_ credential: CredentialBlob, for profileID: ProfileID) throws {
        let registry = try SpikeStore.openExisting(at: storeURL).loadRegistry()
        guard registry.activeProfileID != profileID,
              registry.profiles.contains(where: { $0.id == profileID && $0.needsRelogin }) else {
            throw TestFailure(description: "credential save had no durable pending profile")
        }
        lock.withLock { recordedProfileIDs.append(profileID) }
        try base.saveCredential(credential, for: profileID)
        try onSave()
    }

    func loadCredential(for profileID: ProfileID) throws -> CredentialBlob {
        try base.loadCredential(for: profileID)
    }

    func removeCredential(for profileID: ProfileID) throws {
        try base.removeCredential(for: profileID)
    }
}

private final class TerminationConfirmationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCounts = [Int]()

    var counts: [Int] { lock.withLock { recordedCounts } }

    func confirm(_ count: Int) -> Bool {
        lock.withLock { recordedCounts.append(count) }
        return true
    }
}

private actor AsyncTerminationConfirmationRecorder {
    private let result: Bool
    private(set) var counts = [Int]()

    init(result: Bool) {
        self.result = result
    }

    func confirm(_ count: Int) async -> Bool {
        counts.append(count)
        await Task.yield()
        return result
    }
}

private final class MutatingProcessSnapshotProvider: ProcessSnapshotProviding, @unchecked Sendable {
    private let mutationCall: Int
    private let url: URL
    private let contents: Data
    private let lock = NSLock()
    private var callCount = 0

    init(mutationCall: Int, url: URL, contents: Data) {
        self.mutationCall = mutationCall
        self.url = url
        self.contents = contents
    }

    func snapshot() throws -> [ProcessRecord] {
        lock.lock()
        callCount += 1
        let shouldMutate = callCount == mutationCall
        lock.unlock()
        if shouldMutate {
            try contents.write(to: url)
        }
        return []
    }
}

private final class FinalizationSyncFailureGate: @unchecked Sendable {
    private let storeURL: URL
    private let failure: DurableFileFailure
    private let lock = NSLock()
    private var shouldFailSync = false

    init(storeURL: URL, failure: DurableFileFailure) {
        self.storeURL = storeURL
        self.failure = failure
    }

    func removeJournal() throws -> DurableRemoval {
        _ = try SpikeStore.openExisting(at: storeURL).removeJournal()
        lock.withLock { shouldFailSync = true }
        throw failure
    }

    func sync() throws {
        if lock.withLock({ shouldFailSync }) {
            throw failure
        }
    }
}

@MainActor
private final class RootExitDuringSnapshotPIDs {
    private let processes: TerminableProcessSnapshotProvider
    private let roots: [ProcessRecord]
    private var rootExitRequested = false
    private var checksAfterRequest = 0

    init(
        processes: TerminableProcessSnapshotProvider,
        roots: [ProcessRecord]
    ) {
        self.processes = processes
        self.roots = roots
    }

    func requestRootExit() {
        rootExitRequested = true
        checksAfterRequest = 0
    }

    func current() -> [Int32] {
        if rootExitRequested {
            checksAfterRequest += 1
            if checksAfterRequest == 2 {
                processes.install([])
                rootExitRequested = false
            }
        }
        return roots.filter { processes.contains(pid: $0.identity.pid) }.map(\.identity.pid)
    }
}

@MainActor
private final class RunningPIDSequence {
    private var values: [[Int32]]

    init(_ values: [[Int32]]) {
        self.values = values
    }

    func next() -> [Int32] {
        values.removeFirst()
    }
}

@MainActor
private final class AppLaunchRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
private final class DelayedLaunchPIDVisibility {
    private let pid: Int32
    private(set) var launchCount = 0
    private(set) var observations: [[Int32]] = []

    init(pid: Int32) {
        self.pid = pid
    }

    func launch() -> Int32 {
        launchCount += 1
        return pid
    }

    func current() -> [Int32] {
        guard launchCount > 0 else { return [] }
        let visiblePIDs = observations.count < 2 ? [] : [pid]
        observations.append(visiblePIDs)
        return visiblePIDs
    }
}

private struct ReloginFixture: Sendable {
    let storeURL: URL
    let authURL: URL
    let source: ProfileMetadata
    let target: ProfileMetadata
    let sourceAuthData: Data
    let sourceCredential: CredentialBlob
    let staleTargetCredential: CredentialBlob
    let refreshedTargetCredential: CredentialBlob
    let descriptor: CodexAppDescriptor
}

private func makeReloginFixture(
    in directory: URL,
    activeAuthIsSource: Bool = false,
    isolatedLoginAccount: String = "b",
    isolatedLoginExitCode: Int32 = 0,
    rotateActiveToOtherAccount: Bool = false,
    holdVerifierPipesOpen: Bool = false,
    probeCountURL: URL? = nil,
    failActiveRefresh: Bool = false,
    failConfiguredRefresh: Bool = false
) throws -> ReloginFixture {
    let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
    let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
    let sourceAuthData = Data(
        #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
    )
    let activeB = Data(
        #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"current-b-id","access_token":"current-b-access","refresh_token":"current-b-refresh"}}"#.utf8
    )
    try (activeAuthIsSource ? sourceAuthData : activeB).write(
        to: authURL,
        options: .withoutOverwriting
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

    let storeURL = directory.appendingPathComponent("store", isDirectory: true)
    let store = try SpikeStore.create(at: storeURL)
    let source = ProfileMetadata(
        id: ProfileID(UUID()),
        label: "A",
        email: "person@example.invalid",
        planType: "plus",
        needsRelogin: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let target = ProfileMetadata(
        id: ProfileID(UUID()),
        label: "B",
        email: "b@example.invalid",
        planType: "plus",
        needsRelogin: true,
        createdAt: Date(timeIntervalSince1970: 1_700_000_001),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let sourceCredential = try CredentialBlob(validating: sourceAuthData)
    let staleTargetCredential = try CredentialBlob(validating: Data(
        #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"stale-b-id","access_token":"stale-b-access","refresh_token":"stale-b-refresh"}}"#.utf8
    ))
    let refreshedTargetCredential = try CredentialBlob(validating: Data(
        #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id-rotated","access_token":"b-access-rotated","refresh_token":"b-refresh-rotated"}}"#.utf8
    ))
    _ = try store.saveCredential(sourceCredential, for: source.id)
    _ = try store.saveCredential(staleTargetCredential, for: target.id)
    _ = try store.saveRegistry(ProfileRegistry(activeProfileID: source.id, profiles: [source, target]))

    let failRefreshHomeURL: URL? = if failActiveRefresh {
        codexHome
    } else if failConfiguredRefresh {
        storeURL.appendingPathComponent("credential-verification-workspace", isDirectory: true)
    } else {
        nil
    }
    let executable = try makeCaptureAppServer(
        in: directory,
        rotateToOtherAccount: rotateActiveToOtherAccount,
        rotateToOtherAccountHomeURL: rotateActiveToOtherAccount
            ? (activeAuthIsSource
                ? storeURL.appendingPathComponent("isolated-login-workspace", isDirectory: true)
                : codexHome)
            : nil,
        failRefreshHomeURL: failRefreshHomeURL,
        probeCountURL: probeCountURL,
        requiredJournalURL: activeAuthIsSource
            ? nil
            : storeURL.appendingPathComponent("switch-journal.json"),
        loginAccount: isolatedLoginAccount,
        loginExitCode: isolatedLoginExitCode,
        holdPipesOpen: holdVerifierPipesOpen,
        holdPipesOpenHomeURL: activeAuthIsSource
            ? storeURL.appendingPathComponent("isolated-login-workspace", isDirectory: true)
            : nil
    )
    let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
    let descriptor = CodexAppDescriptor(
        bundleURL: bundleURL,
        mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
        bundledCodexURL: executable,
        bundleIdentifier: "com.openai.codex",
        version: "26.721.41059",
        build: "5848",
        appSigningIdentifier: "com.openai.codex",
        bundledCodexSigningIdentifier: "codex",
        teamIdentifier: "2DC432GLL2"
    )
    return ReloginFixture(
        storeURL: storeURL,
        authURL: authURL,
        source: source,
        target: target,
        sourceAuthData: sourceAuthData,
        sourceCredential: sourceCredential,
        staleTargetCredential: staleTargetCredential,
        refreshedTargetCredential: refreshedTargetCredential,
        descriptor: descriptor
    )
}

private func prepareReloginCrash(
    _ fixture: ReloginFixture,
    phase: SwitchPhase,
    targetPrepared: Bool = true
) throws -> (activeTarget: CredentialBlob, journal: SwitchJournalRecord) {
    let store = try SpikeStore.openExisting(at: fixture.storeURL)
    let activeTarget = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
    if targetPrepared {
        let preparedTarget = ProfileMetadata(
            id: fixture.target.id,
            label: fixture.target.label,
            email: fixture.target.email,
            planType: fixture.target.planType,
            needsRelogin: false,
            createdAt: fixture.target.createdAt,
            updatedAt: fixture.target.updatedAt
        )
        _ = try store.saveCredential(activeTarget, for: fixture.target.id)
        _ = try store.saveRegistry(
            ProfileRegistry(
                activeProfileID: fixture.source.id,
                profiles: [fixture.source, preparedTarget]
            )
        )
    }
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let journal = SwitchJournalRecord(
        transactionID: UUID(),
        phase: phase,
        previousProfileID: fixture.source.id,
        targetProfileID: fixture.target.id,
        startedAt: now,
        updatedAt: now
    )
    _ = try store.createJournalIfAbsent(journal)
    return (activeTarget, journal)
}

private struct ManualRecoveryFixture: Sendable {
    let storeURL: URL
    let authURL: URL
    let targetAuthData: Data
    let previous: ProfileMetadata
    let target: ProfileMetadata
    let descriptor: CodexAppDescriptor
}

private func makeManualRecoveryFixture(in directory: URL) throws -> ManualRecoveryFixture {
    let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
    let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
    let targetData = Data(
        #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
    )
    let targetCredential = try CredentialBlob(validating: targetData)
    try targetData.write(to: authURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

    let storeURL = directory.appendingPathComponent("store", isDirectory: true)
    let store = try SpikeStore.create(at: storeURL)
    let previous = ProfileMetadata(
        id: ProfileID(UUID()),
        label: "A",
        email: "person@example.invalid",
        planType: "plus",
        needsRelogin: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let target = ProfileMetadata(
        id: ProfileID(UUID()),
        label: "B",
        email: "b@example.invalid",
        planType: "plus",
        needsRelogin: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_001),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let previousCredential = try CredentialBlob(validating: Data(
        #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
    ))
    _ = try store.saveCredential(previousCredential, for: previous.id)
    _ = try store.saveCredential(targetCredential, for: target.id)
    _ = try store.saveRegistry(
        ProfileRegistry(activeProfileID: target.id, profiles: [previous, target])
    )
    let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
    _ = try store.createJournalIfAbsent(
        SwitchJournalRecord(
            transactionID: UUID(),
            phase: .rollbackFailed,
            previousProfileID: previous.id,
            targetProfileID: target.id,
            startedAt: startedAt,
            updatedAt: startedAt
        )
    )

    let executable = try makeCaptureAppServer(in: directory, rotateToOtherAccount: false)
    let bundleURL = directory.appendingPathComponent("ChatGPT.app", isDirectory: true)
    let descriptor = CodexAppDescriptor(
        bundleURL: bundleURL,
        mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/ChatGPT"),
        bundledCodexURL: executable,
        bundleIdentifier: "com.openai.codex",
        version: "26.721.41059",
        build: "5848",
        appSigningIdentifier: "com.openai.codex",
        bundledCodexSigningIdentifier: "codex",
        teamIdentifier: "2DC432GLL2"
    )
    return ManualRecoveryFixture(
        storeURL: storeURL,
        authURL: authURL,
        targetAuthData: targetData,
        previous: previous,
        target: target,
        descriptor: descriptor
    )
}

private func makeCommittedCaptureRecoveryFixture(
    in directory: URL,
    phase: SwitchPhase
) throws -> ManualRecoveryFixture {
    let fixture = try makeManualRecoveryFixture(in: directory)
    let store = try SpikeStore.openExisting(at: fixture.storeURL)
    _ = try store.removeJournal()
    let markerURL = fixture.storeURL.appendingPathComponent("capture-profile-id", isDirectory: false)
    _ = try DarwinDurableFileOperations().replace(
        contents: SensitiveBytes(Data("\(fixture.target.id)\n".utf8)),
        at: markerURL,
        expecting: .absent
    )
    let now = Date(timeIntervalSince1970: 1_700_000_200)
    _ = try store.createJournalIfAbsent(
        SwitchJournalRecord(
            transactionID: UUID(),
            phase: phase,
            previousProfileID: fixture.previous.id,
            targetProfileID: fixture.target.id,
            startedAt: now,
            updatedAt: now
        )
    )
    return fixture
}

private func withCaptureTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-capture-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func makeCaptureAppServer(
    in directory: URL,
    rotateToOtherAccount: Bool,
    rotateToOtherAccountHomeURL: URL? = nil,
    failRefreshHomeURL: URL? = nil,
    failProbeHomeURL: URL? = nil,
    probeCountURL: URL? = nil,
    requiredJournalURL: URL? = nil,
    loginAccount: String? = nil,
    loginExitCode: Int32 = 0,
    holdPipesOpen: Bool = false,
    holdPipesOpenHomeURL: URL? = nil
) throws -> URL {
    let executable = directory.appendingPathComponent("fake-capture-app-server")
    let script = #"""
    #!/bin/zsh
    if [[ " $* " == *" login " && -n "\#(loginAccount ?? "")" ]]; then
      [[ "\#(loginExitCode)" == "0" ]] || exit "\#(loginExitCode)"
      print -rn -- '{"auth_mode":"chatgpt","test_account":"\#(loginAccount ?? "")","tokens":{"id_token":"isolated-id","access_token":"isolated-access","refresh_token":"isolated-refresh"}}' > "$CODEX_HOME/auth.json"
      chmod 600 "$CODEX_HOME/auth.json"
      exit 0
    fi
    if [[ -n "\#(probeCountURL?.path ?? "")" ]]; then
      probe_count=0
      [[ -f "\#(probeCountURL?.path ?? "")" ]] && IFS= read -r probe_count < "\#(probeCountURL?.path ?? "")"
      print -r -- $((probe_count + 1)) > "\#(probeCountURL?.path ?? "")"
    fi
    if grep -q '"test_account":"c"' "$CODEX_HOME/auth.json"; then
      account_email='c@example.invalid'
    elif grep -q '"test_account":"b"' "$CODEX_HOME/auth.json"; then
      account_email='b@example.invalid'
    else
      account_email='person@example.invalid'
    fi
    IFS= read -r initialize
    print -r -- '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r account_read
    if [[ -n "\#(failProbeHomeURL?.path ?? "")" && "$CODEX_HOME" == "\#(failProbeHomeURL?.path ?? "")" ]]; then
      exit 8
    fi
    if [[ "$account_read" == *'"refreshToken":true'* ]]; then
      if [[ -n "\#(requiredJournalURL?.path ?? "")" && ! -f "\#(requiredJournalURL?.path ?? "")" ]]; then
        exit 10
      fi
      if [[ -n "\#(failRefreshHomeURL?.path ?? "")" && "$CODEX_HOME" == "\#(failRefreshHomeURL?.path ?? "")" ]]; then
        exit 9
      fi
      if [[ "\#(rotateToOtherAccount)" == "true" && ( -z "\#(rotateToOtherAccountHomeURL?.path ?? "")" || "$CODEX_HOME" == "\#(rotateToOtherAccountHomeURL?.path ?? "")" ) ]]; then
        if [[ "$account_email" == "b@example.invalid" ]]; then
          print -rn -- '{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"other-id","access_token":"other-access","refresh_token":"other-refresh"}}' > "$CODEX_HOME/auth.json"
        else
          print -rn -- '{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"other-id","access_token":"other-access","refresh_token":"other-refresh"}}' > "$CODEX_HOME/auth.json"
        fi
      elif [[ "$account_email" == "c@example.invalid" ]]; then
        print -rn -- '{"auth_mode":"chatgpt","test_account":"c","tokens":{"id_token":"c-id-rotated","access_token":"c-access-rotated","refresh_token":"c-refresh-rotated"}}' > "$CODEX_HOME/auth.json"
      elif [[ "$account_email" == "b@example.invalid" ]]; then
        print -rn -- '{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id-rotated","access_token":"b-access-rotated","refresh_token":"b-refresh-rotated"}}' > "$CODEX_HOME/auth.json"
      else
        print -rn -- '{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"fixture-id-rotated","access_token":"fixture-access-rotated","refresh_token":"fixture-refresh-rotated"}}' > "$CODEX_HOME/auth.json"
      fi
    fi
    print -r -- '{"id":2,"result":{"account":{"type":"chatgpt","email":"'"$account_email"'","planType":"plus"},"requiresOpenaiAuth":true}}'
    if [[ "\#(holdPipesOpen)" == "true" && ( -z "\#(holdPipesOpenHomeURL?.path ?? "")" || "$CODEX_HOME" == "\#(holdPipesOpenHomeURL?.path ?? "")" ) ]]; then
      (sleep 3) &!
      exit 0
    fi
    if IFS= read -r rate_limits_read; then
      grep -q '"auth_mode":"chatgptAuthTokens"' "$CODEX_HOME/auth.json" || exit 11
      grep -q '"refresh_token":""' "$CODEX_HOME/auth.json" || exit 12
      if [[ "$account_email" == "b@example.invalid" ]]; then
        plan_type='team'
        used_percent=35
      else
        plan_type='pro'
        used_percent=25
      fi
      print -r -- '{"id":3,"result":{"rateLimits":{"planType":"free","primary":{"usedPercent":1,"windowDurationMins":43200}},"rateLimitsByLimitId":{"codex":{"planType":"'"$plan_type"'","primary":{"usedPercent":'"$used_percent"',"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":40,"windowDurationMins":10080}},"codex_bengalfox":{"planType":"spark","primary":{"usedPercent":99,"windowDurationMins":10080}}}}}'
      while IFS= read -r ignored; do :; done
    fi
    """#
    try Data(script.utf8).write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

private actor StubCLIDataProvider: CLIDataProviding {
    let profilesValue: [ProfileListItem]
    let failureCanary: String?
    let capturedProfile: ProfileListItem
    let captureFailure: LocalCLIDataProviderFailure?
    let switchFailure: CodexAppLocatorFailure?
    let recoveryStatusValue: RecoveryCLIStatus
    private(set) var capturedLabels = [String]()
    private(set) var switchedTargets = [String]()
#if SPIKE_FAULT_INJECTION
    private(set) var rollbackTestTargets = [String]()
#endif

    init(
        profiles: [ProfileListItem],
        failureCanary: String? = nil,
        capturedProfile: ProfileListItem? = nil,
        captureFailure: LocalCLIDataProviderFailure? = nil,
        switchFailure: CodexAppLocatorFailure? = nil,
        recoveryStatus: RecoveryCLIStatus = .none
    ) {
        profilesValue = profiles
        self.failureCanary = failureCanary
        self.capturedProfile = capturedProfile ?? ProfileListItem(
            id: ProfileID(UUID()),
            label: "captured",
            email: "captured@example.invalid",
            active: true,
            needsRelogin: false
        )
        self.captureFailure = captureFailure
        self.switchFailure = switchFailure
        recoveryStatusValue = recoveryStatus
    }

    func inspect() async throws -> InspectionReport {
        if let failureCanary {
            throw StubCLIError.text(failureCanary)
        }
        return InspectionReport(
            applicationStatus: .ready,
            version: "test",
            build: "test",
            authStatus: .privateRegularFile,
            appOwnedProcessCount: 0,
            independentCodexProcessCount: 0,
            unclassifiedRelevantProcessCount: 0
        )
    }

    func profiles() async throws -> [ProfileListItem] {
        profilesValue
    }

    func captureProfile(label: String) async throws -> ProfileListItem {
        capturedLabels.append(label)
        if let captureFailure {
            throw captureFailure
        }
        return capturedProfile
    }

    func syncActiveProfile() async throws -> ProfileListItem {
        capturedProfile
    }

    func switchProfile(target: String) async throws -> ProfileListItem {
        switchedTargets.append(target)
        if let switchFailure {
            throw switchFailure
        }
        return capturedProfile
    }

    func restoreRecoveryProfile(target: String) async throws -> RecoveryRestoreOutcome {
        .restoredAndLaunched(capturedProfile)
    }

#if SPIKE_FAULT_INJECTION
    func testPostLaunchRollback(target: String) async throws -> ProfileListItem {
        rollbackTestTargets.append(target)
        return capturedProfile
    }
#endif

    func recoveryStatus() async throws -> RecoveryCLIStatus {
        recoveryStatusValue
    }
}

private enum StubCLIError: Error {
    case text(String)
}
