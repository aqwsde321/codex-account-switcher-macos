import Foundation
import CodexAccountCore

func spikeStoreTests() -> [TestCase] {
    [
        TestCase("SpikeStore persists opaque credentials in private storage") {
            try withStoreTemporaryDirectory { parent in
                let root = parent.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: root)
                let profileID = ProfileID(UUID())
                let data = Data(
                    #"{"auth_mode":"chatgpt","tokens":{"id_token":"fixture-id","access_token":"fixture-access","refresh_token":"fixture-refresh"}}"#.utf8
                )
                let credential = try CredentialBlob(validating: data)

                _ = try store.saveCredential(credential, for: profileID)
                let loaded = try store.loadCredential(for: profileID)
                let credentialURL = root
                    .appendingPathComponent("credentials", isDirectory: true)
                    .appendingPathComponent("\(profileID).json")
                let rootMode = try storeMode(at: root)
                let credentialsMode = try storeMode(
                    at: root.appendingPathComponent("credentials", isDirectory: true)
                )
                let credentialMode = try storeMode(at: credentialURL)

                try expect(loaded == credential, "stored credential changed")
                try expect(rootMode == 0o700, "store root mode is not 0700")
                try expect(credentialsMode == 0o700, "credential directory mode is not 0700")
                try expect(credentialMode == 0o600, "credential mode is not 0600")
            }
        },
        TestCase("SpikeStore durably round-trips registry and strict journal") {
            try withStoreTemporaryDirectory { parent in
                let store = try SpikeStore.create(
                    at: parent.appendingPathComponent("store", isDirectory: true)
                )
                let profileID = ProfileID(UUID())
                let now = Date(timeIntervalSince1970: 1_700_000_000)
                let registry = try ProfileRegistry(
                    activeProfileID: profileID,
                    profiles: [
                        ProfileMetadata(
                            id: profileID,
                            label: "personal",
                            email: "person@example.invalid",
                            planType: nil,
                            needsRelogin: false,
                            createdAt: now,
                            updatedAt: now
                        ),
                    ]
                )
                let journal = SwitchJournalRecord(
                    transactionID: UUID(),
                    phase: .preparing,
                    previousProfileID: profileID,
                    targetProfileID: ProfileID(UUID()),
                    startedAt: now,
                    updatedAt: now
                )

                _ = try store.saveRegistry(registry)
                let created = try store.createJournalIfAbsent(journal)
                let loadedRegistry = try store.loadRegistry()
                let loadedJournal = try store.loadJournalIfPresent()

                try expect(created != nil, "initial journal was not created")
                try expect(loadedRegistry == registry, "registry changed in storage")
                try expect(loadedJournal == journal, "journal changed in storage")

                let duplicateCreate = try store.createJournalIfAbsent(journal)
                try expect(duplicateCreate == nil, "existing journal was overwritten")

                let foreignJournal = SwitchJournalRecord(
                    transactionID: UUID(),
                    phase: .quitRequested,
                    previousProfileID: journal.previousProfileID,
                    targetProfileID: journal.targetProfileID,
                    startedAt: journal.startedAt,
                    updatedAt: journal.updatedAt.addingTimeInterval(1)
                )
                try expectError(
                    SpikeStoreError.invalidJournalUpdate,
                    "foreign transaction replaced the journal"
                ) {
                    _ = try store.updateJournal(foreignJournal)
                }

                let skippedPhase = SwitchJournalRecord(
                    transactionID: journal.transactionID,
                    phase: .quiescent,
                    previousProfileID: journal.previousProfileID,
                    targetProfileID: journal.targetProfileID,
                    startedAt: journal.startedAt,
                    updatedAt: journal.updatedAt.addingTimeInterval(1)
                )
                try expectError(
                    SpikeStoreError.invalidJournalUpdate,
                    "non-adjacent phase replaced the journal"
                ) {
                    _ = try store.updateJournal(skippedPhase)
                }

                let updatedJournal = SwitchJournalRecord(
                    transactionID: journal.transactionID,
                    phase: .quitRequested,
                    previousProfileID: journal.previousProfileID,
                    targetProfileID: journal.targetProfileID,
                    startedAt: journal.startedAt,
                    updatedAt: journal.updatedAt.addingTimeInterval(1)
                )
                _ = try store.updateJournal(updatedJournal)
                let loadedUpdatedJournal = try store.loadJournalIfPresent()
                try expect(loadedUpdatedJournal == updatedJournal, "existing journal was not updated")

                _ = try store.removeJournal()
                let removedJournal = try store.loadJournalIfPresent()
                try expect(removedJournal == nil, "journal remains after durable removal")
            }
        },
    ]
}

private func withStoreTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func storeMode(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
