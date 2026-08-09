import Foundation
import CodexAccountCore
import CodexSleepGuardCore

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
                let evidence = JournalFinalizationEvidence(
                    transactionID: journal.transactionID,
                    journalPhase: updatedJournal.phase,
                    expectedActiveProfileID: profileID,
                    expectedActiveAuthSHA256: String(repeating: "a", count: 64)
                )
                _ = try store.createJournalFinalizationEvidence(evidence)
                let loadedEvidence = try store.loadJournalFinalizationEvidenceIfPresent()
                let evidenceMode = try storeMode(
                    at: store.rootURL.appendingPathComponent("journal-finalization.json")
                )
                try expect(loadedUpdatedJournal == updatedJournal, "existing journal was not updated")
                try expect(loadedEvidence == evidence, "journal finalization evidence changed")
                try expect(evidenceMode == 0o600, "journal finalization evidence mode is not 0600")

                _ = try store.removeJournal()
                _ = try store.removeJournalFinalizationEvidence()
                let removedJournal = try store.loadJournalIfPresent()
                let removedEvidence = try store.loadJournalFinalizationEvidenceIfPresent()
                try expect(removedJournal == nil, "journal remains after durable removal")
                try expect(removedEvidence == nil, "journal finalization evidence remains")
            }
        },
        TestCase("SpikeStore rejects malformed journal finalization evidence") {
            try withStoreTemporaryDirectory { parent in
                let store = try SpikeStore.create(
                    at: parent.appendingPathComponent("store", isDirectory: true)
                )
                let transactionID = UUID()
                let profileID = ProfileID(UUID())
                let evidenceURL = store.rootURL.appendingPathComponent(
                    "journal-finalization.json",
                    isDirectory: false
                )
                let malformedDigest = "g" + String(repeating: "a", count: 63)
                let malformedDigestDocument = Data(
                    """
                    {
                      "schemaVersion": 1,
                      "transactionId": "\(transactionID.uuidString)",
                      "journalPhase": "rollbackFailed",
                      "expectedActiveProfileId": "\(profileID)",
                      "expectedActiveAuthSha256": "\(malformedDigest)"
                    }
                    """.utf8
                )
                try malformedDigestDocument.write(to: evidenceURL, options: .withoutOverwriting)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: evidenceURL.path
                )

                try expectError(
                    SpikeStoreError.invalidJournalFinalizationEvidence,
                    "malformed journal finalization digest was accepted"
                ) {
                    _ = try store.loadJournalFinalizationEvidenceIfPresent()
                }

                let unknownFieldDocument = Data(
                    """
                    {
                      "schemaVersion": 1,
                      "transactionId": "\(transactionID.uuidString)",
                      "journalPhase": "rollbackFailed",
                      "expectedActiveProfileId": "\(profileID)",
                      "expectedActiveAuthSha256": "\(String(repeating: "a", count: 64))",
                      "unknown": true
                    }
                    """.utf8
                )
                try unknownFieldDocument.write(to: evidenceURL)

                try expectError(
                    SpikeStoreError.invalidJournalFinalizationEvidence,
                    "unknown journal finalization evidence field was accepted"
                ) {
                    _ = try store.loadJournalFinalizationEvidenceIfPresent()
                }
            }
        },
        TestCase("SpikeStore creates and removes a pending capture profile ID") {
            try withStoreTemporaryDirectory { parent in
                let root = parent.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: root)

                let first = try store.createCaptureProfileID()
                let loaded = try store.loadCaptureProfileIDIfPresent()
                let markerURL = root.appendingPathComponent("capture-profile-id", isDirectory: false)
                let markerMode = try storeMode(at: markerURL)

                try expect(loaded == first, "capture marker changed the profile ID")
                try expect(markerMode == 0o600, "capture marker mode is not 0600")

                _ = try store.removeCaptureProfileID()
                let removed = try store.loadCaptureProfileIDIfPresent()
                let next = try store.createCaptureProfileID()
                try expect(removed == nil, "capture marker remains")
                try expect(next != first, "completed capture reused its removed profile ID")
            }
        },
        TestCase("SpikeStore durably stores a strict sleep guard threshold") {
            guard let threshold = SleepGuardThreshold(rawValue: 99) else {
                throw TestFailure(description: "valid sleep guard threshold was rejected")
            }
            try withStoreTemporaryDirectory { parent in
                let root = parent.appendingPathComponent("store", isDirectory: true)
                let store = try SpikeStore.create(at: root)

                let missing = try store.loadSleepGuardThresholdIfPresent()
                try expect(
                    missing == nil,
                    "missing sleep guard threshold did not use the default path"
                )
                _ = try store.saveSleepGuardThreshold(threshold)
                let loaded = try store.loadSleepGuardThresholdIfPresent()
                try expect(
                    loaded == threshold,
                    "sleep guard threshold changed in storage"
                )
                let thresholdURL = root.appendingPathComponent("sleep-guard-threshold")
                let thresholdMode = try storeMode(at: thresholdURL)
                try expect(
                    thresholdMode == 0o600,
                    "sleep guard threshold mode is not 0600"
                )

                try Data("01\n".utf8).write(to: thresholdURL)
                try expectError(
                    SpikeStoreError.invalidSleepGuardThreshold,
                    "unsupported sleep guard threshold was accepted"
                ) {
                    _ = try store.loadSleepGuardThresholdIfPresent()
                }
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
