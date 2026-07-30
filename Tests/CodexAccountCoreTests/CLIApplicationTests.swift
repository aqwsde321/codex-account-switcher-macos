import Foundation
import CodexAccountCore

func cliApplicationTests() -> [TestCase] {
    [
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

                let independentProcesses = TerminableProcessSnapshotProvider()
                independentProcesses.install(
                    ProcessRecord(
                        identity: ProcessIdentity(pid: 88, startSeconds: 200, startMicroseconds: 1),
                        parentPID: 1,
                        executablePath: "/opt/homebrew/bin/codex",
                        nameHint: "codex"
                    )
                )
                let blockedApplication = CLIApplication(
                    provider: LocalCLIDataProvider(
                        storeURL: storeURL,
                        activeAuthURL: authURL,
                        processProvider: independentProcesses,
                        locateApp: { descriptor },
                        runningApplicationPIDs: { _ in [] },
                        requestApplicationTermination: { _ in [] },
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
}

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

    func recoveryStatus() async throws -> RecoveryCLIStatus {
        .none
    }
}

private enum StubCLIError: Error {
    case text(String)
}
