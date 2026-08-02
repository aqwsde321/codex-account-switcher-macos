import Foundation
import CodexAccountCore

func profileRemovalTests() -> [TestCase] {
    [
        TestCase("Local provider removes only an inactive profile") {
            try await withProfileRemovalTemporaryDirectory { directory in
                let fixture = try makeProfileRemovalFixture(in: directory)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    credentialStore: FileCredentialStore(rootURL: fixture.storeURL),
                    processProvider: ProfileRemovalEmptyProcessProvider()
                )

                let removed = try await provider.removeProfile(fixture.target.id)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registry = try store.loadRegistry()
                let activeAuth = try CredentialBlob(validating: Data(contentsOf: fixture.authURL))
                let storedSource = try store.loadCredential(for: fixture.source.id)

                try expect(removed.id == fixture.target.id, "another profile was removed")
                try expect(!removed.active, "removed profile was reported active")
                try expect(
                    registry.activeProfileID == fixture.source.id && registry.profiles == [fixture.source],
                    "inactive removal changed the active profile"
                )
                try expect(storedSource == fixture.sourceCredential, "inactive removal changed the active credential")
                try expect(activeAuth == fixture.sourceCredential, "inactive removal changed active auth")
                do {
                    _ = try store.loadCredential(for: fixture.target.id)
                    throw TestFailure(description: "removed credential remains readable")
                } catch is TestFailure {
                    throw TestFailure(description: "removed credential remains readable")
                } catch {}
            }
        },
        TestCase("Local provider rejects active profile removal without mutation") {
            try await withProfileRemovalTemporaryDirectory { directory in
                let fixture = try makeProfileRemovalFixture(in: directory)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    credentialStore: FileCredentialStore(rootURL: fixture.storeURL),
                    processProvider: ProfileRemovalEmptyProcessProvider()
                )
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let registryBefore = try store.loadRegistry()
                let authBefore = try Data(contentsOf: fixture.authURL)

                try await expectAsyncError(
                    LocalCLIDataProviderFailure.activeProfileRemovalForbidden,
                    "active profile removal was accepted"
                ) {
                    _ = try await provider.removeProfile(fixture.source.id)
                }

                let registryAfter = try store.loadRegistry()
                let authAfter = try Data(contentsOf: fixture.authURL)
                let sourceAfter = try store.loadCredential(for: fixture.source.id)
                let targetAfter = try store.loadCredential(for: fixture.target.id)
                try expect(registryAfter == registryBefore, "active removal changed registry")
                try expect(authAfter == authBefore, "active removal changed auth")
                try expect(sourceAfter == fixture.sourceCredential, "active removal changed active credential")
                try expect(targetAfter == fixture.targetCredential, "active removal changed inactive credential")
            }
        },
        TestCase("Automatic recovery completes an interrupted profile removal") {
            try await withProfileRemovalTemporaryDirectory { directory in
                let fixture = try makeProfileRemovalFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let record = ProfileRemovalRecord(
                    transactionID: UUID(),
                    profileID: fixture.target.id,
                    expectedActiveProfileID: fixture.source.id
                )
                _ = try store.createProfileRemovalIfAbsent(record)
                _ = try store.removeCredential(for: fixture.target.id)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    credentialStore: FileCredentialStore(rootURL: fixture.storeURL),
                    processProvider: ProfileRemovalEmptyProcessProvider()
                )

                let outcome = try await provider.recoverPendingTransaction()
                let registry = try store.loadRegistry()
                let remainingRecord = try store.loadProfileRemovalIfPresent()

                try expect(outcome == .none, "profile removal created switch recovery work")
                try expect(
                    registry.activeProfileID == fixture.source.id && registry.profiles == [fixture.source],
                    "interrupted removal did not preserve the active profile"
                )
                try expect(remainingRecord == nil, "completed removal left its marker")
                do {
                    _ = try store.loadCredential(for: fixture.target.id)
                    throw TestFailure(description: "recovered removal left target credential")
                } catch is TestFailure {
                    throw TestFailure(description: "recovered removal left target credential")
                } catch {}
            }
        },
        TestCase("Credential denial preserves removal recovery and retries safely") {
            try await withProfileRemovalTemporaryDirectory { directory in
                let fixture = try makeProfileRemovalFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let deniedProvider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    credentialStore: RemovalDeniedCredentialStore(
                        backing: FileCredentialStore(rootURL: fixture.storeURL)
                    ),
                    processProvider: ProfileRemovalEmptyProcessProvider()
                )

                try await expectAsyncError(
                    CredentialStoreError.accessDenied,
                    "credential denial was hidden"
                ) {
                    _ = try await deniedProvider.removeProfile(fixture.target.id)
                }

                let pendingRemoval = try store.loadProfileRemovalIfPresent()
                let registryAfterDenial = try store.loadRegistry()
                let credentialAfterDenial = try store.loadCredential(for: fixture.target.id)
                try expect(
                    pendingRemoval?.profileID == fixture.target.id,
                    "credential denial discarded removal recovery"
                )
                try expect(
                    registryAfterDenial.profiles == [fixture.source, fixture.target],
                    "credential denial removed the registry entry"
                )
                try expect(
                    credentialAfterDenial == fixture.targetCredential,
                    "credential denial removed the target credential"
                )

                let restarted = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    credentialStore: FileCredentialStore(rootURL: fixture.storeURL),
                    processProvider: ProfileRemovalEmptyProcessProvider()
                )
                _ = try await restarted.recoverPendingTransaction()

                let completedRemoval = try store.loadProfileRemovalIfPresent()
                let registryAfterRetry = try store.loadRegistry()
                try expect(
                    completedRemoval == nil,
                    "successful retry left removal recovery"
                )
                try expect(
                    registryAfterRetry.profiles == [fixture.source],
                    "successful retry left the removed profile"
                )
            }
        },
        TestCase("Conflicting removal and switch recovery stops without mutation") {
            try await withProfileRemovalTemporaryDirectory { directory in
                let fixture = try makeProfileRemovalFixture(in: directory)
                let store = try SpikeStore.openExisting(at: fixture.storeURL)
                let journal = SwitchJournalRecord(
                    transactionID: UUID(),
                    phase: .rollbackFailed,
                    previousProfileID: fixture.source.id,
                    targetProfileID: fixture.target.id,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_002),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_003)
                )
                let removal = ProfileRemovalRecord(
                    transactionID: UUID(),
                    profileID: fixture.target.id,
                    expectedActiveProfileID: fixture.source.id
                )
                _ = try store.createJournalIfAbsent(journal)
                _ = try store.createProfileRemovalIfAbsent(removal)
                let registryBefore = try store.loadRegistry()
                let authBefore = try Data(contentsOf: fixture.authURL)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.authURL,
                    processProvider: ProfileRemovalEmptyProcessProvider(),
                    locateApp: {
                        throw TestFailure(description: "conflicting recovery located the app")
                    },
                    runningApplicationPIDs: { _ in [] }
                )

                let acquired = try await provider.beginExclusiveRecovery()
                try expect(acquired, "conflicting recovery did not acquire its test lock")
                try await expectAsyncError(
                    LocalCLIDataProviderFailure.pendingRecovery,
                    "switch recovery accepted a concurrent removal marker"
                ) {
                    _ = try await provider.loadSnapshot()
                }
                await provider.endExclusiveRecovery()

                try await expectAsyncError(
                    LocalCLIDataProviderFailure.manualRecoveryUnavailable,
                    "manual restore accepted a concurrent removal marker"
                ) {
                    _ = try await provider.restoreRecoveryProfile(
                        target: fixture.source.label,
                        expectedTransactionID: journal.transactionID.uuidString
                    )
                }

                let registryAfter = try store.loadRegistry()
                let authAfter = try Data(contentsOf: fixture.authURL)
                let journalAfter = try store.loadJournalIfPresent()
                let removalAfter = try store.loadProfileRemovalIfPresent()
                try expect(registryAfter == registryBefore, "conflicting recovery changed registry")
                try expect(authAfter == authBefore, "conflicting recovery changed active auth")
                try expect(
                    journalAfter == journal,
                    "conflicting recovery changed the switch journal"
                )
                try expect(
                    removalAfter == removal,
                    "conflicting recovery changed the removal marker"
                )
            }
        },
    ]
}

private struct ProfileRemovalFixture {
    let storeURL: URL
    let authURL: URL
    let source: ProfileMetadata
    let target: ProfileMetadata
    let sourceCredential: CredentialBlob
    let targetCredential: CredentialBlob
}

private func makeProfileRemovalFixture(in directory: URL) throws -> ProfileRemovalFixture {
    let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexHome.path)
    let authURL = codexHome.appendingPathComponent("auth.json", isDirectory: false)
    let sourceData = Data(
        #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
    )
    try sourceData.write(to: authURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

    let storeURL = directory.appendingPathComponent("store", isDirectory: true)
    let store = try SpikeStore.create(at: storeURL)
    let source = removalProfile(label: "A", email: "a@example.invalid", timestamp: 1_700_000_000)
    let target = removalProfile(label: "B", email: "b@example.invalid", timestamp: 1_700_000_001)
    let sourceCredential = try CredentialBlob(validating: sourceData)
    let targetCredential = try CredentialBlob(validating: Data(
        #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
    ))
    _ = try store.saveCredential(sourceCredential, for: source.id)
    _ = try store.saveCredential(targetCredential, for: target.id)
    _ = try store.saveRegistry(ProfileRegistry(activeProfileID: source.id, profiles: [source, target]))
    return ProfileRemovalFixture(
        storeURL: storeURL,
        authURL: authURL,
        source: source,
        target: target,
        sourceCredential: sourceCredential,
        targetCredential: targetCredential
    )
}

private func removalProfile(label: String, email: String, timestamp: TimeInterval) -> ProfileMetadata {
    ProfileMetadata(
        id: ProfileID(UUID()),
        label: label,
        email: email,
        planType: "plus",
        needsRelogin: false,
        createdAt: Date(timeIntervalSince1970: timestamp),
        updatedAt: Date(timeIntervalSince1970: timestamp)
    )
}

private func withProfileRemovalTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-profile-removal-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private struct ProfileRemovalEmptyProcessProvider: ProcessSnapshotProviding {
    func snapshot() throws -> [ProcessRecord] { [] }
}

private struct RemovalDeniedCredentialStore: CredentialStoring {
    let backing: FileCredentialStore

    func saveCredential(_ credential: CredentialBlob, for profileID: ProfileID) throws {
        try backing.saveCredential(credential, for: profileID)
    }

    func loadCredential(for profileID: ProfileID) throws -> CredentialBlob {
        try backing.loadCredential(for: profileID)
    }

    func removeCredential(for profileID: ProfileID) throws {
        throw CredentialStoreError.accessDenied
    }
}
