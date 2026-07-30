import Foundation
import Security
import CodexAccountCore

func credentialStoreTests() -> [TestCase] {
    [
        TestCase("KeychainCredentialStore adds and round-trips a new credential") {
            let profileID = ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
            let fixture = try keychainCredentialFixture("new")
            let client = FakeGenericPasswordClient()
            let store = try KeychainCredentialStore(service: "dev.codex.account-switcher", client: client)

            try store.saveCredential(fixture.credential, for: profileID)
            let loaded = try store.loadCredential(for: profileID)

            let key = GenericPasswordKey(
                service: "dev.codex.account-switcher",
                account: profileID.description
            )
            try expect(loaded == fixture.credential, "new Keychain credential changed")
            try expect(
                client.calls == [.update(key), .add(key), .read(key)],
                "new credential did not use update-add-read"
            )
        },
        TestCase("KeychainCredentialStore updates an existing item without add") {
            let profileID = ProfileID(UUID())
            let oldFixture = try keychainCredentialFixture("old")
            let newFixture = try keychainCredentialFixture("updated")
            let client = FakeGenericPasswordClient(storedData: oldFixture.data)
            let store = try KeychainCredentialStore(service: "dev.codex.account-switcher", client: client)

            try store.saveCredential(newFixture.credential, for: profileID)

            try expect(client.storedData == newFixture.data, "existing Keychain item was not updated")
            try expect(client.calls.map(\.kind) == [.update], "existing item unexpectedly used add")
        },
        TestCase("KeychainCredentialStore retries update after an add race") {
            let profileID = ProfileID(UUID())
            let fixture = try keychainCredentialFixture("race")
            let client = FakeGenericPasswordClient(
                updateStatuses: [errSecItemNotFound, errSecSuccess],
                addStatuses: [errSecDuplicateItem]
            )
            let store = try KeychainCredentialStore(service: "dev.codex.account-switcher", client: client)

            try store.saveCredential(fixture.credential, for: profileID)

            try expect(client.storedData == fixture.data, "duplicate race retry did not store credential")
            try expect(
                client.calls.map(\.kind) == [.update, .add, .update],
                "duplicate race did not retry update exactly once"
            )
        },
        TestCase("KeychainCredentialStore reports missing reads and deletes idempotently") {
            let profileID = ProfileID(UUID())
            let client = FakeGenericPasswordClient()
            let store = try KeychainCredentialStore(service: "dev.codex.account-switcher", client: client)

            try expectError(CredentialStoreError.notFound, "missing Keychain item was accepted") {
                _ = try store.loadCredential(for: profileID)
            }
            try store.removeCredential(for: profileID)
            try store.removeCredential(for: profileID)

            try expect(
                client.calls.map(\.kind) == [.read, .delete, .delete],
                "missing delete was not idempotent"
            )
        },
        TestCase("KeychainCredentialStore rejects missing and invalid success data") {
            let profileID = ProfileID(UUID())
            let missingDataClient = FakeGenericPasswordClient(
                readResults: [(errSecSuccess, nil)]
            )
            let invalidDataClient = FakeGenericPasswordClient(
                readResults: [(errSecSuccess, Data("not-json".utf8))]
            )
            let missingDataStore = try KeychainCredentialStore(
                service: "dev.codex.account-switcher",
                client: missingDataClient
            )
            let invalidDataStore = try KeychainCredentialStore(
                service: "dev.codex.account-switcher",
                client: invalidDataClient
            )

            try expectError(CredentialStoreError.operationFailed, "success without data was accepted") {
                _ = try missingDataStore.loadCredential(for: profileID)
            }
            try expectError(CredentialStoreError.invalidCredential, "invalid credential data was accepted") {
                _ = try invalidDataStore.loadCredential(for: profileID)
            }
        },
        TestCase("KeychainCredentialStore maps safe errors and stops after an unexpected status") {
            let unexpected = OSStatus(-99_999)
            let fixture = try keychainCredentialFixture("failure")
            let client = FakeGenericPasswordClient(updateStatuses: [unexpected])
            let store = try KeychainCredentialStore(service: "dev.codex.account-switcher", client: client)

            try expectError(CredentialStoreError.invalidConfiguration, "empty Keychain service was accepted") {
                _ = try KeychainCredentialStore(service: " \n")
            }
            try expect(KeychainCredentialStore.error(for: errSecAuthFailed) == .accessDenied, "auth failure mapping changed")
            try expect(
                KeychainCredentialStore.error(for: errSecInteractionNotAllowed) == .unavailable,
                "locked Keychain mapping changed"
            )
            try expect(KeychainCredentialStore.error(for: unexpected) == .operationFailed, "unexpected status leaked")
            try expectError(CredentialStoreError.operationFailed, "unexpected update status was accepted") {
                try store.saveCredential(fixture.credential, for: ProfileID(UUID()))
            }
            try expect(client.calls.map(\.kind) == [.update], "save continued after unexpected update status")
        },
        TestCase("sync-active leaves files untouched when credential load fails") {
            try await withCredentialStoreTemporaryDirectory { directory in
                let root = directory.appendingPathComponent("store", isDirectory: true)
                let authURL = directory.appendingPathComponent("auth.json", isDirectory: false)
                let store = try SpikeStore.create(at: root)
                let profileID = ProfileID(UUID())
                let profile = ProfileMetadata(
                    id: profileID,
                    label: "personal",
                    email: "person@example.invalid",
                    planType: nil,
                    needsRelogin: false,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
                let registry = try ProfileRegistry(activeProfileID: profileID, profiles: [profile])
                let auth = try keychainCredentialFixture("active").data
                _ = try store.saveRegistry(registry)
                try auth.write(to: authURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

                let registryURL = root.appendingPathComponent("profiles.json", isDirectory: false)
                let registryBefore = try Data(contentsOf: registryURL)
                let markerBefore = try store.loadCaptureProfileIDIfPresent()
                let locateCalls = CredentialStoreCallCounter()
                let provider = LocalCLIDataProvider(
                    storeURL: root,
                    activeAuthURL: authURL,
                    credentialStore: FailingCredentialStore(error: .accessDenied),
                    processProvider: CredentialStoreEmptyProcessSnapshotProvider(),
                    locateApp: {
                        locateCalls.increment()
                        throw CredentialStoreTestFailure.locateAppCalled
                    },
                    runningApplicationPIDs: { _ in [] }
                )

                try await expectAsyncError(
                    CredentialStoreError.accessDenied,
                    "sync-active ignored credential load failure"
                ) {
                    _ = try await provider.syncActiveProfile()
                }

                let authAfter = try Data(contentsOf: authURL)
                let registryAfter = try Data(contentsOf: registryURL)
                let markerAfter = try store.loadCaptureProfileIDIfPresent()
                try expect(authAfter == auth, "credential failure changed active auth")
                try expect(registryAfter == registryBefore, "credential failure changed registry")
                try expect(
                    markerAfter == markerBefore,
                    "credential failure changed capture marker"
                )
                try expect(locateCalls.count == 0, "credential failure located the app before stopping")
            }
        },
    ]
}

private struct KeychainCredentialFixture {
    let data: Data
    let credential: CredentialBlob
}

private func keychainCredentialFixture(_ suffix: String) throws -> KeychainCredentialFixture {
    let data = Data(
        #"{"auth_mode":"chatgpt","tokens":{"id_token":"id-\#(suffix)","access_token":"access-\#(suffix)","refresh_token":"refresh-\#(suffix)"}}"#.utf8
    )
    return KeychainCredentialFixture(data: data, credential: try CredentialBlob(validating: data))
}

private enum GenericPasswordCallKind: Equatable {
    case read
    case update
    case add
    case delete
}

private enum GenericPasswordCall: Equatable {
    case read(GenericPasswordKey)
    case update(GenericPasswordKey)
    case add(GenericPasswordKey)
    case delete(GenericPasswordKey)

    var kind: GenericPasswordCallKind {
        switch self {
        case .read: .read
        case .update: .update
        case .add: .add
        case .delete: .delete
        }
    }
}

private final class FakeGenericPasswordClient: GenericPasswordClient, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var scriptedReads: [(OSStatus, Data?)]
    private var scriptedUpdates: [OSStatus]
    private var scriptedAdds: [OSStatus]
    private var recordedCalls = [GenericPasswordCall]()

    init(
        storedData: Data? = nil,
        readResults: [(OSStatus, Data?)] = [],
        updateStatuses: [OSStatus] = [],
        addStatuses: [OSStatus] = []
    ) {
        stored = storedData
        scriptedReads = readResults
        scriptedUpdates = updateStatuses
        scriptedAdds = addStatuses
    }

    var storedData: Data? {
        lock.withLock { stored }
    }

    var calls: [GenericPasswordCall] {
        lock.withLock { recordedCalls }
    }

    func read(_ key: GenericPasswordKey) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            recordedCalls.append(.read(key))
            if !scriptedReads.isEmpty {
                return scriptedReads.removeFirst()
            }
            guard let stored else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, stored)
        }
    }

    func update(_ data: Data, for key: GenericPasswordKey) -> OSStatus {
        lock.withLock {
            recordedCalls.append(.update(key))
            let status = scriptedUpdates.isEmpty
                ? (stored == nil ? errSecItemNotFound : errSecSuccess)
                : scriptedUpdates.removeFirst()
            if status == errSecSuccess {
                stored = data
            }
            return status
        }
    }

    func add(_ data: Data, for key: GenericPasswordKey) -> OSStatus {
        lock.withLock {
            recordedCalls.append(.add(key))
            let status = scriptedAdds.isEmpty
                ? (stored == nil ? errSecSuccess : errSecDuplicateItem)
                : scriptedAdds.removeFirst()
            if status == errSecSuccess {
                stored = data
            }
            return status
        }
    }

    func delete(_ key: GenericPasswordKey) -> OSStatus {
        lock.withLock {
            recordedCalls.append(.delete(key))
            guard stored != nil else { return errSecItemNotFound }
            stored = nil
            return errSecSuccess
        }
    }
}

private struct FailingCredentialStore: CredentialStoring {
    let error: CredentialStoreError

    func saveCredential(_ credential: CredentialBlob, for profileID: ProfileID) throws {
        throw error
    }

    func loadCredential(for profileID: ProfileID) throws -> CredentialBlob {
        throw error
    }

    func removeCredential(for profileID: ProfileID) throws {
        throw error
    }
}

private struct CredentialStoreEmptyProcessSnapshotProvider: ProcessSnapshotProviding {
    func snapshot() throws -> [ProcessRecord] { [] }
}

private final class CredentialStoreCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}

private enum CredentialStoreTestFailure: Error {
    case locateAppCalled
}

private func withCredentialStoreTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-credential-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}
