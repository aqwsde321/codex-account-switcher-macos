import Foundation

public protocol RecoveryExecuting: Sendable {
    func beginExclusiveRecovery() async throws -> Bool
    func endExclusiveRecovery() async
    func loadSnapshot() async throws -> RecoverySnapshot?
    func persistJournal(_ record: SwitchJournalRecord) async throws
    func cleanupTargetWorkspace() async throws
    func revalidateCredentialMutationGate() async throws
    func repairCurrentCredential(_ profileID: ProfileID) async throws
    func restorePreviousCredential(_ profileID: ProfileID) async throws
    func verifyPrevious(expectedProfileID: ProfileID) async throws
    func verifyTargetStillActive(expectedProfileID: ProfileID) async throws
    func commitActiveProfile(_ profileID: ProfileID) async throws
    func removeJournalDurably() async throws
    func launchPrevious() async throws
}

public enum RecoveryOutcome: Equatable, Sendable {
    case none
    case completed(RecoveryAction)
    case stopped(RecoveryStopReason)
}

public enum RecoveryCoordinatorFailure: Error, Equatable, Sendable {
    case recoveryInProgress
    case lockBusy
    case snapshotInvalid
    case executionFailed
    case rollbackFailed
}

public actor RecoveryCoordinator {
    private let executor: any RecoveryExecuting
    private let now: @Sendable () -> Date
    private var active = false

    public init(
        executor: any RecoveryExecuting,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.executor = executor
        self.now = now
    }

    public func recover(relaunchPrevious: Bool) async throws -> RecoveryOutcome {
        guard !active else {
            throw RecoveryCoordinatorFailure.recoveryInProgress
        }
        active = true

        do {
            guard try await executor.beginExclusiveRecovery() else {
                active = false
                throw RecoveryCoordinatorFailure.lockBusy
            }
        } catch let failure as RecoveryCoordinatorFailure {
            active = false
            throw failure
        } catch {
            active = false
            throw RecoveryCoordinatorFailure.executionFailed
        }

        do {
            guard let snapshot = try await executor.loadSnapshot() else {
                await executor.endExclusiveRecovery()
                active = false
                return .none
            }
            let action = RecoveryPlanner.plan(snapshot)
            let outcome = try await execute(
                action,
                snapshot: snapshot,
                relaunchPrevious: relaunchPrevious
            )
            await executor.endExclusiveRecovery()
            active = false
            return outcome
        } catch let failure as RecoveryCoordinatorFailure {
            await executor.endExclusiveRecovery()
            active = false
            throw failure
        } catch {
            await executor.endExclusiveRecovery()
            active = false
            throw RecoveryCoordinatorFailure.snapshotInvalid
        }
    }
}

private extension RecoveryCoordinator {
    func execute(
        _ action: RecoveryAction,
        snapshot: RecoverySnapshot,
        relaunchPrevious: Bool
    ) async throws -> RecoveryOutcome {
        switch action {
        case let .stop(reason):
            return .stopped(reason)

        case .commitVerifiedTarget:
            do {
                try await executor.verifyTargetStillActive(expectedProfileID: snapshot.journal.targetProfileID)
                try await executor.commitActiveProfile(snapshot.journal.targetProfileID)
                try await executor.removeJournalDurably()
                return .completed(action)
            } catch {
                throw RecoveryCoordinatorFailure.executionFailed
            }

        case .cancelBeforeMutation, .cancelValidatedSource:
            try await finishOnPrevious(snapshot, relaunchPrevious: relaunchPrevious)
            return .completed(action)

        case .cancelTargetValidation:
            do {
                try await executor.cleanupTargetWorkspace()
            } catch {
                throw RecoveryCoordinatorFailure.executionFailed
            }
            try await finishOnPrevious(snapshot, relaunchPrevious: relaunchPrevious)
            return .completed(action)

        case .cleanupTargetThenRestorePrevious:
            do {
                try await executor.cleanupTargetWorkspace()
            } catch {
                throw RecoveryCoordinatorFailure.executionFailed
            }
            try await persist(.rollbackStarted, for: snapshot.journal)
            try await restorePrevious(snapshot, relaunchPrevious: relaunchPrevious)
            return .completed(action)

        case .repairCurrentThenCancel:
            do {
                try await executor.revalidateCredentialMutationGate()
                try await executor.repairCurrentCredential(snapshot.journal.previousProfileID)
            } catch {
                throw RecoveryCoordinatorFailure.executionFailed
            }
            try await finishOnPrevious(snapshot, relaunchPrevious: relaunchPrevious)
            return .completed(action)

        case .restorePrevious:
            try await persist(.rollbackStarted, for: snapshot.journal)
            try await restorePrevious(snapshot, relaunchPrevious: relaunchPrevious)
            return .completed(action)

        case .resumeRollback:
            try await restorePrevious(snapshot, relaunchPrevious: relaunchPrevious)
            return .completed(action)
        }
    }

    func finishOnPrevious(
        _ snapshot: RecoverySnapshot,
        relaunchPrevious: Bool
    ) async throws {
        do {
            try await executor.verifyPrevious(expectedProfileID: snapshot.journal.previousProfileID)
            try await executor.commitActiveProfile(snapshot.journal.previousProfileID)
            try await executor.removeJournalDurably()
            if relaunchPrevious {
                try await executor.launchPrevious()
            }
        } catch {
            throw RecoveryCoordinatorFailure.executionFailed
        }
    }

    func restorePrevious(
        _ snapshot: RecoverySnapshot,
        relaunchPrevious: Bool
    ) async throws {
        do {
            try await executor.revalidateCredentialMutationGate()
            try await executor.restorePreviousCredential(snapshot.journal.previousProfileID)
            try await executor.verifyPrevious(expectedProfileID: snapshot.journal.previousProfileID)
            try await executor.commitActiveProfile(snapshot.journal.previousProfileID)
        } catch {
            try? await persist(.rollbackFailed, for: snapshot.journal)
            throw RecoveryCoordinatorFailure.rollbackFailed
        }

        do {
            try await executor.removeJournalDurably()
        } catch {
            throw RecoveryCoordinatorFailure.executionFailed
        }

        if relaunchPrevious {
            do {
                try await executor.launchPrevious()
            } catch {
                throw RecoveryCoordinatorFailure.executionFailed
            }
        }
    }

    func persist(_ phase: SwitchPhase, for journal: SwitchJournalRecord) async throws {
        do {
            try await executor.persistJournal(
                SwitchJournalRecord(
                    transactionID: journal.transactionID,
                    phase: phase,
                    previousProfileID: journal.previousProfileID,
                    targetProfileID: journal.targetProfileID,
                    startedAt: journal.startedAt,
                    updatedAt: now()
                )
            )
        } catch {
            throw RecoveryCoordinatorFailure.executionFailed
        }
    }
}
