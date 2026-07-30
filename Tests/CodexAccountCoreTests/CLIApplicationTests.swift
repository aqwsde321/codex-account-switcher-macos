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
                let authAfter = try Data(contentsOf: authURL)
                let store = try SpikeStore.openExisting(
                    at: directory.appendingPathComponent("store", isDirectory: true)
                )
                let registry = try store.loadRegistry()
                let storedCredential = try store.loadCredential(for: registry.profiles[0].id)
                let activeCredential = try CredentialBlob(validating: authAfter)

                try expect(captured.exitCode == 0, "local capture failed")
                try expect(listed.exitCode == 0, "captured profile could not be listed")
                try expect(listed.standardOutput.contains("active=true"), "captured profile is not active")
                try expect(listed.standardOutput.contains("label=A"), "captured profile label missing")
                try expect(listed.standardOutput.contains("email=<email-redacted>"), "identity was not redacted")
                try expect(!listed.standardOutput.contains("person@example.invalid"), "identity leaked")
                try expect(authAfter != auth, "refresh did not update the active auth file")
                try expect(storedCredential == activeCredential, "refreshed credential was not captured")
            }
        },
        TestCase("CLI capture stores a second profile and restores the first") {
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

                let executable = try makeCaptureAppServer(
                    in: directory,
                    rotateToOtherAccount: false,
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
                let lingeringProcesses = TerminableProcessSnapshotProvider()
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
                let provider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: lingeringProcesses,
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in
                        if lingeringProcesses.contains(pid: appRootIdentity.pid) {
                            return [appRootIdentity.pid]
                        }
                        return launches.count >= 2 ? [42] : []
                    },
                    requestApplicationTermination: { _ in
                        lingeringProcesses.install(orphanedAppChild)
                        return [appRootIdentity.pid]
                    },
                    confirmAppOwnedTermination: { _ in true },
                    requestProcessTermination: { lingeringProcesses.terminate($0) },
                    normalTerminationGracePolls: 0,
                    quiescenceSleep: { _ in },
                    launchApplication: { _ in
                        launches.record()
                        return 42
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

                lingeringProcesses.install([appRoot, appChild])
                let switchArguments = ["switch", "--target", "B"]
                let deniedSwitch = await application.run(arguments: switchArguments)
                let switched = await application.run(
                    arguments: switchArguments,
                    mutationConfirmed: true
                )
                let switchedRegistry = try store.loadRegistry()
                let switchedActive = try CredentialBlob(validating: Data(contentsOf: authURL))
                let switchedStoredA = try store.loadCredential(for: profileA.id)
                let switchedStoredB = try store.loadCredential(for: profileB.id)
                let switchedList = await application.run(arguments: ["profiles", "list"])
                let switchedRecovery = await application.run(arguments: ["recovery", "status"])
                let switchedLaunchCount = await MainActor.run { launches.count }

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
                let faultLateTargetChild = ProcessRecord(
                    identity: ProcessIdentity(pid: 106, startSeconds: 305, startMicroseconds: 1),
                    parentPID: faultTargetRoot.identity.pid,
                    executablePath: bundleURL
                        .appendingPathComponent("Contents/Helpers/late-target-worker")
                        .path,
                    nameHint: "late-target-worker"
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
                            } else if running.contains(faultSourceRoot) {
                                running.forEach(faultProcesses.terminate)
                            }
                            return running.map(\.identity.pid)
                        },
                        confirmAppOwnedTermination: faultConfirmations.confirm,
                        requestProcessTermination: { process in
                            faultProcesses.terminate(process)
                            if process.identity == faultTargetRoot.identity {
                                faultProcesses.install(faultLateTargetChild)
                            }
                        },
                        normalTerminationGracePolls: 0,
                        quiescenceSleep: { _ in },
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

                try expect(faultResult.exitCode == 0, "B-011 rollback test failed: \(faultResult.standardError)")
                try expect(faultResult.standardOutput.contains("rollback_test=passed"), "B-011 PASS missing")
                try expect(faultResult.standardOutput.contains("active=true label=B"), "B was not restored")
                try expect(faultAuthAfter == faultAuthBefore, "B-011 did not restore active auth")
                try expect(faultRegistryAfter == faultRegistryBefore, "B-011 changed active registry")
                try expect(faultRecovery.standardOutput == "recovery=none\n", "B-011 left recovery state")
                try expect(faultLaunchCount == 2, "B-011 did not launch target and restored source")
                try expect(faultConfirmations.counts == [1, 1], "late target child was not confirmed separately")
                try expect(!faultProcesses.contains(pid: faultTargetRoot.identity.pid), "target app remained running")
                try expect(!faultProcesses.contains(pid: faultLateTargetChild.identity.pid), "late target child remained running")
                try expect(faultProcesses.contains(pid: faultSourceRoot.identity.pid), "source app was not relaunched")
#endif

                let independentProcesses = TerminableProcessSnapshotProvider()
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

                let declinedProcesses = TerminableProcessSnapshotProvider()
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
                        confirmAppOwnedTermination: { _ in false },
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
                try expect(captured.standardOutput.contains("active=false"), "second profile remained active")
                try expect(registry.profiles.count == 2, "second profile was not registered")
                try expect(registry.activeProfileID == profileA.id, "first profile was not restored")
                try expect(profileB.email == "b@example.invalid", "second identity changed")
                try expect(restoredActive == storedA, "active auth does not match restored first profile")
                try expect(listed.standardOutput.contains("active=true label=A"), "first profile is not active")
                try expect(listed.standardOutput.contains("active=false label=B"), "second profile is not inactive")
                try expect(recovery.standardOutput == "recovery=none\n", "second capture left recovery state")
                try expect(launchCount == 1, "restored first account was not launched once")
                try expect(deniedSwitch.standardError == "error=confirmation_required\n", "switch ran without confirmation")
                try expect(switched.exitCode == 0, "A to B switch failed: \(switched.standardError)")
                try expect(switched.standardOutput.contains("active=true label=B"), "switch output did not activate B")
                try expect(switchedRegistry.activeProfileID == profileB.id, "registry did not activate B")
                try expect(switchedActive == switchedStoredB, "active auth does not match stored B")
                try expect(switchedStoredA != storedA, "switch did not refresh stored A")
                try expect(switchedList.standardOutput.contains("active=false label=A"), "A remained active")
                try expect(switchedList.standardOutput.contains("active=true label=B"), "B is not active")
                try expect(switchedRecovery.standardOutput == "recovery=none\n", "switch left recovery state")
                try expect(switchedLaunchCount == 2, "target app was not launched once")
                try expect(
                    lingeringProcesses.terminatedPIDs == [lingeringIdentity.pid],
                    "confirmed switch did not SIGTERM the captured app-owned survivor"
                )
                try expect(blockedSwitch.standardError == "error=process_blocked\n", "independent Codex was not blocked")
                try expect(independentProcesses.terminatedPIDs.isEmpty, "independent Codex received SIGTERM")
                try expect(blockedAuthAfter == blockedAuthBefore, "blocked switch changed active auth")
                try expect(blockedRegistryAfter == blockedRegistryBefore, "blocked switch changed the registry")
                try expect(blockedRecovery.standardOutput == "recovery=none\n", "blocked switch left recovery state")
                try expect(declinedSwitch.standardError == "error=process_blocked\n", "declined SIGTERM was not blocked")
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

                let manualRegistry = try ProfileRegistry(
                    activeProfileID: profileA.id,
                    profiles: try store.loadRegistry().profiles
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
                try expect(
                    restoredManualAuth == manualStoredA,
                    "manual recovery did not restore auth A"
                )
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
        TestCase("CLI second capture rejects the registered account before active refresh") {
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
                    failRefreshHomeURL: codexHome
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
                    "registered account reached active refresh: \(captured.standardError)"
                )
                try expect(registry.profiles == [profileA], "duplicate profile was registered")
                try expect(registry.activeProfileID == profileA.id, "first profile stopped being active")
                try expect(activeCredential == storedCredential, "first credential was not restored")
                try expect(recovery.standardOutput == "recovery=none\n", "duplicate rejection left recovery")
            }
        },
        TestCase("CLI second capture restores the first profile after refreshed identity mismatch") {
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
                _ = try store.saveCredential(
                    CredentialBlob(validating: Data(
                        #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
                    )),
                    for: profileA.id
                )
                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileA.id, profiles: [profileA])
                )

                let executable = try makeCaptureAppServer(
                    in: directory,
                    rotateToOtherAccount: true,
                    rotateToOtherAccountHomeURL: codexHome
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

                try expect(captured.standardError == "error=identity_mismatch\n", "mismatch error changed")
                try expect(registry.profiles == [profileA], "mismatched second profile was registered")
                try expect(registry.activeProfileID == profileA.id, "first profile stopped being active")
                try expect(activeCredential == storedCredential, "first credential was not restored")
                try expect(recovery.standardOutput == "recovery=none\n", "completed rollback left recovery")
            }
        },
        TestCase("CLI second capture preserves recovery when a process appears during final A verification") {
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

                let probeCountURL = directory.appendingPathComponent("probe-count")
                let executable = try makeCaptureAppServer(
                    in: directory,
                    rotateToOtherAccount: false,
                    probeCountURL: probeCountURL
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
                let runningPIDs = await MainActor.run {
                    ProbeCountRunningPIDs(countURL: probeCountURL, blockAt: 6)
                }
                let provider = LocalCLIDataProvider(
                    storeURL: storeURL,
                    activeAuthURL: authURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { descriptor },
                    runningApplicationPIDs: { _ in runningPIDs.current() }
                )
                let application = CLIApplication(provider: provider)

                let captured = await application.run(
                    arguments: ["profile", "capture", "--label", "B"],
                    mutationConfirmed: true
                )
                let activeAfter = try CredentialBlob(validating: Data(contentsOf: authURL))
                let storedA = try store.loadCredential(for: profileA.id)
                let registry = try store.loadRegistry()
                let journal = try store.loadJournalIfPresent()
                let pendingCaptureID = try store.loadCaptureProfileIDIfPresent()
                let recovery = await application.run(arguments: ["recovery", "status"])

                try expect(captured.standardError == "error=rollback_failed\n", "unsafe rollback was reported safe")
                try expect(activeAfter == storedA, "verified A bytes were not retained")
                try expect(registry.profiles.count == 2, "validated second profile was not preserved")
                try expect(registry.activeProfileID != profileA.id, "registry committed A after process race")
                try expect(journal?.phase == .rollbackFailed, "rollback failure journal was not preserved")
                try expect(pendingCaptureID != nil, "capture evidence was removed")
                try expect(recovery.standardOutput.contains("phase=rollbackFailed"), "recovery status hid failure")

                guard let pendingCaptureID,
                      let profileB = registry.profiles.first(where: { $0.id == pendingCaptureID }) else {
                    throw TestFailure(description: "capture recovery fixture lost target B")
                }
                let storedB = try store.loadCredential(for: profileB.id)
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

                _ = try store.saveRegistry(
                    ProfileRegistry(activeProfileID: profileA.id, profiles: [profileA])
                )
                _ = try store.removeCredential(for: profileB.id)
                let precommitTargetID = try store.createCaptureProfileID()
                _ = try store.saveCredential(storedB, for: precommitTargetID)
                _ = try store.createJournalIfAbsent(
                    SwitchJournalRecord(
                        transactionID: UUID(),
                        phase: .rollbackFailed,
                        previousProfileID: profileA.id,
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
                    arguments: ["recovery", "restore", "--profile", "A"],
                    mutationConfirmed: true
                )
                let precommitRegistry = try store.loadRegistry()
                let precommitAuth = try CredentialBlob(validating: Data(contentsOf: authURL))
                let precommitStoredA = try store.loadCredential(for: profileA.id)
                let precommitCredentialURL = storeURL
                    .appendingPathComponent("credentials", isDirectory: true)
                    .appendingPathComponent("\(precommitTargetID).json", isDirectory: false)
                let precommitCaptureID = try store.loadCaptureProfileIDIfPresent()
                let precommitJournal = try store.loadJournalIfPresent()
                let precommitLaunchCount = await MainActor.run { precommitLaunches.count }

                try expect(precommitRestored.exitCode == 0, "pre-commit capture recovery failed")
                try expect(precommitRegistry.profiles == [profileA], "pre-commit recovery registered target")
                try expect(precommitRegistry.activeProfileID == profileA.id, "pre-commit recovery did not activate A")
                try expect(precommitAuth == precommitStoredA, "pre-commit recovery did not restore A auth")
                try expect(
                    !FileManager.default.fileExists(atPath: precommitCredentialURL.path),
                    "pre-commit recovery left temporary target credential"
                )
                try expect(precommitCaptureID == nil, "pre-commit recovery left marker")
                try expect(precommitJournal == nil, "pre-commit recovery left journal")
                try expect(precommitLaunchCount == 1, "pre-commit recovery did not relaunch A")
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
                        mutationCall: 4,
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

private final class TerminationConfirmationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCounts = [Int]()

    var counts: [Int] { lock.withLock { recordedCounts } }

    func confirm(_ count: Int) -> Bool {
        lock.withLock { recordedCounts.append(count) }
        return true
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
private final class ProbeCountRunningPIDs {
    private let countURL: URL
    private let blockAt: Int

    init(countURL: URL, blockAt: Int) {
        self.countURL = countURL
        self.blockAt = blockAt
    }

    func current() -> [Int32] {
        guard let data = try? Data(contentsOf: countURL),
              let count = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              count >= blockAt else {
            return []
        }
        return [42]
    }
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
    probeCountURL: URL? = nil,
    requiredJournalURL: URL? = nil,
    holdPipesOpen: Bool = false
) throws -> URL {
    let executable = directory.appendingPathComponent("fake-capture-app-server")
    let script = #"""
    #!/bin/zsh
    if [[ -n "\#(probeCountURL?.path ?? "")" ]]; then
      probe_count=0
      [[ -f "\#(probeCountURL?.path ?? "")" ]] && IFS= read -r probe_count < "\#(probeCountURL?.path ?? "")"
      print -r -- $((probe_count + 1)) > "\#(probeCountURL?.path ?? "")"
    fi
    if grep -q '"test_account":"b"' "$CODEX_HOME/auth.json"; then
      account_email='b@example.invalid'
    else
      account_email='person@example.invalid'
    fi
    IFS= read -r initialize
    print -r -- '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r account_read
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
      elif [[ "$account_email" == "b@example.invalid" ]]; then
        print -rn -- '{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id-rotated","access_token":"b-access-rotated","refresh_token":"b-refresh-rotated"}}' > "$CODEX_HOME/auth.json"
      else
        print -rn -- '{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"fixture-id-rotated","access_token":"fixture-access-rotated","refresh_token":"fixture-refresh-rotated"}}' > "$CODEX_HOME/auth.json"
      fi
    fi
    print -r -- '{"id":2,"result":{"account":{"type":"chatgpt","email":"'"$account_email"'","planType":"plus"},"requiresOpenaiAuth":true}}'
    if [[ "\#(holdPipesOpen)" == "true" ]]; then
      (sleep 3) &!
      exit 0
    fi
    while IFS= read -r ignored; do :; done
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
        switchFailure: CodexAppLocatorFailure? = nil
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

    func restoreRecoveryProfile(target: String) async throws -> ProfileListItem {
        capturedProfile
    }

#if SPIKE_FAULT_INJECTION
    func testPostLaunchRollback(target: String) async throws -> ProfileListItem {
        rollbackTestTargets.append(target)
        return capturedProfile
    }
#endif

    func recoveryStatus() async throws -> RecoveryCLIStatus {
        .none
    }
}

private enum StubCLIError: Error {
    case text(String)
}
