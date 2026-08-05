import Darwin
import Foundation
import OSLog

private let recoveryLogger = Logger(
    subsystem: "local.codex.account-switcher",
    category: "recovery"
)

private enum ProcessTerminationFailure: Error {
    case identityChanged
    case signalFailed
}

private enum ApplicationQuiescenceFailure: Error {
    case processBlocked
}

private func sendSIGTERM(to expected: ProcessRecord) throws {
    let matches = try LibprocSnapshotProvider().snapshot().filter {
        $0.identity.pid == expected.identity.pid
    }
    guard matches.count <= 1 else {
        throw ProcessTerminationFailure.identityChanged
    }
    guard let current = matches.first else { return }
    guard current.identity == expected.identity,
          current.executablePath == expected.executablePath else {
        throw ProcessTerminationFailure.identityChanged
    }

    var result: Int32
    repeat {
        result = Darwin.kill(expected.identity.pid, SIGTERM)
    } while result == -1 && errno == EINTR
    guard result == 0 || errno == ESRCH else {
        throw ProcessTerminationFailure.signalFailed
    }
}

private let verificationChildMarkerName = "helper-child"

private struct IsolatedLoginResult {
    let credential: CredentialBlob
    let email: String
    let planType: String?
}

private func verificationChildProcessIsAlive(_ pid: Int32) throws -> Bool {
    guard pid > 0 else { throw LocalCLIDataProviderFailure.verificationWorkspaceFailed }
    var result: Int32
    repeat {
        result = Darwin.kill(pid, 0)
    } while result == -1 && errno == EINTR
    if result == 0 || errno == EPERM { return true }
    if errno == ESRCH { return false }
    throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
}

private func writeVerificationChildMarker(at url: URL, value: String) throws {
    let files = DarwinDurableFileOperations()
    let expected = try files.snapshot(at: url)
    _ = try files.replace(
        contents: SensitiveBytes(Data("\(value)\n".utf8)),
        at: url,
        expecting: expected
    )
}

#if SPIKE_FAULT_INJECTION
private enum InjectedSwitchFailure: Error {
    case postLaunchTargetVerification
}
#endif

public actor LocalCLIDataProvider: CLIDataProviding, ProfileCaptureDriving {
    private let storeURL: URL
    private let credentialStore: any CredentialStoring
    private let activeAuthURL: URL
    private let processProvider: any ProcessSnapshotProviding
    private let locateApp: @MainActor @Sendable () throws -> CodexAppDescriptor
    private let runningApplicationPIDs: @MainActor @Sendable (CodexAppDescriptor) throws -> [Int32]
    private let requestApplicationTermination: @MainActor @Sendable (CodexAppDescriptor) throws -> [Int32]
    private let confirmAppOwnedTermination: @Sendable (Int) async -> Bool
    private let requestProcessTermination: @Sendable (ProcessRecord) throws -> Void
    private let normalTerminationGracePolls: Int
    private let quiescenceSleep: @Sendable (Duration) async throws -> Void
    private let removeJournalFile: @Sendable () throws -> DurableRemoval
    private let syncStoreDirectory: @Sendable () throws -> Void
    private let activateApplication: @MainActor @Sendable (CodexAppDescriptor) throws -> Bool
    private let launchApplication: @MainActor @Sendable (CodexAppDescriptor) async throws -> Int32
    private let verificationChildIsAlive: @Sendable (Int32) throws -> Bool
    private let files = DarwinDurableFileOperations()
    private var captureStore: SpikeStore?
    private var captureLock: ExclusiveFileLock?
    private var captureProfileID: ProfileID?
    private var captureOriginalRegistry: ProfileRegistry?
    private var captureDescriptor: CodexAppDescriptor?
    private var originalCredential: CredentialBlob?
    private var originalAuthIdentity: FileIdentity?
    private var capturedAuthIdentity: FileIdentity?
    private var probeChildUnconfirmed = false
    private var captureMutationUncertain = false
    private var routedFirstCaptureCount = 0
    private var switchInProgress = false
    private var switchStore: SpikeStore?
    private var switchLock: ExclusiveFileLock?
    private var switchDescriptor: CodexAppDescriptor?
    private var switchExpectedRegistry: ProfileRegistry?
    private var switchActiveAuthDestination: ExpectedDestination?
    private var switchLaunchedApplicationPID: Int32?
    private var switchAppOwnedTerminationCandidates = [ProcessIdentity: ProcessRecord]()
    private var recoveryExpectedTransactionID: UUID?
    private var recoveryRequestsApplicationQuiescence = false
    private var targetValidationProfileID: ProfileID?
    private var isolatedLoginSession: CodexLoginSession?
    private var profileLoginOperationActive = false
    private var profileLoginCancellationRequested = false
#if SPIKE_FAULT_INJECTION
    private var injectPostLaunchVerificationFailure = false
    private var postLaunchVerificationFailureInjected = false
#endif

    public init(
        storeURL: URL,
        activeAuthURL: URL,
        credentialStore: any CredentialStoring,
        processProvider: any ProcessSnapshotProviding = LibprocSnapshotProvider(),
        confirmAppOwnedTermination: @escaping @Sendable (Int) async -> Bool = { _ in false }
    ) {
        self.storeURL = storeURL
        self.credentialStore = credentialStore
        self.activeAuthURL = activeAuthURL
        self.processProvider = processProvider
        locateApp = { try CodexAppLocator().locate() }
        runningApplicationPIDs = { descriptor in
            try CodexAppLifecycle().runningApplicationPIDs(for: descriptor)
        }
        requestApplicationTermination = { descriptor in
            try CodexAppLifecycle().requestNormalTermination(descriptor)
        }
        self.confirmAppOwnedTermination = confirmAppOwnedTermination
        requestProcessTermination = sendSIGTERM
        normalTerminationGracePolls = 4
        quiescenceSleep = { try await Task.sleep(for: $0) }
        removeJournalFile = {
            try SpikeStore.openExisting(at: storeURL).removeJournal()
        }
        syncStoreDirectory = {
            try PrivateDirectory.sync(at: storeURL)
        }
        activateApplication = { descriptor in
            try CodexAppLifecycle().activateIfRunning(descriptor)
        }
        launchApplication = { descriptor in
            try await CodexAppLifecycle().launch(descriptor)
        }
        verificationChildIsAlive = verificationChildProcessIsAlive
    }

    package init(
        storeURL: URL,
        activeAuthURL: URL,
        credentialStore: (any CredentialStoring)? = nil,
        processProvider: any ProcessSnapshotProviding,
        locateApp: @escaping @MainActor @Sendable () throws -> CodexAppDescriptor,
        runningApplicationPIDs: @escaping @MainActor @Sendable (CodexAppDescriptor) throws -> [Int32],
        requestApplicationTermination: @escaping @MainActor @Sendable (CodexAppDescriptor) throws -> [Int32] = {
            descriptor in
            try CodexAppLifecycle().requestNormalTermination(descriptor)
        },
        confirmAppOwnedTermination: @escaping @Sendable (Int) async -> Bool = { _ in false },
        requestProcessTermination: @escaping @Sendable (ProcessRecord) throws -> Void = sendSIGTERM,
        normalTerminationGracePolls: Int = 4,
        quiescenceSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        removeJournalFile: (@Sendable () throws -> DurableRemoval)? = nil,
        syncStoreDirectory: (@Sendable () throws -> Void)? = nil,
        activateApplication: @escaping @MainActor @Sendable (CodexAppDescriptor) throws -> Bool = {
            descriptor in
            try CodexAppLifecycle().activateIfRunning(descriptor)
        },
        launchApplication: @escaping @MainActor @Sendable (CodexAppDescriptor) async throws -> Int32 = {
            descriptor in
            try await CodexAppLifecycle().launch(descriptor)
        },
        verificationChildIsAlive: @escaping @Sendable (Int32) throws -> Bool = verificationChildProcessIsAlive
    ) {
        self.storeURL = storeURL
        self.credentialStore = credentialStore ?? FileCredentialStore(rootURL: storeURL)
        self.activeAuthURL = activeAuthURL
        self.processProvider = processProvider
        self.locateApp = locateApp
        self.runningApplicationPIDs = runningApplicationPIDs
        self.requestApplicationTermination = requestApplicationTermination
        self.confirmAppOwnedTermination = confirmAppOwnedTermination
        self.requestProcessTermination = requestProcessTermination
        self.normalTerminationGracePolls = min(max(normalTerminationGracePolls, 0), 119)
        self.quiescenceSleep = quiescenceSleep
        self.removeJournalFile = removeJournalFile ?? {
            try SpikeStore.openExisting(at: storeURL).removeJournal()
        }
        self.syncStoreDirectory = syncStoreDirectory ?? {
            try PrivateDirectory.sync(at: storeURL)
        }
        self.activateApplication = activateApplication
        self.launchApplication = launchApplication
        self.verificationChildIsAlive = verificationChildIsAlive
    }

    public func inspect() async throws -> InspectionReport {
        let descriptor: CodexAppDescriptor?
        let applicationStatus: ApplicationInspectionStatus
        do {
            descriptor = try await locateApp()
            applicationStatus = .ready
        } catch CodexAppLocatorFailure.notFound {
            descriptor = nil
            applicationStatus = .notFound
        } catch {
            descriptor = nil
            applicationStatus = .incompatible
        }

        let inventory = try await processInventory(for: descriptor)

        return InspectionReport(
            applicationStatus: applicationStatus,
            version: descriptor?.version,
            build: descriptor?.build,
            authStatus: inspectAuthStatus(),
            appOwnedProcessCount: count(.appOwnedBlocker, in: inventory),
            independentCodexProcessCount: count(.independentCodexBlocker, in: inventory),
            unclassifiedRelevantProcessCount: count(.unclassifiedRelevant, in: inventory)
        )
    }

    public func profiles() async throws -> [ProfileListItem] {
        guard let store = try openStoreIfPresent(),
              let registry = try store.loadRegistryIfPresent() else {
            return []
        }
        return registry.profiles.map { profile in
            ProfileListItem(
                id: profile.id,
                label: profile.label,
                email: profile.email,
                active: registry.activeProfileID == profile.id,
                needsRelogin: profile.needsRelogin
            )
        }
    }

    public func profileUsage(
        profileIDs requestedProfileIDs: Set<ProfileID>? = nil
    ) async throws -> ProfileUsageReport {
        guard !switchInProgress else {
            throw LocalCLIDataProviderFailure.switchAlreadyRunning
        }
        switchInProgress = true
        defer { switchInProgress = false }

        guard let store = try openStoreIfPresent(),
              let lock = try store.tryAcquireTransactionLock() else {
            throw LocalCLIDataProviderFailure.lockBusy
        }
        defer { lock.release() }

        let registry = try store.loadRegistry()
        guard !probeChildUnconfirmed,
              try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try store.loadProfileRemovalIfPresent() == nil,
              try !verificationWorkspaceExists() else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        let targetProfiles = registry.profiles.filter { profile in
            requestedProfileIDs?.contains(profile.id) ?? true
        }
        var usageByProfileID = [ProfileID: AppServerRateLimitsRead]()
        var failedProfileIDs = Set<ProfileID>()

        // ponytail: three accounts share one recovery-safe workspace; split only if measured refresh latency requires it.
        for (index, profile) in targetProfiles.enumerated() {
            try Task.checkCancellation()
            guard !profile.needsRelogin else {
                failedProfileIDs.insert(profile.id)
                continue
            }
            do {
                let descriptor = try await locateApp()
                let usage: AppServerAccountUsageRead
                if registry.activeProfileID == profile.id {
                    usage = try await readActiveProfileUsage(
                        expectedEmail: profile.email,
                        descriptor: descriptor
                    )
                } else {
                    guard let credential = try loadCredentialIfPresent(for: profile.id) else {
                        failedProfileIDs.insert(profile.id)
                        continue
                    }
                    usage = try await readProfileUsage(
                        credential,
                        expectedEmail: profile.email,
                        descriptor: descriptor
                    )
                }
                guard try await locateApp() == descriptor else {
                    throw LocalCLIDataProviderFailure.incompatibleApplication
                }
                guard try store.loadRegistry() == registry else {
                    throw LocalCLIDataProviderFailure.registryRoundTripFailed
                }
                try Task.checkCancellation()
                usageByProfileID[profile.id] = AppServerRateLimitsRead(
                    planType: usage.rateLimits.planType ?? planType(from: usage.account),
                    windows: usage.rateLimits.windows
                )
            } catch let failure as AppServerProbeFailure where failure.code == .cancelled {
                if failure.childDisposition == .unconfirmed {
                    probeChildUnconfirmed = true
                }
                throw failure
            } catch let failure as AppServerProbeFailure
                where failure.childDisposition == .unconfirmed
            {
                probeChildUnconfirmed = true
                failedProfileIDs.formUnion(targetProfiles[index...].map(\.id))
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedProfileIDs.insert(profile.id)
                let mustStop: Bool
                if usageFailureRequiresStop(error) {
                    mustStop = true
                } else {
                    do {
                        mustStop = try pathExists(credentialVerificationHomeURL)
                        if mustStop {
                            probeChildUnconfirmed = true
                        }
                    } catch {
                        probeChildUnconfirmed = true
                        mustStop = true
                    }
                }
                if mustStop {
                    if (error as? LocalCLIDataProviderFailure) == .verificationWorkspaceFailed {
                        probeChildUnconfirmed = true
                    }
                    failedProfileIDs.formUnion(targetProfiles[index...].map(\.id))
                    break
                }
            }
        }

        return ProfileUsageReport(
            usageByProfileID: usageByProfileID,
            failedProfileIDs: failedProfileIDs
        )
    }

    public func removeProfile(_ profileID: ProfileID) async throws -> ProfileListItem {
        guard !switchInProgress else {
            throw LocalCLIDataProviderFailure.switchAlreadyRunning
        }
        switchInProgress = true
        defer { switchInProgress = false }

        guard let store = try openStoreIfPresent(),
              let lock = try store.tryAcquireTransactionLock() else {
            throw LocalCLIDataProviderFailure.lockBusy
        }
        defer { lock.release() }

        let registry = try store.loadRegistry()
        guard let activeProfileID = registry.activeProfileID,
              let target = registry.profiles.first(where: { $0.id == profileID }) else {
            throw LocalCLIDataProviderFailure.targetProfileUnavailable
        }
        guard activeProfileID != profileID else {
            throw LocalCLIDataProviderFailure.activeProfileRemovalForbidden
        }
        guard
              try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try !verificationWorkspaceExists() else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }

        let removal = ProfileRemovalRecord(
            transactionID: UUID(),
            profileID: target.id,
            expectedActiveProfileID: activeProfileID
        )
        guard try store.createProfileRemovalIfAbsent(removal) != nil,
              try store.loadProfileRemovalIfPresent() == removal,
              try store.loadRegistry() == registry else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        try finishProfileRemoval(removal, in: store)
        return ProfileListItem(
            id: target.id,
            label: target.label,
            email: target.email,
            active: false,
            needsRelogin: target.needsRelogin
        )
    }

    public func captureProfile(label: String) async throws -> ProfileListItem {
        if let store = try openStoreIfPresent(),
           let registry = try store.loadRegistryIfPresent(),
           !registry.profiles.isEmpty {
            return try await registerAdditionalProfile(label: label, store: store)
        }
        routedFirstCaptureCount += 1
        defer { routedFirstCaptureCount -= 1 }
        let profile = try await ProfileCaptureCoordinator(driver: self).capture(label: label)
        let registry = try SpikeStore.openExisting(at: storeURL).loadRegistry()
        let descriptor = try await locateApp()
        _ = try await launchApplication(descriptor)
        return ProfileListItem(
            id: profile.id,
            label: profile.label,
            email: profile.email,
            active: registry.activeProfileID == profile.id,
            needsRelogin: profile.needsRelogin
        )
    }

    private func registerAdditionalProfile(label: String, store: SpikeStore) async throws -> ProfileListItem {
        try requireProfileLoginNotCancelled()
        guard !switchInProgress else {
            throw LocalCLIDataProviderFailure.switchAlreadyRunning
        }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.unicodeScalars.count <= 64,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileCaptureFailure.invalidLabel
        }
        profileLoginOperationActive = true
        profileLoginCancellationRequested = false
        switchInProgress = true
        defer {
            profileLoginOperationActive = false
            profileLoginCancellationRequested = false
            switchInProgress = false
        }

        guard let lock = try store.tryAcquireTransactionLock() else {
            throw LocalCLIDataProviderFailure.lockBusy
        }
        defer { lock.release() }

        let registry = try store.loadRegistry()
        guard !registry.profiles.isEmpty,
              registry.profiles.count < ProfileRegistry.maximumProfileCount else {
            throw LocalCLIDataProviderFailure.profileAlreadyExists
        }
        guard !registry.profiles.contains(where: { $0.label == label }) else {
            throw LocalCLIDataProviderFailure.profileAlreadyExists
        }
        guard let sourceID = registry.activeProfileID,
              let source = registry.profiles.first(where: { $0.id == sourceID }),
              !source.needsRelogin else {
            throw LocalCLIDataProviderFailure.activeProfileUnavailable
        }
        guard try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try store.loadProfileRemovalIfPresent() == nil,
              try !verificationWorkspaceExists() else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }

        let descriptor = try await locateApp()
        guard ApprovedResidentRule.codexCrashpad(for: descriptor) != nil else {
            throw LocalCLIDataProviderFailure.incompatibleApplication
        }
        let current = try readCurrentCredential()
        _ = try await validatedCredential(
            current.credential,
            expectedEmail: source.email,
            descriptor: descriptor
        )
        guard try await locateApp() == descriptor,
              try store.loadRegistry() == registry,
              try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try store.loadProfileRemovalIfPresent() == nil,
              try files.snapshot(at: activeAuthURL) == .exact(current.identity) else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        let sourceCredential: CredentialBlob
        if let stored = try loadCredentialIfPresent(for: source.id) {
            sourceCredential = stored
        } else {
            do {
                try credentialStore.saveCredential(current.credential, for: source.id)
            } catch {
                guard (try? credentialStore.loadCredential(for: source.id)) == current.credential else {
                    throw error
                }
            }
            sourceCredential = current.credential
        }
        guard try credentialStore.loadCredential(for: source.id) == sourceCredential else {
            throw LocalCLIDataProviderFailure.credentialRoundTripFailed
        }

        let login = try await runIsolatedLogin(
            descriptor: descriptor,
            disallowedEmails: Set(registry.profiles.map(\.email))
        )
        guard try await locateApp() == descriptor,
              try store.loadRegistry() == registry,
              try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try store.loadProfileRemovalIfPresent() == nil,
              try files.snapshot(at: activeAuthURL) == .exact(current.identity),
              try credentialStore.loadCredential(for: source.id) == sourceCredential else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        try requireProfileLoginNotCancelled()

        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let profileID = ProfileID(UUID())
        let pendingProfile = ProfileMetadata(
            id: profileID,
            label: label,
            email: login.email,
            planType: login.planType,
            needsRelogin: true,
            createdAt: now,
            updatedAt: now
        )
        let profile = ProfileMetadata(
            id: profileID,
            label: label,
            email: login.email,
            planType: login.planType,
            needsRelogin: false,
            createdAt: now,
            updatedAt: now
        )
        let pendingRegistry = try ProfileRegistry(
            activeProfileID: source.id,
            profiles: registry.profiles + [pendingProfile]
        )
        let updatedRegistry = try ProfileRegistry(
            activeProfileID: source.id,
            profiles: registry.profiles + [profile]
        )
        _ = try store.saveRegistry(pendingRegistry)
        guard try store.loadRegistry() == pendingRegistry else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
        do {
            try requireProfileLoginNotCancelled()
            do {
                try credentialStore.saveCredential(login.credential, for: profile.id)
            } catch {
                guard (try? credentialStore.loadCredential(for: profile.id)) == login.credential else {
                    throw error
                }
            }
            guard try credentialStore.loadCredential(for: profile.id) == login.credential else {
                throw LocalCLIDataProviderFailure.credentialRoundTripFailed
            }
            try requireProfileLoginNotCancelled()
            guard try await locateApp() == descriptor,
                  try store.loadRegistry() == pendingRegistry,
                  try journalIsDurablyAbsent(in: store),
                  try store.loadCaptureProfileIDIfPresent() == nil,
                  try store.loadProfileRemovalIfPresent() == nil,
                  try files.snapshot(at: activeAuthURL) == .exact(current.identity),
                  try credentialStore.loadCredential(for: source.id) == sourceCredential else {
                throw LocalCLIDataProviderFailure.activeAuthChanged
            }
            try requireProfileLoginNotCancelled()
            try saveRegistryConfirming(updatedRegistry, in: store)
        } catch {
            let durableRegistry: ProfileRegistry
            do {
                durableRegistry = try store.loadRegistry()
            } catch {
                throw LocalCLIDataProviderFailure.registryRoundTripFailed
            }
            if durableRegistry == pendingRegistry {
                do {
                    try rollbackPendingRegistration(
                        profileID: profile.id,
                        pendingRegistry: pendingRegistry,
                        originalRegistry: registry,
                        store: store
                    )
                } catch {
                    throw ProfileCaptureFailure.rollbackFailed
                }
                throw error
            }
            guard durableRegistry == updatedRegistry || durableRegistry == registry else {
                throw LocalCLIDataProviderFailure.registryRoundTripFailed
            }
            if durableRegistry == registry {
                throw error
            }
        }
        guard try files.snapshot(at: activeAuthURL) == .exact(current.identity),
              try store.loadRegistry() == updatedRegistry,
              try credentialStore.loadCredential(for: source.id) == sourceCredential,
              try credentialStore.loadCredential(for: profile.id) == login.credential else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
        return ProfileListItem(
            id: profile.id,
            label: profile.label,
            email: profile.email,
            active: false,
            needsRelogin: false
        )
    }

    public func switchProfile(target value: String) async throws -> ProfileListItem {
        try await switchProfile(target: value, onPhaseChange: { _ in })
    }

    public func reloginProfile(target value: String) async throws -> ProfileReloginOutcome {
        try requireProfileLoginNotCancelled()
        guard !switchInProgress else {
            throw LocalCLIDataProviderFailure.switchAlreadyRunning
        }
        profileLoginOperationActive = true
        profileLoginCancellationRequested = false
        switchInProgress = true
        defer {
            profileLoginOperationActive = false
            profileLoginCancellationRequested = false
            switchInProgress = false
        }

        guard let requestedUUID = UUID(uuidString: value),
              value == requestedUUID.uuidString,
              let store = try openStoreIfPresent() else {
            throw LocalCLIDataProviderFailure.targetProfileUnavailable
        }
        guard let lock = try store.tryAcquireTransactionLock() else {
            throw LocalCLIDataProviderFailure.lockBusy
        }
        defer { lock.release() }

        let registry = try store.loadRegistry()
        let requestedID = ProfileID(requestedUUID)
        guard let sourceID = registry.activeProfileID,
              let source = registry.profiles.first(where: { $0.id == sourceID }),
              !source.needsRelogin,
              let target = registry.profiles.first(where: { $0.id == requestedID }),
              target.id != source.id,
              target.needsRelogin else {
            throw LocalCLIDataProviderFailure.targetProfileUnavailable
        }
        guard try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try store.loadProfileRemovalIfPresent() == nil,
              try !verificationWorkspaceExists() else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }

        let descriptor = try await locateApp()
        guard ApprovedResidentRule.codexCrashpad(for: descriptor) != nil else {
            throw LocalCLIDataProviderFailure.incompatibleApplication
        }
        let sourceCredential = try credentialStore.loadCredential(for: source.id)
        let current = try readCurrentCredential()
        _ = try await validatedCredential(
            current.credential,
            expectedEmail: source.email,
            descriptor: descriptor
        )
        guard try await locateApp() == descriptor,
              try store.loadRegistry() == registry,
              try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try store.loadProfileRemovalIfPresent() == nil,
              try files.snapshot(at: activeAuthURL) == .exact(current.identity) else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }

        let login = try await runIsolatedLogin(
            descriptor: descriptor,
            expectedEmail: target.email
        )
        guard try store.loadRegistry() == registry,
              try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try store.loadProfileRemovalIfPresent() == nil,
              try files.snapshot(at: activeAuthURL) == .exact(current.identity),
              try credentialStore.loadCredential(for: source.id) == sourceCredential else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }

        let previousTargetCredential = try loadCredentialIfPresent(for: target.id)
        let updatedTarget = ProfileMetadata(
            id: target.id,
            label: target.label,
            email: target.email,
            planType: login.planType ?? target.planType,
            needsRelogin: false,
            createdAt: target.createdAt,
            updatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
        let updatedRegistry = try ProfileRegistry(
            activeProfileID: source.id,
            profiles: registry.profiles.map { $0.id == target.id ? updatedTarget : $0 }
        )
        do {
            try requireProfileLoginNotCancelled()
            do {
                try credentialStore.saveCredential(login.credential, for: target.id)
            } catch {
                guard (try? credentialStore.loadCredential(for: target.id)) == login.credential else {
                    throw error
                }
            }
            guard try credentialStore.loadCredential(for: target.id) == login.credential else {
                throw LocalCLIDataProviderFailure.credentialRoundTripFailed
            }
            try requireProfileLoginNotCancelled()
            guard try await locateApp() == descriptor,
                  try store.loadRegistry() == registry,
                  try journalIsDurablyAbsent(in: store),
                  try store.loadCaptureProfileIDIfPresent() == nil,
                  try store.loadProfileRemovalIfPresent() == nil,
                  try files.snapshot(at: activeAuthURL) == .exact(current.identity),
                  try credentialStore.loadCredential(for: source.id) == sourceCredential else {
                throw LocalCLIDataProviderFailure.activeAuthChanged
            }
            try requireProfileLoginNotCancelled()
            _ = try store.saveRegistry(updatedRegistry)
            guard try store.loadRegistry() == updatedRegistry else {
                throw LocalCLIDataProviderFailure.registryRoundTripFailed
            }
        } catch {
            if (try? store.loadRegistry()) == updatedRegistry {
                // The durable rename completed even though its final sync was uncertain.
            } else if (try? store.loadRegistry()) == registry {
                if let previousTargetCredential {
                    try credentialStore.saveCredential(previousTargetCredential, for: target.id)
                    guard try credentialStore.loadCredential(for: target.id) == previousTargetCredential else {
                        throw LocalCLIDataProviderFailure.credentialRoundTripFailed
                    }
                } else {
                    try credentialStore.removeCredential(for: target.id)
                }
                throw error
            } else {
                throw LocalCLIDataProviderFailure.registryRoundTripFailed
            }
        }

        guard try files.snapshot(at: activeAuthURL) == .exact(current.identity),
              try store.loadRegistry() == updatedRegistry,
              try credentialStore.loadCredential(for: target.id) == login.credential else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
        return .refreshed(
            ProfileListItem(
                id: updatedTarget.id,
                label: updatedTarget.label,
                email: updatedTarget.email,
                active: false,
                needsRelogin: false
            )
        )
    }

    public func cancelProfileLogin() async {
        guard profileLoginOperationActive else { return }
        profileLoginCancellationRequested = true
        await isolatedLoginSession?.cancel()
    }

    public func switchProfile(
        target value: String,
        onPhaseChange: @escaping @Sendable (SwitchPhase) async -> Void
    ) async throws -> ProfileListItem {
        guard !switchInProgress else {
            throw LocalCLIDataProviderFailure.switchAlreadyRunning
        }
        switchInProgress = true
        defer {
            switchInProgress = false
            resetSwitchTransactionState()
        }

        guard !value.isEmpty,
              value.unicodeScalars.count <= 64,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let store = try openStoreIfPresent() else {
            throw LocalCLIDataProviderFailure.targetProfileUnavailable
        }
        let registry = try store.loadRegistry()
        guard let sourceID = registry.activeProfileID,
              let source = registry.profiles.first(where: { $0.id == sourceID }) else {
            throw LocalCLIDataProviderFailure.activeProfileUnavailable
        }
        let requestedID = UUID(uuidString: value).map { ProfileID($0) }
        let matches = registry.profiles.filter { profile in
            profile.label == value || profile.id == requestedID
        }
        guard matches.count == 1, let target = matches.first else {
            throw LocalCLIDataProviderFailure.targetProfileUnavailable
        }
        guard !target.needsRelogin else {
            throw LocalCLIDataProviderFailure.targetNeedsRelogin
        }

        let descriptor = try await locateApp()
        guard ApprovedResidentRule.codexCrashpad(for: descriptor) != nil else {
            throw LocalCLIDataProviderFailure.incompatibleApplication
        }
        let applicationWasRunning = !(try await runningApplicationPIDs(descriptor)).isEmpty
        switchDescriptor = descriptor
        switchExpectedRegistry = registry

        _ = try await SwitchCoordinator(
            driver: self,
            onPhaseChange: onPhaseChange
        ).switchAccount(
            SwitchRequest(
                source: source,
                target: target,
                applicationWasRunning: applicationWasRunning
            )
        )
        let switchedRegistry = try store.loadRegistry()
        guard switchedRegistry.activeProfileID == target.id,
              switchedRegistry.profiles.contains(where: { $0 == target }) else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
        return ProfileListItem(
            id: target.id,
            label: target.label,
            email: target.email,
            active: true,
            needsRelogin: target.needsRelogin
        )
    }

#if SPIKE_FAULT_INJECTION
    public func testPostLaunchRollback(target value: String) async throws -> ProfileListItem {
        guard !switchInProgress, !injectPostLaunchVerificationFailure else {
            throw LocalCLIDataProviderFailure.switchAlreadyRunning
        }
        guard let store = try openStoreIfPresent() else {
            throw LocalCLIDataProviderFailure.targetProfileUnavailable
        }
        let originalRegistry = try store.loadRegistry()
        guard let sourceID = originalRegistry.activeProfileID,
              let source = originalRegistry.profiles.first(where: { $0.id == sourceID }) else {
            throw LocalCLIDataProviderFailure.activeProfileUnavailable
        }

        injectPostLaunchVerificationFailure = true
        postLaunchVerificationFailureInjected = false
        defer {
            injectPostLaunchVerificationFailure = false
            postLaunchVerificationFailureInjected = false
        }

        do {
            _ = try await switchProfile(target: value)
            throw PostLaunchRollbackTestFailure.injectionNotTriggered
        } catch let failure as SwitchCoordinatorFailure
            where failure == .operationFailed && postLaunchVerificationFailureInjected
        {
            do {
                let restoredRegistry = try store.loadRegistry()
                guard restoredRegistry == originalRegistry,
                      try store.loadJournalIfPresent() == nil,
                      try readCurrentCredential().credential == credentialStore.loadCredential(for: source.id),
                      !(try await runningApplicationPIDs(locateApp())).isEmpty else {
                    throw PostLaunchRollbackTestFailure.finalStateMismatch
                }
                return ProfileListItem(
                    id: source.id,
                    label: source.label,
                    email: source.email,
                    active: true,
                    needsRelogin: source.needsRelogin
                )
            } catch {
                throw PostLaunchRollbackTestFailure.finalStateMismatch
            }
        }
    }
#endif

    public func restoreRecoveryProfile(target value: String) async throws -> RecoveryRestoreOutcome {
        try await restoreRecoveryProfile(target: value, expectedTransactionID: nil)
    }

    public func restoreRecoveryProfile(
        target value: String,
        expectedTransactionID: String?
    ) async throws -> RecoveryRestoreOutcome {
        guard !switchInProgress else {
            throw LocalCLIDataProviderFailure.switchAlreadyRunning
        }
        switchInProgress = true
        defer {
            switchInProgress = false
            resetSwitchTransactionState()
        }

        guard !value.isEmpty,
              value.unicodeScalars.count <= 64,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let store = try openStoreIfPresent() else {
            throw LocalCLIDataProviderFailure.manualRecoveryUnavailable
        }
        let registry = try store.loadRegistry()
        let captureProfileID = try store.loadCaptureProfileIDIfPresent()
        let journalFinalizationEvidence = try store.loadJournalFinalizationEvidenceIfPresent()
        guard try store.loadProfileRemovalIfPresent() == nil,
              let journal = try store.loadJournalIfPresent(),
              journal.phase == .rollbackFailed,
              expectedTransactionID == nil || journal.transactionID.uuidString == expectedTransactionID,
              journalFinalizationEvidence == nil,
              journal.previousProfileID != journal.targetProfileID,
              captureProfileID == nil || captureProfileID == journal.targetProfileID,
              registry.activeProfileID == journal.previousProfileID
                || registry.activeProfileID == journal.targetProfileID else {
            throw LocalCLIDataProviderFailure.manualRecoveryUnavailable
        }
        let profileIDs = Set(registry.profiles.map(\.id))
        guard profileIDs.contains(journal.previousProfileID) else {
            throw LocalCLIDataProviderFailure.manualRecoveryUnavailable
        }
        if captureProfileID != nil {
            let targetIsRegistered = profileIDs.contains(journal.targetProfileID)
            guard targetIsRegistered
                ? registry.profiles.last?.id == journal.targetProfileID
                : registry.profiles.count < ProfileRegistry.maximumProfileCount else {
                throw LocalCLIDataProviderFailure.manualRecoveryUnavailable
            }
        } else if !profileIDs.contains(journal.targetProfileID) {
            throw LocalCLIDataProviderFailure.manualRecoveryUnavailable
        }
        let requestedID = UUID(uuidString: value).map { ProfileID($0) }
        let matches = registry.profiles.filter { $0.label == value || $0.id == requestedID }
        guard matches.count == 1,
              let profile = matches.first,
              profile.id == journal.previousProfileID,
              !profile.needsRelogin else {
            throw LocalCLIDataProviderFailure.manualRecoveryUnavailable
        }

        let descriptor = try await locateApp()
        guard ApprovedResidentRule.codexCrashpad(for: descriptor) != nil else {
            throw LocalCLIDataProviderFailure.incompatibleApplication
        }
        switchDescriptor = descriptor
        switchExpectedRegistry = registry
        guard try await beginExclusiveTransaction() else {
            throw LocalCLIDataProviderFailure.lockBusy
        }
        guard try await locateApp() == descriptor,
              try store.loadRegistry() == registry,
              try store.loadProfileRemovalIfPresent() == nil,
              try store.loadJournalIfPresent() == journal,
              try store.loadJournalFinalizationEvidenceIfPresent() == journalFinalizationEvidence,
              try store.loadCaptureProfileIDIfPresent() == captureProfileID else {
            throw LocalCLIDataProviderFailure.manualRecoveryUnavailable
        }
        if registry.profiles.contains(where: { $0.id == journal.targetProfileID }) {
            _ = try credentialStore.loadCredential(for: journal.targetProfileID)
        }

        try await requestNormalQuit()
        try await waitForQuiescence()
        try await revalidateCredentialMutationGate()
        try quarantineVerificationHomes(transactionID: journal.transactionID)
        guard try !verificationWorkspaceExists() else {
            throw LocalCLIDataProviderFailure.manualRecoveryUnavailable
        }
        try await revalidateCredentialMutationGate()
        switchActiveAuthDestination = try files.snapshot(at: activeAuthURL)
        try await restorePreviousCredential(profile.id)
        try await verifyPrevious(expectedEmail: profile.email)
        try await revalidateCredentialMutationGate()
        try await commitActiveProfile(profile.id)
        if !registry.profiles.contains(where: { $0.id == journal.targetProfileID }) {
            try credentialStore.removeCredential(for: journal.targetProfileID)
        }
        if captureProfileID != nil {
            _ = try store.removeCaptureProfileID()
        }
        let restoredProfile = ProfileListItem(
            id: profile.id,
            label: profile.label,
            email: profile.email,
            active: true,
            needsRelogin: profile.needsRelogin
        )
        do {
            try await removeJournalDurably()
        } catch where mutationOutcomeIsUncertain(error) {
            return .journalFinalizationUncertain
        }
        do {
            try await launchPrevious()
            return .restoredAndLaunched(restoredProfile)
        } catch {
            return .restoredButLaunchUnconfirmed(restoredProfile)
        }
    }

    public func syncActiveProfile() async throws -> ProfileListItem {
        guard captureLock == nil else {
            throw LocalCLIDataProviderFailure.captureAlreadyRunning
        }
        guard let store = try openStoreIfPresent() else {
            throw LocalCLIDataProviderFailure.activeProfileUnavailable
        }
        guard let lock = try store.tryAcquireTransactionLock() else {
            throw LocalCLIDataProviderFailure.lockBusy
        }
        defer {
            lock.release()
            probeChildUnconfirmed = false
        }

        guard try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try !verificationWorkspaceExists() else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        let registry = try store.loadRegistry()
        guard let activeProfileID = registry.activeProfileID,
              let profile = registry.profiles.first(where: { $0.id == activeProfileID }) else {
            throw LocalCLIDataProviderFailure.activeProfileUnavailable
        }
        let previousCredential = try credentialStore.loadCredential(for: profile.id)

        let descriptor = try await locateApp()
        guard ApprovedResidentRule.codexCrashpad(for: descriptor) != nil else {
            throw LocalCLIDataProviderFailure.incompatibleApplication
        }
        try await requireMutationGate(for: descriptor)

        let current = try readCurrentCredential()
        _ = try await validatedCredential(
            current.credential,
            expectedEmail: profile.email,
            descriptor: descriptor
        )
        guard try store.loadRegistry() == registry,
              try store.loadJournalIfPresent() == nil,
              try store.loadCaptureProfileIDIfPresent() == nil else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        try await requireMutationGate(for: descriptor)
        guard try files.snapshot(at: activeAuthURL) == .exact(current.identity) else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }

        let backupProfileID = try store.createCaptureProfileID()
        var storedCredentialMayHaveChanged = false
        do {
            try credentialStore.saveCredential(previousCredential, for: backupProfileID)
            guard try credentialStore.loadCredential(for: backupProfileID) == previousCredential else {
                throw LocalCLIDataProviderFailure.credentialRoundTripFailed
            }
            guard try store.loadCaptureProfileIDIfPresent() == backupProfileID,
                  try store.loadJournalIfPresent() == nil,
                  try store.loadRegistry() == registry else {
                throw LocalCLIDataProviderFailure.pendingRecovery
            }
            guard try files.snapshot(at: activeAuthURL) == .exact(current.identity) else {
                throw LocalCLIDataProviderFailure.activeAuthChanged
            }

            storedCredentialMayHaveChanged = true
            try credentialStore.saveCredential(current.credential, for: profile.id)
            guard try credentialStore.loadCredential(for: profile.id) == current.credential else {
                throw LocalCLIDataProviderFailure.credentialRoundTripFailed
            }
            try await requireMutationGate(for: descriptor)
            guard try files.snapshot(at: activeAuthURL) == .exact(current.identity) else {
                throw LocalCLIDataProviderFailure.activeAuthChanged
            }
            guard try store.loadRegistry() == registry,
                  try store.loadJournalIfPresent() == nil,
                  try store.loadCaptureProfileIDIfPresent() == backupProfileID else {
                throw LocalCLIDataProviderFailure.registryRoundTripFailed
            }
            try removeCaptureArtifacts(store: store, profileID: backupProfileID)
        } catch {
            do {
                if storedCredentialMayHaveChanged {
                    try credentialStore.saveCredential(previousCredential, for: profile.id)
                    guard try credentialStore.loadCredential(for: profile.id) == previousCredential else {
                        throw LocalCLIDataProviderFailure.rollbackFailed
                    }
                }
                guard try store.loadCaptureProfileIDIfPresent() == backupProfileID else {
                    throw LocalCLIDataProviderFailure.rollbackFailed
                }
                try removeCaptureArtifacts(store: store, profileID: backupProfileID)
            } catch {
                throw ProfileCaptureFailure.rollbackFailed
            }
            throw error
        }
        return ProfileListItem(
            id: profile.id,
            label: profile.label,
            email: profile.email,
            active: true,
            needsRelogin: profile.needsRelogin
        )
    }

    public func recoverPendingTransaction() async throws -> RecoveryOutcome {
        _ = try recoverPendingProfileRemoval()
        return try await performPendingRecovery(
            expectedTransactionID: nil,
            requestApplicationQuiescence: false
        )
    }

    public func retryPendingRecovery(expectedTransactionID: String) async throws -> RecoveryOutcome {
        guard let transactionID = UUID(uuidString: expectedTransactionID) else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        return try await performPendingRecovery(
            expectedTransactionID: transactionID,
            requestApplicationQuiescence: true
        )
    }

    private func performPendingRecovery(
        expectedTransactionID: UUID?,
        requestApplicationQuiescence: Bool
    ) async throws -> RecoveryOutcome {
        guard !switchInProgress else {
            throw LocalCLIDataProviderFailure.switchAlreadyRunning
        }
        guard let store = try openStoreIfPresent() else {
            return .none
        }
        switchInProgress = true
        defer {
            switchInProgress = false
            resetSwitchTransactionState()
        }
        recoveryExpectedTransactionID = expectedTransactionID
        recoveryRequestsApplicationQuiescence = requestApplicationQuiescence
        let mode = requestApplicationQuiescence ? "manual" : "automatic"
        recoveryLogger.notice("event=recovery_started mode=\(mode, privacy: .public)")
        do {
            try removeAbandonedVerificationWorkspacesIfSafe(in: store)
            let outcome = try await RecoveryCoordinator(executor: self).recover(relaunchPrevious: false)
            switch outcome {
            case .none:
                recoveryLogger.notice("event=recovery_finished outcome=none")
            case .completed:
                recoveryLogger.notice("event=recovery_finished outcome=completed")
            case .stopped(.helperChildAlive), .stopped(.processBlockerPresent):
                recoveryLogger.error("event=recovery_finished outcome=stopped reason=process_blocked")
            case .stopped(.activeCredentialUnverified):
                recoveryLogger.error(
                    "event=recovery_finished outcome=stopped reason=active_credential_unverified"
                )
            case .stopped:
                recoveryLogger.error("event=recovery_finished outcome=stopped reason=recovery_state_invalid")
            }
            return outcome
        } catch {
            recoveryLogger.error("event=recovery_failed code=coordinator_failure")
            throw error
        }
    }

    public func recoveryStatus() async throws -> RecoveryCLIStatus {
        do {
            guard let store = try openStoreIfPresent() else {
                return .none
            }
            guard let lock = try store.tryAcquireTransactionLock() else {
                return .blocked
            }
            defer { lock.release() }
            if try journalIsDurablyAbsent(in: store) {
                guard try store.loadCaptureProfileIDIfPresent() == nil,
                      try !verificationWorkspaceExists() else {
                    return .blocked
                }
                return .none
            }
            guard let journal = try store.loadJournalIfPresent(),
                  try store.loadJournalFinalizationEvidenceIfPresent() == nil else {
                return .blocked
            }
            return .pending(
                transactionID: journal.transactionID.uuidString,
                phase: journal.phase,
                previousProfileID: journal.previousProfileID
            )
        } catch {
            return .blocked
        }
    }

    public func prepareCapture() async throws -> ProfileID {
        guard captureLock == nil else {
            throw LocalCLIDataProviderFailure.captureAlreadyRunning
        }
        let store = try SpikeStore.create(at: storeURL)
        guard let lock = try store.tryAcquireTransactionLock() else {
            throw LocalCLIDataProviderFailure.lockBusy
        }
        captureStore = store
        captureLock = lock

        do {
            guard try journalIsDurablyAbsent(in: store),
                  try !verificationWorkspaceExists() else {
                throw LocalCLIDataProviderFailure.pendingRecovery
            }
            let registry = try store.loadRegistryIfPresent()
            guard routedFirstCaptureCount == 0 || registry?.profiles.isEmpty != false else {
                throw LocalCLIDataProviderFailure.captureAlreadyRunning
            }
            guard (registry?.profiles.count ?? 0) < ProfileRegistry.maximumProfileCount else {
                throw LocalCLIDataProviderFailure.profileAlreadyExists
            }
            guard try store.loadCaptureProfileIDIfPresent() == nil else {
                throw LocalCLIDataProviderFailure.pendingRecovery
            }
            let descriptor = try await locateApp()
            guard ApprovedResidentRule.codexCrashpad(for: descriptor) != nil else {
                throw LocalCLIDataProviderFailure.incompatibleApplication
            }
            let terminationCandidates: [ProcessIdentity: ProcessRecord]
            do {
                terminationCandidates = try appOwnedTerminationCandidates(
                    in: try await processInventory(for: descriptor)
                )
            } catch ApplicationQuiescenceFailure.processBlocked {
                throw LocalCLIDataProviderFailure.processBlocked
            }
            if !terminationCandidates.isEmpty {
                _ = try await requestApplicationTermination(descriptor)
            }
            do {
                try await waitForAppQuiescence(
                    descriptor: descriptor,
                    terminationCandidates: terminationCandidates
                )
            } catch ApplicationQuiescenceFailure.processBlocked {
                throw LocalCLIDataProviderFailure.processBlocked
            }
            let previous: ProfileMetadata?
            if let registry {
                guard let activeProfileID = registry.activeProfileID,
                      let activeProfile = registry.profiles.first(where: { $0.id == activeProfileID }) else {
                    throw LocalCLIDataProviderFailure.invalidCaptureState
                }
                previous = activeProfile
                _ = try credentialStore.loadCredential(for: activeProfile.id)
            } else {
                previous = nil
            }
            try await requireMutationGate(for: descriptor)
            let original = try readCurrentCredential()
            captureDescriptor = descriptor
            originalCredential = original.credential
            originalAuthIdentity = original.identity
            captureOriginalRegistry = registry
            let profileID = try store.createCaptureProfileID()
            captureProfileID = profileID
            try credentialStore.saveCredential(original.credential, for: profileID)
            guard try credentialStore.loadCredential(for: profileID) == original.credential else {
                throw LocalCLIDataProviderFailure.credentialRoundTripFailed
            }
            if let previous {
                let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
                let journal = SwitchJournalRecord(
                    transactionID: UUID(),
                    phase: .validatingTarget,
                    previousProfileID: previous.id,
                    targetProfileID: profileID,
                    startedAt: now,
                    updatedAt: now
                )
                guard try store.createJournalIfAbsent(journal) != nil else {
                    throw LocalCLIDataProviderFailure.pendingRecovery
                }
            }
            return profileID
        } catch {
            if !mutationOutcomeIsUncertain(error), let captureProfileID {
                try? removeCaptureArtifacts(store: store, profileID: captureProfileID)
            }
            resetCaptureState()
            throw error
        }
    }

    public func probeAccount(refreshToken: Bool) async throws -> AppServerAccountRead {
        guard let descriptor = captureDescriptor else {
            throw LocalCLIDataProviderFailure.invalidCaptureState
        }
        try await requireMutationGate(for: descriptor)
        let configuration = AppServerProbeConfiguration(
            executableURL: descriptor.bundledCodexURL,
            codexHomeURL: activeAuthURL.deletingLastPathComponent(),
            homePolicy: .ownerControlled,
            refreshToken: refreshToken,
            timeouts: AppServerProbeTimeouts(
                initializeResponse: .seconds(10),
                accountResponse: .seconds(30),
                normalExit: .seconds(5),
                terminateExit: .seconds(2)
            )
        )
        do {
            let account = try await AppServerProbeSession(configuration: configuration).run()
            if !refreshToken,
               let registry = captureOriginalRegistry,
               case let .chatGPT(email?, _, _) = account,
               registry.profiles.contains(where: { $0.email == email }) {
                throw ProfileCaptureFailure.accountAlreadyRegistered
            }
            return account
        } catch let failure as AppServerProbeFailure {
            if failure.childDisposition == .unconfirmed {
                probeChildUnconfirmed = true
            }
            throw failure
        }
    }

    public func readActiveCredential() async throws -> CredentialBlob {
        let result = try readCurrentCredential()
        capturedAuthIdentity = result.identity
        return result.credential
    }

    public func verifyCapturedCredential(
        _ credential: CredentialBlob,
        expectedEmail: String
    ) async throws {
        guard let descriptor = captureDescriptor else {
            throw LocalCLIDataProviderFailure.invalidCaptureState
        }
        let homeURL = captureVerificationHomeURL
        try createVerificationHome(homeURL)
        let authURL = homeURL.appendingPathComponent("auth.json", isDirectory: false)
        do {
            _ = try files.replace(
                contents: SensitiveBytes(CredentialBlob.persistenceData(for: credential)),
                at: authURL,
                expecting: .absent
            )
            let account = try await probeAccount(
                descriptor: descriptor,
                codexHomeURL: homeURL
            )
            do {
                try AccountIdentityValidator.validate(expectedEmail: expectedEmail, account: account)
            } catch {
                throw ProfileCaptureFailure.identityMismatch
            }
            try removeVerificationHome(homeURL)
        } catch let failure as AppServerProbeFailure where failure.childDisposition == .unconfirmed {
            probeChildUnconfirmed = true
            throw failure
        } catch {
            try removeVerificationHome(homeURL)
            throw error
        }
    }

    public func revalidateMutationGate() async throws {
        guard let descriptor = captureDescriptor else {
            throw LocalCLIDataProviderFailure.invalidCaptureState
        }
        try await requireMutationGate(for: descriptor)
        try requireCapturedAuthUnchanged()
    }

    public func commit(profile: ProfileMetadata, credential: CredentialBlob) async throws {
        do {
            try await performCommit(profile: profile, credential: credential)
        } catch {
            if mutationOutcomeIsUncertain(error) {
                captureMutationUncertain = true
            }
            throw error
        }
    }

    private func performCommit(profile: ProfileMetadata, credential: CredentialBlob) async throws {
        guard let store = captureStore,
              let captureProfileID,
              captureProfileID == profile.id,
              try store.loadCaptureProfileIDIfPresent() == profile.id else {
            throw LocalCLIDataProviderFailure.invalidCaptureState
        }
        try requireCapturedAuthUnchanged()
        try credentialStore.saveCredential(credential, for: profile.id)
        guard try credentialStore.loadCredential(for: profile.id) == credential else {
            throw LocalCLIDataProviderFailure.credentialRoundTripFailed
        }
        try requireCapturedAuthUnchanged()
        let registry: ProfileRegistry
        if let original = captureOriginalRegistry {
            guard try store.loadRegistry() == original,
                  let journal = try store.loadJournalIfPresent(),
                  journal.phase == .validatingTarget,
                  journal.previousProfileID == original.activeProfileID,
                  journal.targetProfileID == profile.id,
                  let previousProfileID = original.activeProfileID,
                  original.profiles.contains(where: { $0.id == previousProfileID }) else {
                throw LocalCLIDataProviderFailure.invalidCaptureState
            }
            try requireCapturedAuthUnchanged()
            registry = try ProfileRegistry(
                activeProfileID: profile.id,
                profiles: original.profiles + [profile]
            )
            let targetValidated = SwitchJournalRecord(
                transactionID: journal.transactionID,
                phase: .targetValidated,
                previousProfileID: journal.previousProfileID,
                targetProfileID: journal.targetProfileID,
                startedAt: journal.startedAt,
                updatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            )
            _ = try store.updateJournal(targetValidated)
            _ = try store.saveRegistry(registry)
            guard try store.loadRegistry() == registry else {
                throw LocalCLIDataProviderFailure.registryRoundTripFailed
            }
            try requireCapturedAuthUnchanged()
            _ = try markTargetVerified(targetValidated, in: store)
            try requireCapturedAuthUnchanged()
            _ = try store.removeCaptureProfileID()
            guard try store.loadCaptureProfileIDIfPresent() == nil,
                  let capturedAuthIdentity else {
                throw LocalCLIDataProviderFailure.invalidCaptureState
            }
            try finalizeJournal(
                in: store,
                expectedActiveProfileID: profile.id,
                expectedActiveAuthIdentity: capturedAuthIdentity
            )
            return
        } else {
            guard try store.loadRegistryIfPresent() == nil else {
                throw LocalCLIDataProviderFailure.profileAlreadyExists
            }
            registry = try ProfileRegistry(activeProfileID: profile.id, profiles: [profile])
        }
        _ = try store.saveRegistry(registry)
        guard try store.loadRegistry() == registry else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
        try requireCapturedAuthUnchanged()
        _ = try store.removeCaptureProfileID()
    }

    public func finishCapture() async {
        resetCaptureState()
    }

    public func abortCapture() async throws {
        defer { resetCaptureState() }
        guard !probeChildUnconfirmed,
              !captureMutationUncertain,
              let store = captureStore,
              let captureProfileID,
              let originalCredential,
              let originalAuthIdentity else {
            throw LocalCLIDataProviderFailure.rollbackUnavailable
        }
        if let originalRegistry = captureOriginalRegistry {
            if try store.loadJournalIfPresent()?.phase == .targetVerified {
                return
            }
            try await restoreOriginalAfterCapture(
                store: store,
                captureProfileID: captureProfileID,
                originalRegistry: originalRegistry
            )
            return
        }
        let current = try files.snapshot(at: activeAuthURL)
        if current != .exact(originalAuthIdentity) {
            guard let descriptor = captureDescriptor else {
                throw LocalCLIDataProviderFailure.rollbackUnavailable
            }
            try await requireMutationGate(for: descriptor)
            _ = try files.replace(
                contents: SensitiveBytes(CredentialBlob.persistenceData(for: originalCredential)),
                at: activeAuthURL,
                expecting: current
            )
        }
        guard try readCurrentCredential().credential == originalCredential else {
            throw LocalCLIDataProviderFailure.rollbackFailed
        }
        guard try store.loadRegistryIfPresent() == nil else {
            throw LocalCLIDataProviderFailure.rollbackUnavailable
        }
        try removeCaptureArtifacts(store: store, profileID: captureProfileID)
    }

}

public enum LocalCLIDataProviderFailure: Error, Equatable, Sendable {
    case captureAlreadyRunning
    case lockBusy
    case pendingRecovery
    case profileAlreadyExists
    case activeProfileUnavailable
    case activeProfileRemovalForbidden
    case targetProfileUnavailable
    case targetNeedsRelogin
    case switchAlreadyRunning
    case incompatibleApplication
    case processBlocked
    case invalidCaptureState
    case invalidSwitchState
    case credentialRoundTripFailed
    case registryRoundTripFailed
    case processSnapshotUnstable
    case activeAuthChanged
    case verificationWorkspaceFailed
    case rollbackUnavailable
    case rollbackFailed
    case manualRecoveryUnavailable
}

extension LocalCLIDataProvider: SwitchTransactionDriving {
    public func beginExclusiveTransaction() async throws -> Bool {
        guard switchLock == nil,
              captureLock == nil,
              switchDescriptor != nil,
              switchExpectedRegistry != nil,
              let store = try openStoreIfPresent() else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        guard let lock = try store.tryAcquireTransactionLock() else {
            return false
        }
        switchStore = store
        switchLock = lock
        return true
    }

    public func endExclusiveTransaction() async {
        resetSwitchTransactionState()
    }

    public func pendingRecoveryExists() async throws -> Bool {
        let context = try requireSwitchContext()
        guard try context.store.loadRegistry() == context.registry else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        return try !journalIsDurablyAbsent(in: context.store)
            || context.store.loadCaptureProfileIDIfPresent() != nil
            || verificationWorkspaceExists()
    }

    public func createJournalIfAbsent(_ record: SwitchJournalRecord) async throws -> Bool {
        try requireSwitchContext().store.createJournalIfAbsent(record) != nil
    }

    public func persistJournal(_ record: SwitchJournalRecord) async throws {
        let context = try requireSwitchContext()
        guard try context.store.loadRegistry() == context.registry else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        if let current = try context.store.loadJournalIfPresent(),
           current.phase == .rollbackFailed,
           record.phase == .rollbackStarted {
            guard current.transactionID == record.transactionID,
                  current.previousProfileID == record.previousProfileID,
                  current.targetProfileID == record.targetProfileID,
                  try context.store.loadCaptureProfileIDIfPresent() == current.targetProfileID,
                  context.registry.profiles.last?.id == current.targetProfileID else {
                throw LocalCLIDataProviderFailure.invalidSwitchState
            }
        }
        _ = try context.store.updateJournal(record)
        guard try context.store.loadRegistry() == context.registry else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
    }

    public func validatePreparation(
        source: ProfileMetadata,
        target: ProfileMetadata
    ) async throws {
        let context = try requireSwitchContext()
        guard try await locateApp() == context.descriptor,
              ApprovedResidentRule.codexCrashpad(for: context.descriptor) != nil,
              try context.store.loadRegistry() == context.registry,
              context.registry.activeProfileID == source.id,
              context.registry.profiles.contains(source),
              context.registry.profiles.contains(target),
              !target.needsRelogin else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        let activeAuthDestination = try files.snapshot(at: activeAuthURL)
        guard case .exact = activeAuthDestination else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        switchActiveAuthDestination = activeAuthDestination
        _ = try credentialStore.loadCredential(for: source.id)
        _ = try credentialStore.loadCredential(for: target.id)
    }

    public func requestNormalQuit() async throws {
        let descriptor = try requireSwitchContext().descriptor
        do {
            switchAppOwnedTerminationCandidates = try appOwnedTerminationCandidates(
                in: try await switchProcessInventory(for: descriptor)
            )
        } catch ApplicationQuiescenceFailure.processBlocked {
            throw SwitchCoordinatorFailure.processBlocked
        }
        _ = try await requestApplicationTermination(descriptor)
    }

    public func waitForQuiescence() async throws {
        let descriptor = try requireSwitchContext().descriptor
        do {
            try await waitForAppQuiescence(
                descriptor: descriptor,
                terminationCandidates: switchAppOwnedTerminationCandidates
            )
        } catch ApplicationQuiescenceFailure.processBlocked {
            throw SwitchCoordinatorFailure.processBlocked
        }
    }

    private func waitForAppQuiescence(
        descriptor: CodexAppDescriptor,
        terminationCandidates: [ProcessIdentity: ProcessRecord]
    ) async throws {
        var sentSIGTERM = false
        for poll in 0..<120 {
            let inventory: ProcessInventory
            do {
                inventory = try await processInventory(for: descriptor)
            } catch LocalCLIDataProviderFailure.processSnapshotUnstable {
                try await quiescenceSleep(.milliseconds(250))
                continue
            }
            let newlyDiscovered = inventory.processes.filter {
                $0.disposition.blocksAuthMutation
                    && terminationCandidates[$0.record.identity] == nil
            }
            guard newlyDiscovered.allSatisfy({ $0.disposition == .appOwnedBlocker }) else {
                throw ApplicationQuiescenceFailure.processBlocked
            }
            if !newlyDiscovered.isEmpty {
                try await quiescenceSleep(.milliseconds(250))
                continue
            }
            let survivors = try capturedAppOwnedSurvivors(
                in: inventory,
                terminationCandidates: terminationCandidates
            )
            if survivors.isEmpty {
                return
            }
            if poll >= normalTerminationGracePolls, !sentSIGTERM {
                guard await confirmAppOwnedTermination(survivors.count) else {
                    throw ApplicationQuiescenceFailure.processBlocked
                }
                try terminateCapturedAppOwnedProcesses(survivors)
                sentSIGTERM = true
            }
            try await quiescenceSleep(.milliseconds(250))
        }
        throw ApplicationQuiescenceFailure.processBlocked
    }

    public func revalidateCredentialMutationGate() async throws {
        let context = try requireSwitchContext()
        guard try context.store.loadRegistry() == context.registry else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        do {
            try await requireMutationGate(for: context.descriptor)
        } catch let failure as LocalCLIDataProviderFailure
            where failure == .processBlocked || failure == .processSnapshotUnstable
        {
            throw SwitchCoordinatorFailure.processBlocked
        }
        guard try context.store.loadRegistry() == context.registry else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
    }

    public func verifyActiveSource(expectedEmail: String) async throws {
        switchActiveAuthDestination = .exact(
            try await verifyActiveCredential(
                expectedEmail: expectedEmail,
                descriptor: requireSwitchContext().descriptor
            )
        )
    }

    public func refreshAndSaveCurrent(profile: ProfileMetadata) async throws {
        try await refreshAndSaveCurrent(
            profile: profile,
            expectedRegistryActiveProfileID: profile.id
        )
    }

    func refreshAndSaveCurrent(
        profile: ProfileMetadata,
        expectedRegistryActiveProfileID: ProfileID
    ) async throws {
        let context = try requireSwitchContext()
        guard context.registry.activeProfileID == expectedRegistryActiveProfileID,
              context.registry.profiles.contains(profile),
              let expectedDestination = switchActiveAuthDestination,
              try files.snapshot(at: activeAuthURL) == expectedDestination else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }

        do {
            let account = try await probeAccount(
                descriptor: context.descriptor,
                codexHomeURL: activeAuthURL.deletingLastPathComponent(),
                homePolicy: .ownerControlled,
                refreshToken: true
            )
            let refreshed = try readCurrentCredential()
            switchActiveAuthDestination = .exact(refreshed.identity)
            do {
                try AccountIdentityValidator.validate(expectedEmail: profile.email, account: account)
            } catch {
                throw ProfileCaptureFailure.identityMismatch
            }
            try await revalidateCredentialMutationGate()
            try credentialStore.saveCredential(refreshed.credential, for: profile.id)
            guard try credentialStore.loadCredential(for: profile.id) == refreshed.credential,
                  try files.snapshot(at: activeAuthURL) == .exact(refreshed.identity) else {
                throw LocalCLIDataProviderFailure.credentialRoundTripFailed
            }
        } catch {
            if !appServerExitIsUnconfirmed(error),
               let snapshot = try? files.snapshot(at: activeAuthURL) {
                switchActiveAuthDestination = snapshot
            }
            throw error
        }
    }

    public func validateAndSaveTarget(profile: ProfileMetadata) async throws {
        try await TargetCredentialValidator(driver: self).validate(profile: profile)
    }

    public func markTargetNeedsRelogin(_ profileID: ProfileID) async throws {
        let context = try requireSwitchContext()
        try await revalidateCredentialMutationGate()
        let current = try context.store.loadRegistry()
        let journal = try context.store.loadJournalIfPresent()
        guard current == context.registry,
              current.activeProfileID != profileID,
              let target = current.profiles.first(where: { $0.id == profileID }),
              !target.needsRelogin,
              journal?.phase == .validatingTarget,
              journal?.previousProfileID == current.activeProfileID,
              journal?.targetProfileID == profileID,
              targetValidationProfileID == nil,
              try !verificationWorkspaceExists(),
              let expectedDestination = switchActiveAuthDestination,
              try files.snapshot(at: activeAuthURL) == expectedDestination else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        let updatedTarget = ProfileMetadata(
            id: target.id,
            label: target.label,
            email: target.email,
            planType: target.planType,
            needsRelogin: true,
            createdAt: target.createdAt,
            updatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
        let updated = try ProfileRegistry(
            activeProfileID: current.activeProfileID,
            profiles: current.profiles.map { $0.id == profileID ? updatedTarget : $0 }
        )
        _ = try context.store.saveRegistry(updated)
        switchExpectedRegistry = updated
        guard try context.store.loadRegistry() == updated,
              try context.store.loadJournalIfPresent() == journal,
              try files.snapshot(at: activeAuthURL) == expectedDestination else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
    }

    public func replaceActiveAuth(with profileID: ProfileID) async throws {
        let context = try requireSwitchContext()
        try await revalidateCredentialMutationGate()
        guard context.registry.profiles.contains(where: { $0.id == profileID }),
              let expectedDestination = switchActiveAuthDestination,
              try files.snapshot(at: activeAuthURL) == expectedDestination else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        let credential = try credentialStore.loadCredential(for: profileID)
        let identity = try files.replace(
            contents: SensitiveBytes(CredentialBlob.persistenceData(for: credential)),
            at: activeAuthURL,
            expecting: expectedDestination
        )
        switchActiveAuthDestination = .exact(identity)
        guard try readCurrentCredential().credential == credential else {
            throw LocalCLIDataProviderFailure.credentialRoundTripFailed
        }
    }

    public func launchTarget() async throws {
        let descriptor = try requireSwitchContext().descriptor
        try await revalidateCredentialMutationGate()
        let pid = try await launchApplication(descriptor)
        try await confirmLaunchedApplication(pid, descriptor: descriptor)
        switchLaunchedApplicationPID = pid
    }

    public func verifyLaunchedTarget(expectedEmail: String) async throws {
        let descriptor = try requireSwitchContext().descriptor
        guard let pid = switchLaunchedApplicationPID,
              try await runningApplicationPIDs(descriptor).contains(pid) else {
            throw CodexAppLifecycleFailure.launchFailed
        }
#if SPIKE_FAULT_INJECTION
        if injectPostLaunchVerificationFailure {
            injectPostLaunchVerificationFailure = false
            postLaunchVerificationFailureInjected = true
            throw InjectedSwitchFailure.postLaunchTargetVerification
        }
#endif
        switchActiveAuthDestination = .exact(
            try await verifyActiveCredential(
                expectedEmail: expectedEmail,
                descriptor: descriptor
            )
        )
        guard try await runningApplicationPIDs(descriptor).contains(pid) else {
            throw CodexAppLifecycleFailure.launchFailed
        }
    }

    public func commitActiveProfile(_ profileID: ProfileID) async throws {
        recoveryLogger.notice("event=active_profile_commit_started")
        let context = try requireSwitchContext()
        let current = try context.store.loadRegistry()
        guard current == context.registry,
              current.profiles.contains(where: { $0.id == profileID && !$0.needsRelogin }),
              let expectedDestination = switchActiveAuthDestination,
              try files.snapshot(at: activeAuthURL) == expectedDestination else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
        if let journal = try context.store.loadJournalIfPresent(),
           journal.phase == .targetValidated {
            guard current.activeProfileID == profileID,
                  journal.targetProfileID == profileID,
                  try context.store.loadCaptureProfileIDIfPresent() == profileID else {
                throw LocalCLIDataProviderFailure.registryRoundTripFailed
            }
            _ = try markTargetVerified(journal, in: context.store)
        }
        let updated = try ProfileRegistry(activeProfileID: profileID, profiles: current.profiles)
        if current != updated {
            _ = try context.store.saveRegistry(updated)
        }
        guard try context.store.loadRegistry() == updated,
              try files.snapshot(at: activeAuthURL) == expectedDestination else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
        switchExpectedRegistry = updated
        recoveryLogger.notice("event=active_profile_commit_finished")
    }

    public func removeJournalDurably() async throws {
        recoveryLogger.notice("event=journal_removal_started")
        let context = try requireSwitchContext()
        guard try context.store.loadRegistry() == context.registry else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
        if let captureProfileID = try context.store.loadCaptureProfileIDIfPresent() {
            guard let journal = try context.store.loadJournalIfPresent(),
                  captureProfileID == journal.targetProfileID,
                  context.registry.profiles.last?.id == captureProfileID else {
                throw LocalCLIDataProviderFailure.pendingRecovery
            }
            _ = try context.store.removeCaptureProfileID()
            guard try context.store.loadCaptureProfileIDIfPresent() == nil else {
                throw LocalCLIDataProviderFailure.pendingRecovery
            }
        }
        guard case let .exact(expectedIdentity) = switchActiveAuthDestination,
              try files.snapshot(at: activeAuthURL) == .exact(expectedIdentity),
              let activeProfileID = context.registry.activeProfileID else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
        try finalizeJournal(
            in: context.store,
            expectedActiveProfileID: activeProfileID,
            expectedActiveAuthIdentity: expectedIdentity
        )
        recoveryLogger.notice("event=journal_removal_finished")
    }

    public func activateExistingApplication() async throws {
        guard try await activateApplication(requireSwitchContext().descriptor) else {
            throw CodexAppLifecycleFailure.normalTerminationRequestRejected
        }
    }

    public func restorePreviousCredential(_ profileID: ProfileID) async throws {
        let context = try requireSwitchContext()
        guard let profile = context.registry.profiles.first(where: { $0.id == profileID }) else {
            throw LocalCLIDataProviderFailure.rollbackFailed
        }
        guard let expectedDestination = switchActiveAuthDestination else {
            throw LocalCLIDataProviderFailure.rollbackFailed
        }
        if try files.snapshot(at: activeAuthURL) != expectedDestination {
            guard let journal = try context.store.loadJournalIfPresent(),
                  journal.phase == .rollbackStarted,
                  journal.previousProfileID == profileID,
                  let target = context.registry.profiles.first(where: { $0.id == journal.targetProfileID }) else {
                throw LocalCLIDataProviderFailure.rollbackFailed
            }
            switchActiveAuthDestination = .exact(
                try await verifyActiveCredential(
                    expectedEmail: target.email,
                    descriptor: context.descriptor
                )
            )
        }
        try await TargetCredentialValidator(driver: self).validate(profile: profile)
        let credential = try credentialStore.loadCredential(for: profileID)
        try await revalidateCredentialMutationGate()
        guard let expectedDestination = switchActiveAuthDestination,
              try files.snapshot(at: activeAuthURL) == expectedDestination else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        let identity = try files.replace(
            contents: SensitiveBytes(CredentialBlob.persistenceData(for: credential)),
            at: activeAuthURL,
            expecting: expectedDestination
        )
        switchActiveAuthDestination = .exact(identity)
        guard try readCurrentCredential().credential == credential else {
            throw LocalCLIDataProviderFailure.rollbackFailed
        }
    }

    public func verifyPrevious(expectedEmail: String) async throws {
        switchActiveAuthDestination = .exact(
            try await verifyActiveCredential(
                expectedEmail: expectedEmail,
                descriptor: requireSwitchContext().descriptor
            )
        )
    }

    public func launchPrevious() async throws {
        let descriptor = try requireSwitchContext().descriptor
        try await revalidateCredentialMutationGate()
        let pid = try await launchApplication(descriptor)
        try await confirmLaunchedApplication(pid, descriptor: descriptor)
    }
}

extension LocalCLIDataProvider: RecoveryExecuting {
    public func beginExclusiveRecovery() async throws -> Bool {
        guard switchLock == nil,
              captureLock == nil,
              switchStore == nil,
              switchDescriptor == nil,
              switchExpectedRegistry == nil else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        guard let store = try openStoreIfPresent() else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        guard let lock = try store.tryAcquireTransactionLock() else {
            return false
        }
        do {
            if let recoveryExpectedTransactionID,
               try store.loadJournalIfPresent()?.transactionID != recoveryExpectedTransactionID {
                throw RecoveryCoordinatorFailure.snapshotInvalid
            }
        } catch {
            lock.release()
            throw error
        }
        switchStore = store
        switchLock = lock
        return true
    }

    public func endExclusiveRecovery() async {
        resetSwitchTransactionState()
    }

    public func loadSnapshot() async throws -> RecoverySnapshot? {
        guard let store = switchStore, switchLock != nil else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        guard try store.loadProfileRemovalIfPresent() == nil else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        if try journalIsDurablyAbsent(in: store) {
            return nil
        }
        guard let journal = try store.loadJournalIfPresent() else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        recoveryLogger.notice("event=journal_loaded phase=\(journal.phase.rawValue, privacy: .public)")
        let registry = try store.loadRegistry()
        let captureProfileID = try store.loadCaptureProfileIDIfPresent()
        let captureMarkerIsRecoverable: Bool
        if let captureProfileID {
            captureMarkerIsRecoverable = captureProfileID == journal.targetProfileID
                && registry.profiles.last?.id == captureProfileID
                && (
                    journal.phase == .targetValidated
                        || journal.phase == .targetVerified
                        || journal.phase == .rollbackStarted
                        || journal.phase == .rollbackFailed
                )
        } else {
            captureMarkerIsRecoverable = true
        }
        guard captureMarkerIsRecoverable else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        guard let activeProfileID = registry.activeProfileID else {
            throw LocalCLIDataProviderFailure.activeProfileUnavailable
        }
        let knownProfileIDs = Set(registry.profiles.map(\.id))
        switchExpectedRegistry = registry

        if try store.loadJournalFinalizationEvidenceIfPresent() != nil {
            return RecoverySnapshot(
                journal: journal,
                knownProfileIDs: knownProfileIDs,
                registryActiveProfileID: activeProfileID,
                helperChildAlive: false,
                durabilityUnknown: true,
                activeCredential: .unreadable
            )
        }
        guard journal.previousProfileID != journal.targetProfileID,
              knownProfileIDs.contains(journal.previousProfileID),
              knownProfileIDs.contains(journal.targetProfileID),
              let previous = registry.profiles.first(where: { $0.id == journal.previousProfileID }),
              let target = registry.profiles.first(where: { $0.id == journal.targetProfileID }) else {
            return RecoverySnapshot(
                journal: journal,
                knownProfileIDs: knownProfileIDs,
                registryActiveProfileID: activeProfileID,
                helperChildAlive: false,
                durabilityUnknown: false,
                activeCredential: .unreadable
            )
        }
        let registryMatchesPhase = switch journal.phase {
        case .targetValidated:
            activeProfileID == previous.id
                || (captureProfileID != nil && activeProfileID == target.id)
        case .targetVerified, .rollbackStarted, .rollbackFailed:
            activeProfileID == previous.id || activeProfileID == target.id
        default:
            activeProfileID == previous.id
        }
        guard registryMatchesPhase,
              !previous.needsRelogin,
              journal.phase != .targetVerified || !target.needsRelogin else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        if journal.phase == .rollbackFailed, captureProfileID == nil {
            return RecoverySnapshot(
                journal: journal,
                knownProfileIDs: knownProfileIDs,
                registryActiveProfileID: activeProfileID,
                helperChildAlive: false,
                durabilityUnknown: false,
                activeCredential: .unreadable
            )
        }
        let descriptor = try await locateApp()
        guard ApprovedResidentRule.codexCrashpad(for: descriptor) != nil else {
            throw LocalCLIDataProviderFailure.incompatibleApplication
        }
        switchDescriptor = descriptor

        if probeChildUnconfirmed {
            return RecoverySnapshot(
                journal: journal,
                knownProfileIDs: knownProfileIDs,
                registryActiveProfileID: activeProfileID,
                helperChildAlive: true,
                durabilityUnknown: false,
                activeCredential: .unreadable
            )
        }

        if recoveryRequestsApplicationQuiescence {
            do {
                try await requestNormalQuit()
                try await waitForQuiescence()
                recoveryLogger.notice("event=application_quiescent")
            } catch let failure as SwitchCoordinatorFailure where failure == .processBlocked {
                recoveryLogger.error("event=application_quiescence_failed code=process_blocked")
                return RecoverySnapshot(
                    journal: journal,
                    knownProfileIDs: knownProfileIDs,
                    registryActiveProfileID: activeProfileID,
                    helperChildAlive: false,
                    durabilityUnknown: false,
                    activeCredential: .unreadable,
                    processBlockerPresent: true
                )
            }
        }

        let activeAuthDestination = try files.snapshot(at: activeAuthURL)
        switchActiveAuthDestination = activeAuthDestination

        let processBlockerPresent: Bool
        do {
            let inventory = try await processInventory(for: descriptor)
            processBlockerPresent = !inventory.authMutationAllowed
        } catch {
            processBlockerPresent = true
        }
        if processBlockerPresent || probeChildUnconfirmed {
            recoveryLogger.error(
                "event=process_gate_failed blocker=\(processBlockerPresent, privacy: .public) child_unconfirmed=\(self.probeChildUnconfirmed, privacy: .public)"
            )
            return RecoverySnapshot(
                journal: journal,
                knownProfileIDs: knownProfileIDs,
                registryActiveProfileID: activeProfileID,
                helperChildAlive: probeChildUnconfirmed,
                durabilityUnknown: false,
                activeCredential: .unreadable,
                processBlockerPresent: processBlockerPresent
            )
        }

        if try verificationWorkspaceExists() {
            try quarantineVerificationHomes(transactionID: journal.transactionID)
        }
        let activeCredential = await recoveryActiveCredentialEvidence(
            journal: journal,
            registry: registry,
            descriptor: descriptor,
            expectedDestination: activeAuthDestination
        )
        switch activeCredential {
        case .previous:
            recoveryLogger.notice("event=active_credential_evidence result=previous")
        case .previousCredentialChanged:
            recoveryLogger.notice("event=active_credential_evidence result=previous_credential_changed")
        case .target:
            recoveryLogger.notice("event=active_credential_evidence result=target")
        case .other:
            recoveryLogger.error("event=active_credential_evidence result=other")
        case .unreadable:
            recoveryLogger.error("event=active_credential_evidence result=unreadable")
        }
        guard try store.loadRegistry() == registry,
              try store.loadJournalIfPresent() == journal,
              try store.loadJournalFinalizationEvidenceIfPresent() == nil,
              try store.loadCaptureProfileIDIfPresent() == captureProfileID,
              try files.snapshot(at: activeAuthURL) == activeAuthDestination else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        return RecoverySnapshot(
            journal: journal,
            knownProfileIDs: knownProfileIDs,
            registryActiveProfileID: activeProfileID,
            helperChildAlive: probeChildUnconfirmed,
            durabilityUnknown: false,
            activeCredential: activeCredential,
            captureRecoveryPending: captureProfileID != nil
        )
    }

    public func cleanupTargetWorkspace() async throws {
        let context = try requireSwitchContext()
        guard let journal = try context.store.loadJournalIfPresent() else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        try await revalidateCredentialMutationGate()
        try quarantineVerificationHomes(transactionID: journal.transactionID)
        guard try !verificationWorkspaceExists() else {
            throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
        }
        try await revalidateCredentialMutationGate()
    }

    public func repairCurrentCredential(_ profileID: ProfileID) async throws {
        let context = try requireSwitchContext()
        guard let profile = context.registry.profiles.first(where: { $0.id == profileID }),
              let registryActiveProfileID = context.registry.activeProfileID else {
            throw LocalCLIDataProviderFailure.rollbackFailed
        }
        if registryActiveProfileID != profile.id {
            guard let journal = try context.store.loadJournalIfPresent(),
                  journal.previousProfileID == profile.id,
                  registryActiveProfileID == journal.targetProfileID,
                  try context.store.loadCaptureProfileIDIfPresent() == journal.targetProfileID,
                  journal.phase == .rollbackStarted || journal.phase == .rollbackFailed else {
                throw LocalCLIDataProviderFailure.rollbackFailed
            }
        }
        do {
            try await revalidateCredentialMutationGate()
            switchActiveAuthDestination = .exact(
                try await verifyActiveCredential(
                    expectedEmail: profile.email,
                    descriptor: context.descriptor
                )
            )
            try await revalidateCredentialMutationGate()
            try await refreshAndSaveCurrent(
                profile: profile,
                expectedRegistryActiveProfileID: registryActiveProfileID
            )
        } catch {
            if appServerExitIsUnconfirmed(error) {
                throw error
            }
            try await restorePreviousCredential(profileID)
        }
    }

    public func verifyPrevious(expectedProfileID: ProfileID) async throws {
        recoveryLogger.notice("event=previous_verification_started")
        let context = try requireSwitchContext()
        guard let journal = try context.store.loadJournalIfPresent(),
              journal.previousProfileID == expectedProfileID,
              let profile = context.registry.profiles.first(where: { $0.id == expectedProfileID }) else {
            throw LocalCLIDataProviderFailure.rollbackFailed
        }
        do {
            try await revalidateCredentialMutationGate()
            switchActiveAuthDestination = .exact(
                try await verifyActiveCredential(
                    expectedEmail: profile.email,
                    descriptor: context.descriptor
                )
            )
            try await revalidateCredentialMutationGate()
            recoveryLogger.notice("event=previous_verification_finished")
        } catch let failure as SwitchCoordinatorFailure where failure == .processBlocked {
            recoveryLogger.error("event=previous_verification_failed code=process_blocked")
            throw failure
        } catch let failure as ProfileCaptureFailure where failure == .identityMismatch {
            recoveryLogger.error("event=previous_verification_failed code=identity_mismatch")
            throw failure
        } catch let failure as AppServerProbeFailure {
            recoveryLogger.error("event=previous_verification_failed code=app_server_failure")
            throw failure
        } catch {
            recoveryLogger.error("event=previous_verification_failed code=other")
            throw error
        }
    }

    public func verifyTargetStillActive(expectedProfileID: ProfileID) async throws {
        let context = try requireSwitchContext()
        guard let journal = try context.store.loadJournalIfPresent(),
              journal.targetProfileID == expectedProfileID,
              let profile = context.registry.profiles.first(where: { $0.id == expectedProfileID }) else {
            throw LocalCLIDataProviderFailure.rollbackFailed
        }
        try await revalidateCredentialMutationGate()
        let identity: FileIdentity
        do {
            identity = try await verifyActiveCredential(
                expectedEmail: profile.email,
                descriptor: context.descriptor
            )
            let current = try readCurrentCredential()
            guard current.identity == identity,
                  current.credential == (try credentialStore.loadCredential(for: expectedProfileID)) else {
                throw RecoveryTargetVerificationFailure.targetUnverified
            }
        } catch let failure as AppServerProbeFailure
            where failure.childDisposition == .unconfirmed
        {
            throw failure
        } catch {
            throw RecoveryTargetVerificationFailure.targetUnverified
        }
        switchActiveAuthDestination = .exact(identity)
        try await revalidateCredentialMutationGate()
    }
}

extension LocalCLIDataProvider: TargetCredentialValidationDriving {
    public func prepareWorkspace(for profileID: ProfileID) async throws {
        let context = try requireSwitchContext()
        guard targetValidationProfileID == nil,
              context.registry.profiles.contains(where: { $0.id == profileID }) else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        let credential = try credentialStore.loadCredential(for: profileID)
        let homeURL = credentialVerificationHomeURL
        try createVerificationHome(homeURL)
        targetValidationProfileID = profileID
        do {
            _ = try files.replace(
                contents: SensitiveBytes(CredentialBlob.persistenceData(for: credential)),
                at: homeURL.appendingPathComponent("auth.json", isDirectory: false),
                expecting: .absent
            )
        } catch {
            try? removeVerificationHome(homeURL)
            targetValidationProfileID = nil
            throw error
        }
    }

    public func probe(refreshToken: Bool) async throws -> AppServerAccountRead {
        guard targetValidationProfileID != nil else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        return try await probeAccount(
            descriptor: requireSwitchContext().descriptor,
            codexHomeURL: credentialVerificationHomeURL,
            refreshToken: refreshToken
        )
    }

    public func readRefreshedCredential() async throws -> CredentialBlob {
        guard targetValidationProfileID != nil else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        return try CredentialBlob(
            validating: files.read(
                at: credentialVerificationHomeURL.appendingPathComponent("auth.json", isDirectory: false)
            ).contents.data
        )
    }

    public func saveRefreshedCredential(
        _ credential: CredentialBlob,
        for profileID: ProfileID
    ) async throws {
        let context = try requireSwitchContext()
        guard targetValidationProfileID == profileID,
              try context.store.loadRegistry() == context.registry else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        try credentialStore.saveCredential(credential, for: profileID)
        guard try credentialStore.loadCredential(for: profileID) == credential,
              try context.store.loadRegistry() == context.registry else {
            throw LocalCLIDataProviderFailure.credentialRoundTripFailed
        }
    }

    public func cleanupWorkspace() async throws {
        guard targetValidationProfileID != nil else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        try removeVerificationHome(credentialVerificationHomeURL)
        targetValidationProfileID = nil
    }
}

private extension LocalCLIDataProvider {
    func confirmLaunchedApplication(
        _ pid: Int32,
        descriptor: CodexAppDescriptor
    ) async throws {
        guard pid > 0 else {
            throw CodexAppLifecycleFailure.launchFailed
        }
        for poll in 0..<20 {
            if try await runningApplicationPIDs(descriptor).contains(pid) {
                return
            }
            if poll < 19 {
                try await quiescenceSleep(.milliseconds(250))
            }
        }
        throw CodexAppLifecycleFailure.launchFailed
    }

    func switchProcessInventory(for descriptor: CodexAppDescriptor) async throws -> ProcessInventory {
        do {
            return try await processInventory(for: descriptor)
        } catch LocalCLIDataProviderFailure.processSnapshotUnstable {
            throw SwitchCoordinatorFailure.processBlocked
        }
    }

    func inspectAuthStatus() -> AuthInspectionStatus {
        let parent = activeAuthURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            return .absent
        }
        do {
            switch try files.snapshot(at: activeAuthURL) {
            case .absent:
                return .absent
            case .exact:
                return .privateRegularFile
            }
        } catch {
            return .unsafe
        }
    }

    func readCurrentCredential() throws -> (credential: CredentialBlob, identity: FileIdentity) {
        let result = try files.read(at: activeAuthURL)
        return (try CredentialBlob(validating: result.contents.data), result.identity)
    }

    func recoveryActiveCredentialEvidence(
        journal: SwitchJournalRecord,
        registry: ProfileRegistry,
        descriptor: CodexAppDescriptor,
        expectedDestination: ExpectedDestination
    ) async -> ActiveCredentialEvidence {
        guard case let .exact(expectedIdentity) = expectedDestination,
              let current = try? readCurrentCredential(),
              current.identity == expectedIdentity else {
            recoveryLogger.error("event=evidence_failed stage=active_auth_snapshot")
            return .unreadable
        }
        let matchesPrevious = (try? credentialStore.loadCredential(for: journal.previousProfileID))
            .map { $0 == current.credential } ?? false
        let matchesTarget = (try? credentialStore.loadCredential(for: journal.targetProfileID))
            .map { $0 == current.credential } ?? false
        switch (matchesPrevious, matchesTarget) {
        case (true, false):
            recoveryLogger.notice("event=evidence_resolved result=previous source=keychain")
            return .previous
        case (false, true):
            recoveryLogger.notice("event=evidence_resolved result=target source=keychain")
            return .target
        case (true, true):
            recoveryLogger.error("event=evidence_resolved result=ambiguous source=keychain")
            return .other
        case (false, false):
            break
        }
        guard let previous = registry.profiles.first(where: { $0.id == journal.previousProfileID }),
              let target = registry.profiles.first(where: { $0.id == journal.targetProfileID }) else {
            return .other
        }
        do {
            recoveryLogger.notice("event=evidence_probe_started expected=previous")
            _ = try await validatedCredential(
                current.credential,
                expectedEmail: previous.email,
                descriptor: descriptor
            )
            recoveryLogger.notice("event=evidence_probe_finished result=previous_credential_changed")
            return .previousCredentialChanged
        } catch let failure as ProfileCaptureFailure where failure == .identityMismatch {
            recoveryLogger.notice("event=evidence_probe_finished result=previous_mismatch")
        } catch is AppServerProbeFailure {
            recoveryLogger.error("event=evidence_probe_failed expected=previous code=app_server_failure")
            return .unreadable
        } catch {
            recoveryLogger.error("event=evidence_probe_failed expected=previous code=other")
            return .unreadable
        }
        do {
            recoveryLogger.notice("event=evidence_probe_started expected=target")
            _ = try await validatedCredential(
                current.credential,
                expectedEmail: target.email,
                descriptor: descriptor
            )
            recoveryLogger.notice("event=evidence_probe_finished result=target")
            return .target
        } catch let failure as ProfileCaptureFailure where failure == .identityMismatch {
            recoveryLogger.notice("event=evidence_probe_finished result=target_mismatch")
            return .other
        } catch is AppServerProbeFailure {
            recoveryLogger.error("event=evidence_probe_failed expected=target code=app_server_failure")
            return .unreadable
        } catch {
            recoveryLogger.error("event=evidence_probe_failed expected=target code=other")
            return .unreadable
        }
    }

    func processInventory(for descriptor: CodexAppDescriptor?) async throws -> ProcessInventory {
        let runningBefore = if let descriptor {
            Set(try await runningApplicationPIDs(descriptor))
        } else {
            Set<Int32>()
        }
        let records: [ProcessRecord]
        do {
            records = try processProvider.snapshot()
        } catch ProcessSnapshotFailure.processChanged {
            throw LocalCLIDataProviderFailure.processSnapshotUnstable
        }
        let runningAfter = if let descriptor {
            Set(try await runningApplicationPIDs(descriptor))
        } else {
            Set<Int32>()
        }
        let recordedPIDs = Set(records.map(\.identity.pid))
        guard runningBefore == runningAfter,
              runningAfter.isSubset(of: recordedPIDs) else {
            throw LocalCLIDataProviderFailure.processSnapshotUnstable
        }
        let roots = Set(records.filter { runningAfter.contains($0.identity.pid) }.map(\.identity))
        let approvedResidents = descriptor.flatMap(ApprovedResidentRule.codexCrashpad).map { [$0] } ?? []
        let context = ProcessClassificationContext(
            bundleRootPath: descriptor?.bundleURL.path ?? "/__codex_app_not_found__",
            mainExecutablePath: descriptor?.mainExecutableURL.path ?? "/__codex_main_not_found__",
            bundledCodexPath: descriptor?.bundledCodexURL.path ?? "/__codex_cli_not_found__",
            appRootIdentities: roots,
            helperOwnedIdentities: [],
            approvedResidents: approvedResidents
        )
        return ProcessClassifier.classify(records, context: context)
    }

    func resetCaptureState() {
        captureLock?.release()
        captureLock = nil
        captureStore = nil
        captureProfileID = nil
        captureOriginalRegistry = nil
        captureDescriptor = nil
        originalCredential = nil
        originalAuthIdentity = nil
        capturedAuthIdentity = nil
        probeChildUnconfirmed = false
        captureMutationUncertain = false
    }

    func appOwnedTerminationCandidates(
        in inventory: ProcessInventory
    ) throws -> [ProcessIdentity: ProcessRecord] {
        let blockers = inventory.processes.filter { $0.disposition.blocksAuthMutation }
        guard blockers.allSatisfy({
            $0.disposition == .appOwnedBlocker && $0.record.executablePath != nil
        }) else {
            throw ApplicationQuiescenceFailure.processBlocked
        }
        return Dictionary(uniqueKeysWithValues: blockers.map { ($0.record.identity, $0.record) })
    }

    func capturedAppOwnedSurvivors(
        in inventory: ProcessInventory,
        terminationCandidates: [ProcessIdentity: ProcessRecord]
    ) throws -> [ProcessRecord] {
        var identities = Set<ProcessIdentity>()
        var survivors = [ProcessRecord]()
        for process in inventory.processes {
            guard let captured = terminationCandidates[process.record.identity] else {
                continue
            }
            guard captured.executablePath == process.record.executablePath,
                  identities.insert(process.record.identity).inserted else {
                throw ApplicationQuiescenceFailure.processBlocked
            }
            survivors.append(process.record)
        }
        return survivors
    }

    func terminateCapturedAppOwnedProcesses(_ survivors: [ProcessRecord]) throws {
        guard !survivors.isEmpty else {
            throw ApplicationQuiescenceFailure.processBlocked
        }
        do {
            for process in survivors {
                try requestProcessTermination(process)
            }
        } catch {
            throw ApplicationQuiescenceFailure.processBlocked
        }
    }

    func resetSwitchTransactionState() {
        switchLock?.release()
        switchLock = nil
        switchStore = nil
        switchDescriptor = nil
        switchExpectedRegistry = nil
        switchActiveAuthDestination = nil
        switchLaunchedApplicationPID = nil
        switchAppOwnedTerminationCandidates = [:]
        recoveryExpectedTransactionID = nil
        recoveryRequestsApplicationQuiescence = false
        targetValidationProfileID = nil
    }

    func requireSwitchContext() throws -> (
        store: SpikeStore,
        descriptor: CodexAppDescriptor,
        registry: ProfileRegistry
    ) {
        guard let store = switchStore,
              let descriptor = switchDescriptor,
              let registry = switchExpectedRegistry else {
            throw LocalCLIDataProviderFailure.invalidSwitchState
        }
        return (store, descriptor, registry)
    }

    func markTargetVerified(
        _ journal: SwitchJournalRecord,
        in store: SpikeStore
    ) throws -> SwitchJournalRecord {
        let updated = SwitchJournalRecord(
            transactionID: journal.transactionID,
            phase: .targetVerified,
            previousProfileID: journal.previousProfileID,
            targetProfileID: journal.targetProfileID,
            startedAt: journal.startedAt,
            updatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
        _ = try store.updateVerifiedTargetJournal(updated)
        return updated
    }

    func appServerExitIsUnconfirmed(_ error: Error) -> Bool {
        guard let failure = error as? AppServerProbeFailure else { return false }
        return failure.childDisposition == .unconfirmed
    }

    func requireMutationGate(for descriptor: CodexAppDescriptor) async throws {
        guard try await processInventory(for: descriptor).authMutationAllowed else {
            throw LocalCLIDataProviderFailure.processBlocked
        }
    }

    func requireCapturedAuthUnchanged() throws {
        guard let capturedAuthIdentity,
              try files.snapshot(at: activeAuthURL) == .exact(capturedAuthIdentity) else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
    }

    func removeVerificationHome(_ url: URL) throws {
        do {
            try PrivateDirectory.validate(at: url)
            try FileManager.default.removeItem(at: url)
            try PrivateDirectory.sync(at: url.deletingLastPathComponent())
        } catch {
            throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
        }
    }

    func removeAbandonedVerificationWorkspacesIfSafe(in store: SpikeStore) throws {
        let homes = try verificationHomeURLs.filter(pathExists)
        guard !homes.isEmpty else { return }
        guard let lock = try store.tryAcquireTransactionLock() else {
            throw LocalCLIDataProviderFailure.lockBusy
        }
        defer { lock.release() }
        for homeURL in homes {
            switch try readVerificationChildMarker(in: homeURL) {
            case .notLaunched:
                continue
            case .launching:
                probeChildUnconfirmed = true
                throw LocalCLIDataProviderFailure.pendingRecovery
            case let .child(pid):
                guard try !verificationChildIsAlive(pid) else {
                    probeChildUnconfirmed = true
                    throw LocalCLIDataProviderFailure.pendingRecovery
                }
            }
        }
        probeChildUnconfirmed = false
        guard try journalIsDurablyAbsent(in: store),
              try store.loadCaptureProfileIDIfPresent() == nil,
              try store.loadProfileRemovalIfPresent() == nil else {
            return
        }
        for homeURL in homes {
            try removeVerificationHome(homeURL)
        }
        isolatedLoginSession = nil
    }

    var credentialVerificationHomeURL: URL {
        storeURL.appendingPathComponent("credential-verification-workspace", isDirectory: true)
    }

    var captureVerificationHomeURL: URL {
        storeURL.appendingPathComponent("capture-verification-workspace", isDirectory: true)
    }

    var isolatedLoginHomeURL: URL {
        storeURL.appendingPathComponent("isolated-login-workspace", isDirectory: true)
    }

    var isolatedLoginMarkerURL: URL {
        isolatedLoginHomeURL.appendingPathComponent(verificationChildMarkerName, isDirectory: false)
    }

    enum VerificationChildMarker: Equatable {
        case notLaunched
        case launching
        case child(Int32)
    }

    func readVerificationChildMarker(in homeURL: URL) throws -> VerificationChildMarker {
        let markerURL = homeURL.appendingPathComponent(verificationChildMarkerName, isDirectory: false)
        guard case .exact = try files.snapshot(at: markerURL) else { return .notLaunched }
        let data = try files.read(at: markerURL, maximumBytes: 64).contents.data
        guard let value = String(data: data, encoding: .utf8) else {
            throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
        }
        if value == "launching\n" { return .launching }
        guard value.hasPrefix("pid="), value.hasSuffix("\n"),
              let pid = Int32(value.dropFirst(4).dropLast()), pid > 0 else {
            throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
        }
        return .child(pid)
    }

    var verificationHomeURLs: [URL] {
        [credentialVerificationHomeURL, captureVerificationHomeURL, isolatedLoginHomeURL]
    }

    var recoveryEvidenceURL: URL {
        storeURL.appendingPathComponent("recovery-evidence", isDirectory: true)
    }

    func quarantineVerificationHomes(transactionID: UUID) throws {
        let staleHomes = try verificationHomeURLs.filter(pathExists)
        let evidenceExists = try pathExists(recoveryEvidenceURL)
        guard !staleHomes.isEmpty || evidenceExists else { return }
        do {
            if evidenceExists {
                try PrivateDirectory.validate(at: recoveryEvidenceURL)
            } else {
                _ = try PrivateDirectory.ensure(at: recoveryEvidenceURL)
            }
            for homeURL in staleHomes {
                try PrivateDirectory.validate(at: homeURL)
                let destination = recoveryEvidenceURL.appendingPathComponent(
                    "\(transactionID.uuidString)-\(homeURL.lastPathComponent)-\(UUID().uuidString)",
                    isDirectory: true
                )
                guard try !pathExists(destination) else {
                    throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
                }
                try moveVerificationHome(homeURL, to: destination)
                try PrivateDirectory.validate(at: destination)
            }
            try PrivateDirectory.sync(at: recoveryEvidenceURL)
            try PrivateDirectory.sync(at: storeURL)
        } catch {
            throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
        }
    }

    func moveVerificationHome(_ source: URL, to destination: URL) throws {
        var result: Int32
        repeat {
            result = source.path.withCString { sourcePath in
                destination.path.withCString { destinationPath in
                    Darwin.rename(sourcePath, destinationPath)
                }
            }
        } while result == -1 && errno == EINTR
        guard result == 0 else {
            throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
        }
        do {
            try PrivateDirectory.sync(at: destination.deletingLastPathComponent())
            try PrivateDirectory.sync(at: source.deletingLastPathComponent())
        } catch {
            throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
        }
    }

    func createVerificationHome(_ url: URL) throws {
        do {
            guard try PrivateDirectory.ensure(at: url) else {
                throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
            }
        } catch {
            throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
        }
    }

    func verificationWorkspaceExists() throws -> Bool {
        for url in verificationHomeURLs where try pathExists(url) {
            return true
        }
        return false
    }

    func pathExists(_ url: URL) throws -> Bool {
        var information = stat()
        var result: Int32
        repeat {
            result = Darwin.lstat(url.path, &information)
        } while result == -1 && errno == EINTR
        if result == -1, errno == ENOENT {
            return false
        }
        guard result == 0 else {
            throw LocalCLIDataProviderFailure.verificationWorkspaceFailed
        }
        return true
    }

    func removeCaptureArtifacts(store: SpikeStore, profileID: ProfileID) throws {
        try credentialStore.removeCredential(for: profileID)
        _ = try store.removeCaptureProfileID()
    }

    func mutationOutcomeIsUncertain(_ error: Error) -> Bool {
        guard let failure = error as? DurableFileFailure else { return false }
        return failure.certainty != .destinationUnchanged
    }

    func saveRegistryConfirming(_ registry: ProfileRegistry, in store: SpikeStore) throws {
        do {
            _ = try store.saveRegistry(registry)
        } catch {
            guard (try? store.loadRegistry()) == registry else { throw error }
        }
        guard try store.loadRegistry() == registry else {
            throw LocalCLIDataProviderFailure.registryRoundTripFailed
        }
    }

    func rollbackPendingRegistration(
        profileID: ProfileID,
        pendingRegistry: ProfileRegistry,
        originalRegistry: ProfileRegistry,
        store: SpikeStore
    ) throws {
        guard try store.loadRegistry() == pendingRegistry else {
            throw LocalCLIDataProviderFailure.rollbackFailed
        }
        try credentialStore.removeCredential(for: profileID)
        do {
            try saveRegistryConfirming(originalRegistry, in: store)
        } catch {
            throw LocalCLIDataProviderFailure.rollbackFailed
        }
    }

    func loadCredentialIfPresent(for profileID: ProfileID) throws -> CredentialBlob? {
        do {
            return try credentialStore.loadCredential(for: profileID)
        } catch CredentialStoreError.notFound {
            return nil
        } catch let failure as DurableFileFailure where failure.errno == ENOENT {
            return nil
        }
    }

    func verifyActiveCredential(
        expectedEmail: String,
        descriptor: CodexAppDescriptor
    ) async throws -> FileIdentity {
        let current = try readCurrentCredential()
        _ = try await validatedCredential(
            current.credential,
            expectedEmail: expectedEmail,
            descriptor: descriptor
        )
        guard try files.snapshot(at: activeAuthURL) == .exact(current.identity) else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        return current.identity
    }

    func validatedCredential(
        _ credential: CredentialBlob,
        expectedEmail: String,
        descriptor: CodexAppDescriptor,
        refreshToken: Bool = false
    ) async throws -> CredentialBlob {
        let homeURL = credentialVerificationHomeURL
        try createVerificationHome(homeURL)
        let authURL = homeURL.appendingPathComponent("auth.json", isDirectory: false)
        do {
            _ = try files.replace(
                contents: SensitiveBytes(CredentialBlob.persistenceData(for: credential)),
                at: authURL,
                expecting: .absent
            )
            try AccountIdentityValidator.validate(
                expectedEmail: expectedEmail,
                account: try await probeAccount(
                    descriptor: descriptor,
                    codexHomeURL: homeURL,
                    refreshToken: refreshToken
                )
            )
            let credential = try CredentialBlob(validating: files.read(at: authURL).contents.data)
            try removeVerificationHome(homeURL)
            return credential
        } catch let failure as AppServerProbeFailure where failure.childDisposition == .unconfirmed {
            probeChildUnconfirmed = true
            throw failure
        } catch is AccountIdentityError {
            try removeVerificationHome(homeURL)
            throw ProfileCaptureFailure.identityMismatch
        } catch {
            try removeVerificationHome(homeURL)
            throw error
        }
    }

    func readProfileUsage(
        _ credential: CredentialBlob,
        expectedEmail: String,
        descriptor: CodexAppDescriptor
    ) async throws -> AppServerAccountUsageRead {
        let homeURL = credentialVerificationHomeURL
        try createVerificationHome(homeURL)
        let authURL = homeURL.appendingPathComponent("auth.json", isDirectory: false)
        do {
            let authIdentity = try files.replace(
                contents: SensitiveBytes(try CredentialBlob.usageProbeData(for: credential)),
                at: authURL,
                expecting: .absent
            )
            let usage = try await probeAccountUsage(
                descriptor: descriptor,
                codexHomeURL: homeURL
            )
            try AccountIdentityValidator.validate(expectedEmail: expectedEmail, account: usage.account)
            guard try files.snapshot(at: authURL) == .exact(authIdentity) else {
                throw LocalCLIDataProviderFailure.credentialRoundTripFailed
            }
            try removeVerificationHome(homeURL)
            return usage
        } catch let failure as AppServerProbeFailure where failure.childDisposition == .unconfirmed {
            probeChildUnconfirmed = true
            throw failure
        } catch is AccountIdentityError {
            try removeVerificationHome(homeURL)
            throw ProfileCaptureFailure.identityMismatch
        } catch {
            try removeVerificationHome(homeURL)
            throw error
        }
    }

    func readActiveProfileUsage(
        expectedEmail: String,
        descriptor: CodexAppDescriptor
    ) async throws -> AppServerAccountUsageRead {
        let current = try readCurrentCredential()
        let usage: AppServerAccountUsageRead
        do {
            usage = try await readProfileUsage(
                current.credential,
                expectedEmail: expectedEmail,
                descriptor: descriptor
            )
        } catch is ProfileCaptureFailure {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        guard try files.snapshot(at: activeAuthURL) == .exact(current.identity) else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        return usage
    }

    func usageFailureRequiresStop(_ error: Error) -> Bool {
        guard let failure = error as? LocalCLIDataProviderFailure else { return false }
        switch failure {
        case .incompatibleApplication, .credentialRoundTripFailed, .registryRoundTripFailed,
             .activeAuthChanged, .verificationWorkspaceFailed:
            return true
        default:
            return false
        }
    }

    func planType(from account: AppServerAccountRead) -> String? {
        guard case let .chatGPT(_, planType, _) = account else { return nil }
        return planType
    }

    func runIsolatedLogin(
        descriptor: CodexAppDescriptor,
        expectedEmail: String? = nil,
        disallowedEmails: Set<String> = []
    ) async throws -> IsolatedLoginResult {
        try requireProfileLoginNotCancelled(childDisposition: .notStarted)
        let loginHome = isolatedLoginHomeURL
        try createVerificationHome(loginHome)
        do {
            let markerURL = isolatedLoginMarkerURL
            try writeVerificationChildMarker(at: markerURL, value: "launching")
            let session = CodexLoginSession(
                configuration: CodexLoginConfiguration(
                    executableURL: descriptor.bundledCodexURL,
                    codexHomeURL: loginHome,
                    timeouts: CodexLoginTimeouts(login: .seconds(600), terminateExit: .seconds(2))
                ),
                didLaunch: { pid in
                    try writeVerificationChildMarker(at: markerURL, value: "pid=\(pid)")
                }
            )
            isolatedLoginSession = session
            try await session.run()
            isolatedLoginSession = nil
            try requireProfileLoginNotCancelled()
            guard try await locateApp() == descriptor else {
                throw LocalCLIDataProviderFailure.incompatibleApplication
            }

            let initial = try capturedProfileIdentity(
                from: try await probeAccount(descriptor: descriptor, codexHomeURL: loginHome)
            )
            try requireProfileLoginNotCancelled()
            if let expectedEmail, initial.email != expectedEmail {
                throw ProfileCaptureFailure.identityMismatch
            }
            guard !disallowedEmails.contains(initial.email) else {
                throw ProfileCaptureFailure.accountAlreadyRegistered
            }
            guard try await locateApp() == descriptor else {
                throw LocalCLIDataProviderFailure.incompatibleApplication
            }
            let refreshed = try capturedProfileIdentity(
                from: try await probeAccount(
                    descriptor: descriptor,
                    codexHomeURL: loginHome,
                    refreshToken: true
                )
            )
            try requireProfileLoginNotCancelled()
            guard refreshed.email == initial.email,
                  expectedEmail == nil || refreshed.email == expectedEmail else {
                throw ProfileCaptureFailure.identityMismatch
            }
            guard try await locateApp() == descriptor else {
                throw LocalCLIDataProviderFailure.incompatibleApplication
            }
            let verified = try capturedProfileIdentity(
                from: try await probeAccount(descriptor: descriptor, codexHomeURL: loginHome)
            )
            try requireProfileLoginNotCancelled()
            guard verified.email == initial.email,
                  expectedEmail == nil || verified.email == expectedEmail else {
                throw ProfileCaptureFailure.identityMismatch
            }
            guard try await locateApp() == descriptor else {
                throw LocalCLIDataProviderFailure.incompatibleApplication
            }
            try requireProfileLoginNotCancelled()
            let loginAuthURL = loginHome.appendingPathComponent("auth.json", isDirectory: false)
            let credential = try CredentialBlob(validating: files.read(at: loginAuthURL).contents.data)
            try removeVerificationHome(loginHome)
            probeChildUnconfirmed = false
            return IsolatedLoginResult(
                credential: credential,
                email: verified.email,
                planType: refreshed.planType ?? verified.planType
            )
        } catch let failure as CodexLoginFailure where failure.childDisposition == .unconfirmed {
            probeChildUnconfirmed = true
            throw failure
        } catch let failure as AppServerProbeFailure where failure.childDisposition == .unconfirmed {
            probeChildUnconfirmed = true
            throw failure
        } catch {
            if try pathExists(loginHome) {
                try removeVerificationHome(loginHome)
            }
            isolatedLoginSession = nil
            probeChildUnconfirmed = false
            throw error
        }
    }

    func requireProfileLoginNotCancelled(
        childDisposition: CodexLoginFailure.ChildDisposition = .confirmedExited
    ) throws {
        guard !profileLoginCancellationRequested, !Task.isCancelled else {
            throw CodexLoginFailure(code: .cancelled, childDisposition: childDisposition)
        }
    }

    func probeAccount(
        descriptor: CodexAppDescriptor,
        codexHomeURL: URL,
        homePolicy: AppServerProbeHomePolicy = .privateDirectory,
        refreshToken: Bool = false
    ) async throws -> AppServerAccountRead {
        try await makeAppServerProbeSession(
            descriptor: descriptor,
            codexHomeURL: codexHomeURL,
            homePolicy: homePolicy,
            refreshToken: refreshToken
        ).run()
    }

    func probeAccountUsage(
        descriptor: CodexAppDescriptor,
        codexHomeURL: URL
    ) async throws -> AppServerAccountUsageRead {
        try await makeAppServerProbeSession(
            descriptor: descriptor,
            codexHomeURL: codexHomeURL,
            homePolicy: .privateDirectory,
            refreshToken: false
        ).runAccountUsage()
    }

    func makeAppServerProbeSession(
        descriptor: CodexAppDescriptor,
        codexHomeURL: URL,
        homePolicy: AppServerProbeHomePolicy,
        refreshToken: Bool
    ) throws -> AppServerProbeSession {
        let didLaunch: @Sendable (Int32) throws -> Void
        switch homePolicy {
        case .privateDirectory:
            let markerURL = codexHomeURL.appendingPathComponent(
                verificationChildMarkerName,
                isDirectory: false
            )
            try writeVerificationChildMarker(at: markerURL, value: "launching")
            didLaunch = { pid in
                try writeVerificationChildMarker(at: markerURL, value: "pid=\(pid)")
            }
        case .ownerControlled:
            didLaunch = { _ in }
        }
        return AppServerProbeSession(
            configuration: AppServerProbeConfiguration(
                executableURL: descriptor.bundledCodexURL,
                codexHomeURL: codexHomeURL,
                homePolicy: homePolicy,
                refreshToken: refreshToken,
                timeouts: AppServerProbeTimeouts(
                    initializeResponse: .seconds(10),
                    accountResponse: .seconds(30),
                    normalExit: .seconds(5),
                    terminateExit: .seconds(2)
                )
            ),
            didLaunch: didLaunch
        )
    }

    func restoreOriginalAfterCapture(
        store: SpikeStore,
        captureProfileID: ProfileID,
        originalRegistry: ProfileRegistry
    ) async throws {
        guard let descriptor = captureDescriptor,
              let journal = try store.loadJournalIfPresent(),
              journal.phase != .rollbackFailed,
              journal.previousProfileID == originalRegistry.activeProfileID,
              journal.targetProfileID == captureProfileID else {
            throw LocalCLIDataProviderFailure.rollbackUnavailable
        }
        let rollback = SwitchJournalRecord(
            transactionID: journal.transactionID,
            phase: .rollbackStarted,
            previousProfileID: journal.previousProfileID,
            targetProfileID: journal.targetProfileID,
            startedAt: journal.startedAt,
            updatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
        _ = try store.updateJournal(rollback)

        do {
            try await requireMutationGate(for: descriptor)
            guard let previousProfileID = originalRegistry.activeProfileID,
                  let previous = originalRegistry.profiles.first(where: { $0.id == previousProfileID }) else {
                throw LocalCLIDataProviderFailure.rollbackUnavailable
            }
            let previousCredential = try await validatedCredential(
                credentialStore.loadCredential(for: previous.id),
                expectedEmail: previous.email,
                descriptor: descriptor,
                refreshToken: true
            )
            try await requireMutationGate(for: descriptor)
            try credentialStore.saveCredential(previousCredential, for: previous.id)
            guard try credentialStore.loadCredential(for: previous.id) == previousCredential else {
                throw LocalCLIDataProviderFailure.credentialRoundTripFailed
            }
            try await requireMutationGate(for: descriptor)
            let current = try files.snapshot(at: activeAuthURL)
            guard let expectedIdentity = capturedAuthIdentity ?? originalAuthIdentity,
                  case let .exact(currentIdentity) = current,
                  currentIdentity == expectedIdentity else {
                throw LocalCLIDataProviderFailure.activeAuthChanged
            }
            _ = try files.replace(
                contents: SensitiveBytes(CredentialBlob.persistenceData(for: previousCredential)),
                at: activeAuthURL,
                expecting: .exact(currentIdentity)
            )
            let restoredIdentity = try await verifyActiveCredential(
                expectedEmail: previous.email,
                descriptor: descriptor
            )
            try await requireMutationGate(for: descriptor)
            guard try files.snapshot(at: activeAuthURL) == .exact(restoredIdentity) else {
                throw LocalCLIDataProviderFailure.activeAuthChanged
            }

            let currentRegistry = try store.loadRegistry()
            if currentRegistry != originalRegistry {
                guard currentRegistry.activeProfileID == captureProfileID,
                      currentRegistry.profiles.count == originalRegistry.profiles.count + 1,
                      Array(currentRegistry.profiles.dropLast()) == originalRegistry.profiles,
                      currentRegistry.profiles.last?.id == captureProfileID else {
                    throw LocalCLIDataProviderFailure.rollbackUnavailable
                }
                let restored = try ProfileRegistry(
                    activeProfileID: previous.id,
                    profiles: currentRegistry.profiles
                )
                _ = try store.saveRegistry(restored)
                guard try store.loadRegistry() == restored else {
                    throw LocalCLIDataProviderFailure.registryRoundTripFailed
                }
            } else {
                try credentialStore.removeCredential(for: captureProfileID)
            }
            _ = try store.removeCaptureProfileID()
            try finalizeJournal(
                in: store,
                expectedActiveProfileID: previous.id,
                expectedActiveAuthIdentity: restoredIdentity
            )
        } catch {
            let failed = SwitchJournalRecord(
                transactionID: rollback.transactionID,
                phase: .rollbackFailed,
                previousProfileID: rollback.previousProfileID,
                targetProfileID: rollback.targetProfileID,
                startedAt: rollback.startedAt,
                updatedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            )
            do {
                _ = try store.updateJournal(failed)
            } catch {
                if mutationOutcomeIsUncertain(error) {
                    captureMutationUncertain = true
                }
            }
            throw error
        }
    }

    func openStoreIfPresent() throws -> SpikeStore? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }
        return try SpikeStore.openExisting(at: storeURL)
    }

    func recoverPendingProfileRemoval() throws -> Bool {
        guard !switchInProgress else {
            throw LocalCLIDataProviderFailure.switchAlreadyRunning
        }
        guard let store = try openStoreIfPresent() else { return false }
        guard let lock = try store.tryAcquireTransactionLock() else {
            throw LocalCLIDataProviderFailure.lockBusy
        }
        defer { lock.release() }
        guard let removal = try store.loadProfileRemovalIfPresent() else { return false }
        guard try store.loadJournalIfPresent() == nil,
              try store.loadJournalFinalizationEvidenceIfPresent() == nil,
              try store.loadCaptureProfileIDIfPresent() == nil,
              try !verificationWorkspaceExists() else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        try finishProfileRemoval(removal, in: store)
        return true
    }

    func finishProfileRemoval(_ removal: ProfileRemovalRecord, in store: SpikeStore) throws {
        guard try store.loadProfileRemovalIfPresent() == removal else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        let registry = try store.loadRegistry()
        guard registry.activeProfileID == removal.expectedActiveProfileID,
              registry.activeProfileID != removal.profileID else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        try credentialStore.removeCredential(for: removal.profileID)
        if registry.profiles.contains(where: { $0.id == removal.profileID }) {
            let updated = try ProfileRegistry(
                activeProfileID: removal.expectedActiveProfileID,
                profiles: registry.profiles.filter { $0.id != removal.profileID }
            )
            _ = try store.saveRegistry(updated)
            guard try store.loadRegistry() == updated else {
                throw LocalCLIDataProviderFailure.registryRoundTripFailed
            }
        }
        guard try store.loadProfileRemovalIfPresent() == removal else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
        _ = try store.removeProfileRemoval()
        guard try store.loadProfileRemovalIfPresent() == nil else {
            throw LocalCLIDataProviderFailure.pendingRecovery
        }
    }

    func finalizeJournal(
        in store: SpikeStore,
        expectedActiveProfileID: ProfileID,
        expectedActiveAuthIdentity: FileIdentity
    ) throws {
        guard let journal = try store.loadJournalIfPresent() else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        let evidence = JournalFinalizationEvidence(
            transactionID: journal.transactionID,
            journalPhase: journal.phase,
            expectedActiveProfileID: expectedActiveProfileID,
            expectedActiveAuthSHA256: expectedActiveAuthIdentity.sha256.description
        )
        guard journalMatchesFinalizationEvidence(journal, evidence: evidence),
              try finalizationStateMatches(
                  evidence,
                  in: store,
                  expectedActiveAuthIdentity: expectedActiveAuthIdentity
              ) else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        if let existing = try store.loadJournalFinalizationEvidenceIfPresent() {
            guard existing == evidence else {
                throw LocalCLIDataProviderFailure.pendingRecovery
            }
        } else {
            _ = try store.createJournalFinalizationEvidence(evidence)
        }
        guard try store.loadJournalFinalizationEvidenceIfPresent() == evidence,
              try finalizationStateMatches(
                  evidence,
                  in: store,
                  expectedActiveAuthIdentity: expectedActiveAuthIdentity
              ) else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        _ = try removeJournalFile()
        guard try store.loadJournalIfPresent() == nil,
              try store.loadJournalFinalizationEvidenceIfPresent() == evidence,
              try finalizationStateMatches(
                  evidence,
                  in: store,
                  expectedActiveAuthIdentity: expectedActiveAuthIdentity
              ) else {
            throw LocalCLIDataProviderFailure.activeAuthChanged
        }
        _ = try store.removeJournalFinalizationEvidence()
    }

    func journalIsDurablyAbsent(in store: SpikeStore) throws -> Bool {
        guard try store.loadProfileRemovalIfPresent() == nil else { return false }
        let journal = try store.loadJournalIfPresent()
        guard let evidence = try store.loadJournalFinalizationEvidenceIfPresent() else {
            guard journal == nil else { return false }
            do {
                try syncStoreDirectory()
                return true
            } catch {
                return false
            }
        }

        guard journal.map({ journalMatchesFinalizationEvidence($0, evidence: evidence) }) ?? true,
              try finalizationStateMatches(evidence, in: store) else {
            return false
        }
        do {
            if journal == nil {
                try syncStoreDirectory()
            } else {
                _ = try removeJournalFile()
                guard try store.loadJournalIfPresent() == nil else { return false }
            }
            guard try store.loadJournalFinalizationEvidenceIfPresent() == evidence,
                  try finalizationStateMatches(evidence, in: store) else {
                return false
            }
            _ = try store.removeJournalFinalizationEvidence()
            return true
        } catch {
            return false
        }
    }

    func journalMatchesFinalizationEvidence(
        _ journal: SwitchJournalRecord,
        evidence: JournalFinalizationEvidence
    ) -> Bool {
        let expectedProfileID = journal.phase == .targetVerified
            ? journal.targetProfileID
            : journal.previousProfileID
        let phaseMatches = journal.phase == evidence.journalPhase
            || (journal.phase == .rollbackFailed && evidence.journalPhase == .rollbackStarted)
        return journal.transactionID == evidence.transactionID
            && phaseMatches
            && expectedProfileID == evidence.expectedActiveProfileID
    }

    func finalizationStateMatches(
        _ evidence: JournalFinalizationEvidence,
        in store: SpikeStore,
        expectedActiveAuthIdentity: FileIdentity? = nil
    ) throws -> Bool {
        let registry = try store.loadRegistry()
        guard registry.activeProfileID == evidence.expectedActiveProfileID,
              registry.profiles.contains(where: {
                  $0.id == evidence.expectedActiveProfileID && !$0.needsRelogin
              }),
              try store.loadProfileRemovalIfPresent() == nil,
              try store.loadCaptureProfileIDIfPresent() == nil,
              try !verificationWorkspaceExists(),
              case let .exact(activeIdentity) = try files.snapshot(at: activeAuthURL),
              expectedActiveAuthIdentity.map({ $0 == activeIdentity }) ?? true,
              activeIdentity.sha256.description == evidence.expectedActiveAuthSHA256 else {
            return false
        }
        if evidence.journalPhase != .preparing && evidence.journalPhase != .quitRequested {
            let current = try readCurrentCredential()
            guard current.identity == activeIdentity,
                  current.credential
                    == (try credentialStore.loadCredential(for: evidence.expectedActiveProfileID)) else {
                return false
            }
        }
        return try store.loadRegistry() == registry
            && store.loadProfileRemovalIfPresent() == nil
            && store.loadCaptureProfileIDIfPresent() == nil
            && !verificationWorkspaceExists()
            && files.snapshot(at: activeAuthURL) == .exact(activeIdentity)
    }

    func count(_ disposition: ProcessDisposition, in inventory: ProcessInventory) -> Int {
        inventory.processes.lazy.filter { $0.disposition == disposition }.count
    }
}
