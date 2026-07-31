import Foundation

public struct SwitchRequest: Equatable, Sendable {
    public let source: ProfileMetadata
    public let target: ProfileMetadata
    public let applicationWasRunning: Bool

    public init(
        source: ProfileMetadata,
        target: ProfileMetadata,
        applicationWasRunning: Bool
    ) {
        self.source = source
        self.target = target
        self.applicationWasRunning = applicationWasRunning
    }
}

public enum SwitchOutcome: Equatable, Sendable {
    case switched
    case activatedExisting
    case launchedExisting
}

public enum SwitchCoordinatorFailure: Error, Equatable, Sendable {
    case transactionInProgress
    case lockBusy
    case operationFailed
    case processBlocked
    case recoveryRequired
    case rollbackFailed
}

public protocol SwitchTransactionDriving: Sendable {
    func beginExclusiveTransaction() async throws -> Bool
    func endExclusiveTransaction() async
    func pendingRecoveryExists() async throws -> Bool
    func createJournalIfAbsent(_ record: SwitchJournalRecord) async throws -> Bool
    func persistJournal(_ record: SwitchJournalRecord) async throws
    func validatePreparation(source: ProfileMetadata, target: ProfileMetadata) async throws
    func requestNormalQuit() async throws
    func waitForQuiescence() async throws
    func revalidateCredentialMutationGate() async throws
    func verifyActiveSource(expectedEmail: String) async throws
    func refreshAndSaveCurrent(profile: ProfileMetadata) async throws
    func validateAndSaveTarget(profile: ProfileMetadata) async throws
    func replaceActiveAuth(with profileID: ProfileID) async throws
    func launchTarget() async throws
    func verifyLaunchedTarget(expectedEmail: String) async throws
    func commitActiveProfile(_ profileID: ProfileID) async throws
    func removeJournalDurably() async throws
    func activateExistingApplication() async throws
    func restorePreviousCredential(_ profileID: ProfileID) async throws
    func verifyPrevious(expectedEmail: String) async throws
    func launchPrevious() async throws
}

public actor SwitchCoordinator {
    private let driver: any SwitchTransactionDriving
    private let now: @Sendable () -> Date
    private let onPhaseChange: @Sendable (SwitchPhase) async -> Void
    private var activeTransactionID: UUID?

    public init(
        driver: any SwitchTransactionDriving,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.driver = driver
        self.now = now
        self.onPhaseChange = { _ in }
    }

    public init(
        driver: any SwitchTransactionDriving,
        onPhaseChange: @escaping @Sendable (SwitchPhase) async -> Void,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.driver = driver
        self.now = now
        self.onPhaseChange = onPhaseChange
    }

    public func switchAccount(_ request: SwitchRequest) async throws -> SwitchOutcome {
        guard activeTransactionID == nil else {
            throw SwitchCoordinatorFailure.transactionInProgress
        }

        let transactionID = UUID()
        activeTransactionID = transactionID

        do {
            guard try await driver.beginExclusiveTransaction() else {
                activeTransactionID = nil
                throw SwitchCoordinatorFailure.lockBusy
            }
        } catch let failure as SwitchCoordinatorFailure {
            activeTransactionID = nil
            throw failure
        } catch {
            activeTransactionID = nil
            throw SwitchCoordinatorFailure.operationFailed
        }

        let pendingRecovery: Bool
        do {
            pendingRecovery = try await driver.pendingRecoveryExists()
        } catch {
            await driver.endExclusiveTransaction()
            activeTransactionID = nil
            throw SwitchCoordinatorFailure.operationFailed
        }
        if pendingRecovery {
            await driver.endExclusiveTransaction()
            activeTransactionID = nil
            throw SwitchCoordinatorFailure.recoveryRequired
        }

        if request.source.id == request.target.id {
            do {
                let outcome: SwitchOutcome
                if request.applicationWasRunning {
                    try await driver.activateExistingApplication()
                    outcome = .activatedExisting
                } else {
                    try await driver.verifyActiveSource(expectedEmail: request.source.email)
                    try await driver.launchTarget()
                    outcome = .launchedExisting
                }
                await driver.endExclusiveTransaction()
                activeTransactionID = nil
                return outcome
            } catch {
                await driver.endExclusiveTransaction()
                activeTransactionID = nil
                throw operationFailure(from: error)
            }
        }

        let startedAt = now()
        let initialJournal = SwitchJournalRecord(
            transactionID: transactionID,
            phase: .preparing,
            previousProfileID: request.source.id,
            targetProfileID: request.target.id,
            startedAt: startedAt,
            updatedAt: now()
        )
        let journalCreated: Bool
        do {
            journalCreated = try await driver.createJournalIfAbsent(initialJournal)
        } catch {
            await driver.endExclusiveTransaction()
            activeTransactionID = nil
            throw SwitchCoordinatorFailure.operationFailed
        }
        if !journalCreated {
            await driver.endExclusiveTransaction()
            activeTransactionID = nil
            throw SwitchCoordinatorFailure.recoveryRequired
        }
        await onPhaseChange(.preparing)

        var phase: SwitchPhase? = .preparing
        do {
            try await driver.validatePreparation(source: request.source, target: request.target)

            try await persist(
                .quitRequested,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .quitRequested
            try await driver.requestNormalQuit()
            try await driver.waitForQuiescence()

            try await persist(
                .quiescent,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .quiescent
            try await driver.verifyActiveSource(expectedEmail: request.source.email)

            try await persist(
                .refreshingCurrent,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .refreshingCurrent
            try await driver.revalidateCredentialMutationGate()
            try await driver.refreshAndSaveCurrent(profile: request.source)

            try await persist(
                .currentSaved,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .currentSaved

            try await persist(
                .validatingTarget,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .validatingTarget
            try await driver.validateAndSaveTarget(profile: request.target)

            try await persist(
                .targetValidated,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .targetValidated
            try await driver.revalidateCredentialMutationGate()
            try await driver.replaceActiveAuth(with: request.target.id)

            try await persist(
                .authReplaced,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .authReplaced
            try await driver.launchTarget()

            try await persist(
                .targetLaunched,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .targetLaunched

            try await persist(
                .verifyingTarget,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .verifyingTarget
            try await driver.verifyLaunchedTarget(expectedEmail: request.target.email)

            try await persist(
                .targetVerified,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            phase = .targetVerified
            try await driver.commitActiveProfile(request.target.id)
            try await driver.removeJournalDurably()

            await driver.endExclusiveTransaction()
            activeTransactionID = nil
            return .switched
        } catch {
            let mapped = await recover(
                from: phase,
                cause: error,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            await driver.endExclusiveTransaction()
            activeTransactionID = nil
            throw mapped
        }
    }
}

private extension SwitchCoordinator {
    func persist(
        _ phase: SwitchPhase,
        transactionID: UUID,
        request: SwitchRequest,
        startedAt: Date
    ) async throws {
        try await driver.persistJournal(
            SwitchJournalRecord(
                transactionID: transactionID,
                phase: phase,
                previousProfileID: request.source.id,
                targetProfileID: request.target.id,
                startedAt: startedAt,
                updatedAt: now()
            )
        )
        await onPhaseChange(phase)
    }

    func recover(
        from phase: SwitchPhase?,
        cause: Error,
        transactionID: UUID,
        request: SwitchRequest,
        startedAt: Date
    ) async -> SwitchCoordinatorFailure {
        if processExitIsUnconfirmed(cause) {
            return .recoveryRequired
        }
        guard let phase else {
            return .operationFailed
        }

        switch phase {
        case .preparing, .quitRequested:
            do {
                try await driver.removeJournalDurably()
                return operationFailure(from: cause)
            } catch {
                return .recoveryRequired
            }

        case .quiescent:
            return .recoveryRequired

        case .currentSaved, .validatingTarget, .targetValidated:
            do {
                try await driver.verifyPrevious(expectedEmail: request.source.email)
                try await driver.revalidateCredentialMutationGate()
                try await driver.commitActiveProfile(request.source.id)
                try await driver.removeJournalDurably()
            } catch {
                return .recoveryRequired
            }
            if request.applicationWasRunning {
                try? await driver.launchPrevious()
            }
            return operationFailure(from: cause)

        case .targetVerified:
            return .recoveryRequired

        case .rollbackFailed:
            return .rollbackFailed

        case .refreshingCurrent, .authReplaced, .targetLaunched, .verifyingTarget, .rollbackStarted:
            return await rollback(
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
        }
    }

    func processExitIsUnconfirmed(_ error: Error) -> Bool {
        if let failure = error as? TargetValidationFailure {
            return failure == .childStillAlive
        }
        if let failure = error as? AppServerProbeFailure {
            return failure.childDisposition == .unconfirmed
        }
        return false
    }

    func operationFailure(from error: Error) -> SwitchCoordinatorFailure {
        guard let failure = error as? SwitchCoordinatorFailure,
              failure == .processBlocked else {
            return .operationFailed
        }
        return .processBlocked
    }

    func rollback(
        transactionID: UUID,
        request: SwitchRequest,
        startedAt: Date
    ) async -> SwitchCoordinatorFailure {
        do {
            try await persist(
                .rollbackStarted,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
        } catch {
            return .recoveryRequired
        }

        do {
            try await driver.requestNormalQuit()
            try await driver.waitForQuiescence()
            try await driver.revalidateCredentialMutationGate()
            try await driver.restorePreviousCredential(request.source.id)
            try await driver.verifyPrevious(expectedEmail: request.source.email)
            try await driver.revalidateCredentialMutationGate()
            try await driver.commitActiveProfile(request.source.id)
            try await driver.removeJournalDurably()
        } catch {
            try? await persist(
                .rollbackFailed,
                transactionID: transactionID,
                request: request,
                startedAt: startedAt
            )
            return .rollbackFailed
        }
        try? await driver.launchPrevious()
        return .operationFailed
    }
}
