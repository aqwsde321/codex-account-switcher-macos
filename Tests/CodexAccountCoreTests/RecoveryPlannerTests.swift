import Foundation
import CodexAccountCore

func recoveryPlannerTests() -> [TestCase] {
    [
        TestCase("RecoveryPlanner permits forward commit only from targetVerified") {
            let previous = ProfileID(UUID())
            let target = ProfileID(UUID())
            let replaced = recoverySnapshot(
                phase: .authReplaced,
                activeCredential: .target,
                previous: previous,
                target: target
            )
            let verified = recoverySnapshot(
                phase: .targetVerified,
                activeCredential: .target,
                previous: previous,
                target: target
            )

            try expect(
                RecoveryPlanner.plan(replaced) == .restorePrevious,
                "authReplaced attempted forward recovery"
            )
            try expect(
                RecoveryPlanner.plan(verified) == .commitVerifiedTarget,
                "targetVerified did not permit target commit"
            )
        },
        TestCase("RecoveryPlanner stops for a live helper or unknown durability") {
            let previous = ProfileID(UUID())
            let target = ProfileID(UUID())
            let liveChild = RecoverySnapshot(
                journal: recoveryJournal(phase: .targetVerified, previous: previous, target: target),
                knownProfileIDs: [previous, target],
                registryActiveProfileID: previous,
                helperChildAlive: true,
                durabilityUnknown: false,
                activeCredential: .target
            )
            let unknown = RecoverySnapshot(
                journal: recoveryJournal(phase: .targetVerified, previous: previous, target: target),
                knownProfileIDs: [previous, target],
                registryActiveProfileID: previous,
                helperChildAlive: false,
                durabilityUnknown: true,
                activeCredential: .target
            )
            let processBlocker = RecoverySnapshot(
                journal: recoveryJournal(phase: .authReplaced, previous: previous, target: target),
                knownProfileIDs: [previous, target],
                registryActiveProfileID: previous,
                helperChildAlive: false,
                durabilityUnknown: false,
                activeCredential: .target,
                processBlockerPresent: true
            )

            try expect(RecoveryPlanner.plan(liveChild) == .stop(.helperChildAlive), "live helper was ignored")
            try expect(RecoveryPlanner.plan(unknown) == .stop(.durabilityUnknown), "unknown durability was guessed")
            try expect(
                RecoveryPlanner.plan(processBlocker) == .stop(.processBlockerPresent),
                "process blocker was ignored"
            )
        },
        TestCase("RecoveryPlanner resolves the targetValidated rename crash window from active identity") {
            let previous = ProfileID(UUID())
            let target = ProfileID(UUID())
            let sourceStillActive = recoverySnapshot(
                phase: .targetValidated,
                activeCredential: .previous,
                previous: previous,
                target: target
            )
            let targetAlreadyInstalled = recoverySnapshot(
                phase: .targetValidated,
                activeCredential: .target,
                previous: previous,
                target: target
            )
            let unreadable = recoverySnapshot(
                phase: .targetValidated,
                activeCredential: .unreadable,
                previous: previous,
                target: target
            )

            try expect(
                RecoveryPlanner.plan(sourceStillActive) == .cancelValidatedSource,
                "source-active rename window was not cancelled"
            )
            try expect(
                RecoveryPlanner.plan(targetAlreadyInstalled) == .restorePrevious,
                "target-active rename window did not roll back"
            )
            try expect(
                RecoveryPlanner.plan(unreadable) == .stop(.activeCredentialUnverified),
                "unreadable active auth was guessed"
            )
        },
        TestCase("RecoveryPlanner never commits targetVerified without active target evidence") {
            let previous = ProfileID(UUID())
            let target = ProfileID(UUID())
            let wrongActive = recoverySnapshot(
                phase: .targetVerified,
                activeCredential: .previous,
                previous: previous,
                target: target
            )

            try expect(
                RecoveryPlanner.plan(wrongActive) == .restorePrevious,
                "target was committed without active target evidence"
            )
        },
    ]
}

private func recoverySnapshot(
    phase: SwitchPhase,
    activeCredential: ActiveCredentialEvidence,
    previous: ProfileID,
    target: ProfileID
) -> RecoverySnapshot {
    RecoverySnapshot(
        journal: recoveryJournal(phase: phase, previous: previous, target: target),
        knownProfileIDs: [previous, target],
        registryActiveProfileID: previous,
        helperChildAlive: false,
        durabilityUnknown: false,
        activeCredential: activeCredential
    )
}

private func recoveryJournal(
    phase: SwitchPhase,
    previous: ProfileID,
    target: ProfileID
) -> SwitchJournalRecord {
    SwitchJournalRecord(
        transactionID: UUID(),
        phase: phase,
        previousProfileID: previous,
        targetProfileID: target,
        startedAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}
