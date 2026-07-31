import Foundation
import CodexAccountCore

func recoveryCoordinatorTests() -> [TestCase] {
    [
        TestCase("RecoveryCoordinator commits target only from targetVerified") {
            let snapshot = recoveryCoordinatorSnapshot(phase: .targetVerified)
            let executor = RecordingRecoveryExecutor(snapshot: snapshot)
            let coordinator = RecoveryCoordinator(executor: executor)

            let outcome = try await coordinator.recover(relaunchPrevious: true)
            let events = await executor.events

            try expect(outcome == .completed(.commitVerifiedTarget), "verified target was not completed")
            try expect(
                events == ["lock", "snapshot", "verifyTarget", "commitTarget", "removeJournal", "unlock"],
                "target commit recovery performed extra effects"
            )
        },
        TestCase("RecoveryCoordinator rolls back when target verification changes") {
            let snapshot = recoveryCoordinatorSnapshot(phase: .targetVerified)
            let executor = RecordingRecoveryExecutor(
                snapshot: snapshot,
                failTargetVerification: true
            )
            let coordinator = RecoveryCoordinator(executor: executor)

            let outcome = try await coordinator.recover(relaunchPrevious: false)
            let events = await executor.events

            try expect(outcome == .completed(.restorePrevious), "target mismatch did not roll back")
            try expect(
                events == [
                    "lock", "snapshot", "verifyTarget", "mutationGate", "journal:rollbackStarted",
                    "mutationGate", "restorePrevious", "verifyPrevious", "commitPrevious",
                    "removeJournal", "unlock",
                ],
                "target mismatch recovery order changed"
            )
        },
        TestCase("RecoveryCoordinator restores previous before relaunch after auth replacement") {
            let snapshot = recoveryCoordinatorSnapshot(phase: .authReplaced)
            let executor = RecordingRecoveryExecutor(snapshot: snapshot)
            let coordinator = RecoveryCoordinator(executor: executor)

            _ = try await coordinator.recover(relaunchPrevious: true)
            let events = await executor.events

            try expect(
                events == [
                    "lock", "snapshot", "journal:rollbackStarted", "mutationGate", "restorePrevious",
                    "verifyPrevious", "commitPrevious", "removeJournal", "launchPrevious", "unlock",
                ],
                "recovery rollback order differs from the contract"
            )
        },
        TestCase("RecoveryCoordinator stops before auth restore when process gate fails") {
            let snapshot = recoveryCoordinatorSnapshot(phase: .authReplaced)
            let executor = RecordingRecoveryExecutor(snapshot: snapshot, failPrepare: true)
            let coordinator = RecoveryCoordinator(executor: executor)

            do {
                _ = try await coordinator.recover(relaunchPrevious: true)
                throw TestFailure(description: "unsafe recovery completed")
            } catch let failure as RecoveryCoordinatorFailure {
                try expect(failure == .rollbackFailed, "process gate failure returned the wrong status")
            }

            let events = await executor.events
            try expect(!events.contains("restorePrevious"), "recovery wrote auth with a live process")
            try expect(!events.contains("launchPrevious"), "recovery launched after process gate failure")
            try expect(events.contains("journal:rollbackFailed"), "recovery failure was not persisted")
        },
        TestCase("RecoveryCoordinator makes a failed current repair terminal") {
            let snapshot = recoveryCoordinatorSnapshot(phase: .refreshingCurrent)
            let executor = RecordingRecoveryExecutor(snapshot: snapshot, failPrepare: true)
            let coordinator = RecoveryCoordinator(executor: executor)

            do {
                _ = try await coordinator.recover(relaunchPrevious: false)
                throw TestFailure(description: "failed current repair was retried")
            } catch let failure as RecoveryCoordinatorFailure {
                try expect(failure == .rollbackFailed, "current repair returned the wrong failure")
            }

            let events = await executor.events
            try expect(
                events == [
                    "lock", "snapshot", "journal:rollbackStarted", "mutationGate",
                    "journal:rollbackFailed", "unlock",
                ],
                "current repair failure did not become terminal"
            )
        },
    ]
}

private actor RecordingRecoveryExecutor: RecoveryExecuting {
    private(set) var events = [String]()
    let snapshotValue: RecoverySnapshot?
    let failPrepare: Bool
    let failTargetVerification: Bool

    init(
        snapshot: RecoverySnapshot?,
        failPrepare: Bool = false,
        failTargetVerification: Bool = false
    ) {
        snapshotValue = snapshot
        self.failPrepare = failPrepare
        self.failTargetVerification = failTargetVerification
    }

    func beginExclusiveRecovery() async throws -> Bool { events.append("lock"); return true }
    func endExclusiveRecovery() async { events.append("unlock") }
    func loadSnapshot() async throws -> RecoverySnapshot? { events.append("snapshot"); return snapshotValue }
    func persistJournal(_ record: SwitchJournalRecord) async throws { events.append("journal:\(record.phase.rawValue)") }
    func cleanupTargetWorkspace() async throws { events.append("cleanupTarget") }
    func revalidateCredentialMutationGate() async throws {
        events.append("mutationGate")
        if failPrepare {
            throw RecordingRecoveryFailure.injected
        }
    }
    func repairCurrentCredential(_ profileID: ProfileID) async throws { events.append("repairCurrent") }
    func restorePreviousCredential(_ profileID: ProfileID) async throws { events.append("restorePrevious") }
    func verifyPrevious(expectedProfileID: ProfileID) async throws { events.append("verifyPrevious") }
    func verifyTargetStillActive(expectedProfileID: ProfileID) async throws {
        events.append("verifyTarget")
        if failTargetVerification {
            throw RecoveryTargetVerificationFailure.targetUnverified
        }
    }
    func commitActiveProfile(_ profileID: ProfileID) async throws {
        if profileID == snapshotValue?.journal.targetProfileID {
            events.append("commitTarget")
        } else {
            events.append("commitPrevious")
        }
    }
    func removeJournalDurably() async throws { events.append("removeJournal") }
    func launchPrevious() async throws { events.append("launchPrevious") }
}

private enum RecordingRecoveryFailure: Error {
    case injected
}

private func recoveryCoordinatorSnapshot(phase: SwitchPhase) -> RecoverySnapshot {
    let previous = ProfileID(UUID())
    let target = ProfileID(UUID())
    return RecoverySnapshot(
        journal: SwitchJournalRecord(
            transactionID: UUID(),
            phase: phase,
            previousProfileID: previous,
            targetProfileID: target,
            startedAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        ),
        knownProfileIDs: [previous, target],
        registryActiveProfileID: previous,
        helperChildAlive: false,
        durabilityUnknown: false,
        activeCredential: .target
    )
}
