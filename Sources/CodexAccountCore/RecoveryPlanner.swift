public enum ActiveCredentialEvidence: Equatable, Sendable {
    case previous
    case previousCredentialChanged
    case target
    case other
    case unreadable
}

public struct RecoverySnapshot: Equatable, Sendable {
    public let journal: SwitchJournalRecord
    public let knownProfileIDs: Set<ProfileID>
    public let registryActiveProfileID: ProfileID
    public let helperChildAlive: Bool
    public let durabilityUnknown: Bool
    public let activeCredential: ActiveCredentialEvidence
    public let processBlockerPresent: Bool
    public let captureRecoveryPending: Bool

    public init(
        journal: SwitchJournalRecord,
        knownProfileIDs: Set<ProfileID>,
        registryActiveProfileID: ProfileID,
        helperChildAlive: Bool,
        durabilityUnknown: Bool,
        activeCredential: ActiveCredentialEvidence,
        processBlockerPresent: Bool = false,
        captureRecoveryPending: Bool = false
    ) {
        self.journal = journal
        self.knownProfileIDs = knownProfileIDs
        self.registryActiveProfileID = registryActiveProfileID
        self.helperChildAlive = helperChildAlive
        self.durabilityUnknown = durabilityUnknown
        self.activeCredential = activeCredential
        self.processBlockerPresent = processBlockerPresent
        self.captureRecoveryPending = captureRecoveryPending
    }
}

public enum RecoveryStopReason: Equatable, Sendable {
    case helperChildAlive
    case durabilityUnknown
    case invalidProfileReference
    case registryMismatch
    case rollbackPreviouslyFailed
    case activeCredentialUnverified
    case processBlockerPresent
}

public enum RecoveryAction: Equatable, Sendable {
    case cancelBeforeMutation
    case repairCurrentThenCancel
    case cancelValidatedSource
    case cancelTargetValidation
    case cleanupTargetThenRestorePrevious
    case restorePrevious
    case commitVerifiedTarget
    case resumeRollback
    case stop(RecoveryStopReason)
}

public enum RecoveryPlanner {
    public static func plan(_ snapshot: RecoverySnapshot) -> RecoveryAction {
        if snapshot.helperChildAlive {
            return .stop(.helperChildAlive)
        }
        if snapshot.durabilityUnknown {
            return .stop(.durabilityUnknown)
        }
        if snapshot.processBlockerPresent {
            return .stop(.processBlockerPresent)
        }

        let previous = snapshot.journal.previousProfileID
        let target = snapshot.journal.targetProfileID
        guard previous != target,
              snapshot.knownProfileIDs.contains(previous),
              snapshot.knownProfileIDs.contains(target) else {
            return .stop(.invalidProfileReference)
        }
        guard snapshot.registryActiveProfileID == previous
                || snapshot.registryActiveProfileID == target else {
            return .stop(.registryMismatch)
        }

        switch snapshot.journal.phase {
        case .preparing, .quitRequested:
            switch snapshot.activeCredential {
            case .previous, .previousCredentialChanged:
                return .cancelBeforeMutation
            case .target, .other, .unreadable:
                return .stop(.activeCredentialUnverified)
            }
        case .quiescent:
            return actionForPreviousOrRollback(
                snapshot.activeCredential,
                previousAction: .cancelBeforeMutation,
                changedPreviousAction: .repairCurrentThenCancel
            )
        case .refreshingCurrent:
            return .repairCurrentThenCancel
        case .currentSaved:
            return actionForPreviousOrRollback(snapshot.activeCredential, previousAction: .cancelValidatedSource)
        case .validatingTarget:
            switch snapshot.activeCredential {
            case .previous:
                return .cancelTargetValidation
            case .previousCredentialChanged:
                return .stop(.activeCredentialUnverified)
            case .target:
                return .cleanupTargetThenRestorePrevious
            case .other, .unreadable:
                return .stop(.activeCredentialUnverified)
            }
        case .targetValidated:
            if snapshot.captureRecoveryPending,
               snapshot.registryActiveProfileID == target,
               snapshot.activeCredential == .target {
                return .commitVerifiedTarget
            }
            return actionForPreviousOrRollback(snapshot.activeCredential, previousAction: .cancelValidatedSource)
        case .authReplaced, .targetLaunched, .verifyingTarget:
            return actionForKnownCredential(snapshot.activeCredential, action: .restorePrevious)
        case .targetVerified:
            switch snapshot.activeCredential {
            case .target:
                return .commitVerifiedTarget
            case .previous, .previousCredentialChanged:
                return .restorePrevious
            case .other, .unreadable:
                return .stop(.activeCredentialUnverified)
            }
        case .rollbackStarted:
            switch snapshot.activeCredential {
            case .previousCredentialChanged:
                return .repairCurrentThenCancel
            case .previous, .target:
                return .resumeRollback
            case .other, .unreadable:
                return .stop(.activeCredentialUnverified)
            }
        case .rollbackFailed:
            return snapshot.captureRecoveryPending
                && snapshot.activeCredential == .previousCredentialChanged
                ? .repairCurrentThenCancel
                : .stop(.rollbackPreviouslyFailed)
        }
    }

    private static func actionForPreviousOrRollback(
        _ evidence: ActiveCredentialEvidence,
        previousAction: RecoveryAction,
        changedPreviousAction: RecoveryAction = .stop(.activeCredentialUnverified)
    ) -> RecoveryAction {
        switch evidence {
        case .previous:
            return previousAction
        case .previousCredentialChanged:
            return changedPreviousAction
        case .target:
            return .restorePrevious
        case .other, .unreadable:
            return .stop(.activeCredentialUnverified)
        }
    }

    private static func actionForKnownCredential(
        _ evidence: ActiveCredentialEvidence,
        action: RecoveryAction
    ) -> RecoveryAction {
        switch evidence {
        case .previous, .previousCredentialChanged, .target:
            return action
        case .other, .unreadable:
            return .stop(.activeCredentialUnverified)
        }
    }
}
