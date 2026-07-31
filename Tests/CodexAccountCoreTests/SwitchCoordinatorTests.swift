import Foundation
import CodexAccountCore

func switchCoordinatorTests() -> [TestCase] {
    [
        TestCase("SwitchCoordinator emits each durable canonical phase before its side effect") {
            let driver = RecordingSwitchDriver()
            let coordinator = SwitchCoordinator(
                driver: driver,
                onPhaseChange: { phase in await driver.recordPhase(phase) },
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            )
            let request = switchRequest()

            let outcome = try await coordinator.switchAccount(request)
            let events = await driver.events
            let phases = await driver.phases

            try expect(outcome == .switched, "switch did not complete")
            try expect(
                phases == SwitchStateMachine.canonicalPhases,
                "emitted phases differ from the canonical order"
            )
            try expect(
                events == [
                    "lock",
                    "recoveryGate",
                    "journal:preparing", "phase:preparing", "validate",
                    "journal:quitRequested", "phase:quitRequested", "quit", "quiescent",
                    "journal:quiescent", "phase:quiescent", "verifySource",
                    "journal:refreshingCurrent", "phase:refreshingCurrent", "mutationGate", "refreshCurrent",
                    "journal:currentSaved", "phase:currentSaved",
                    "journal:validatingTarget", "phase:validatingTarget", "validateTarget",
                    "journal:targetValidated", "phase:targetValidated", "mutationGate", "replaceAuth",
                    "journal:authReplaced", "phase:authReplaced", "launchTarget",
                    "journal:targetLaunched", "phase:targetLaunched",
                    "journal:verifyingTarget", "phase:verifyingTarget", "verifyTarget",
                    "journal:targetVerified", "phase:targetVerified", "commit", "removeJournal",
                    "unlock",
                ],
                "switch event order differs from durable phase contract"
            )
        },
        TestCase("SwitchCoordinator preserves the trailing now closure API") {
            let driver = RecordingSwitchDriver()
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_123)
            let coordinator = SwitchCoordinator(driver: driver) { fixedDate }

            _ = try await coordinator.switchAccount(switchRequest())

            let journalDates = await driver.journalDates
            let phases = await driver.phases
            try expect(
                !journalDates.isEmpty && journalDates.allSatisfy { $0 == fixedDate },
                "trailing closure no longer supplies deterministic journal timestamps"
            )
            try expect(phases.isEmpty, "trailing now closure was treated as a phase callback")
        },
        TestCase("SwitchCoordinator never emits a phase for a failed journal write") {
            for (failurePoint, expectedPhases) in [
                ("journal:preparing", [SwitchPhase]()),
                ("journal:quitRequested", [.preparing]),
            ] {
                let driver = RecordingSwitchDriver(failAt: failurePoint)
                let coordinator = SwitchCoordinator(
                    driver: driver,
                    onPhaseChange: { phase in await driver.recordPhase(phase) }
                )

                do {
                    _ = try await coordinator.switchAccount(switchRequest())
                    throw TestFailure(description: "failed journal write completed")
                } catch let failure as SwitchCoordinatorFailure {
                    try expect(failure == .operationFailed, "journal write failure returned the wrong status")
                }

                let phases = await driver.phases
                try expect(phases == expectedPhases, "failed journal phase was emitted")
            }
        },
        TestCase("SwitchCoordinator rolls back in the documented order after active replacement") {
            let driver = RecordingSwitchDriver(failAt: "verifyTarget")
            let coordinator = SwitchCoordinator(
                driver: driver,
                onPhaseChange: { phase in await driver.recordPhase(phase) }
            )

            do {
                _ = try await coordinator.switchAccount(switchRequest())
                throw TestFailure(description: "failed target verification completed")
            } catch let failure as SwitchCoordinatorFailure {
                try expect(failure == .operationFailed, "successful rollback returned wrong status")
            }

            let events = await driver.events
            let phases = await driver.phases
            try expect(
                phases == Array(SwitchStateMachine.canonicalPhases.dropLast()) + [.rollbackStarted],
                "rollback phase sequence differs from the durable journal order"
            )
            guard let rollbackIndex = events.firstIndex(of: "journal:rollbackStarted") else {
                throw TestFailure(description: "rollbackStarted was not persisted")
            }
            let rollbackTail = Array(events[rollbackIndex...])
            try expect(
                rollbackTail == [
                    "journal:rollbackStarted", "phase:rollbackStarted", "quit", "quiescent", "mutationGate",
                    "restorePrevious", "verifyPrevious",
                    "mutationGate", "commit", "removeJournal", "launchPrevious", "unlock",
                ],
                "rollback order differs from restore→verify→commit→delete→launch"
            )
        },
        TestCase("SwitchCoordinator does not report rollback failure after durable recovery") {
            let driver = RecordingSwitchDriver(
                failAt: "verifyTarget",
                failDuringRollbackAt: "launchPrevious"
            )
            let coordinator = SwitchCoordinator(driver: driver)

            do {
                _ = try await coordinator.switchAccount(switchRequest())
                throw TestFailure(description: "failed target verification completed")
            } catch let failure as SwitchCoordinatorFailure {
                try expect(failure == .operationFailed, "post-recovery launch failure became rollback failure")
            }

            let events = await driver.events
            try expect(events.contains("removeJournal"), "durable recovery did not remove the journal")
            try expect(events.contains("launchPrevious"), "previous launch was not attempted")
            try expect(!events.contains("journal:rollbackFailed"), "completed recovery was marked rollbackFailed")
        },
        TestCase("SwitchCoordinator preserves recovery evidence after quiescent source mismatch") {
            let driver = RecordingSwitchDriver(failAt: "verifySource")
            let coordinator = SwitchCoordinator(driver: driver)

            do {
                _ = try await coordinator.switchAccount(switchRequest())
                throw TestFailure(description: "source mismatch completed")
            } catch let failure as SwitchCoordinatorFailure {
                try expect(failure == .recoveryRequired, "source mismatch did not require recovery")
            }

            let events = await driver.events
            try expect(!events.contains("removeJournal"), "source mismatch deleted recovery evidence")
            try expect(!events.contains("launchPrevious"), "source mismatch launched an unverified account")
        },
        TestCase("SwitchCoordinator locks the already-active profile path") {
            let driver = RecordingSwitchDriver()
            let coordinator = SwitchCoordinator(
                driver: driver,
                onPhaseChange: { phase in await driver.recordPhase(phase) }
            )
            let request = switchRequest()
            let sameProfile = SwitchRequest(
                source: request.source,
                target: request.source,
                applicationWasRunning: true
            )

            let outcome = try await coordinator.switchAccount(sameProfile)
            let events = await driver.events
            let phases = await driver.phases

            try expect(outcome == .activatedExisting, "existing application was not activated")
            try expect(phases.isEmpty, "same-profile activation emitted a switch phase")
            try expect(
                events == ["lock", "recoveryGate", "activate", "unlock"],
                "same-profile path bypassed recovery gate"
            )
        },
        TestCase("SwitchCoordinator verifies and launches a closed active profile without auth mutation") {
            let driver = RecordingSwitchDriver()
            let coordinator = SwitchCoordinator(driver: driver)
            let request = switchRequest()
            let sameProfile = SwitchRequest(
                source: request.source,
                target: request.source,
                applicationWasRunning: false
            )

            let outcome = try await coordinator.switchAccount(sameProfile)
            let events = await driver.events

            try expect(outcome == .launchedExisting, "closed active profile was not launched")
            try expect(
                events == ["lock", "recoveryGate", "verifySource", "launchTarget", "unlock"],
                "closed same-profile path mutated switch state"
            )
        },
        TestCase("SwitchCoordinator never restores auth when rollback quiescence fails") {
            let driver = RecordingSwitchDriver(
                failAt: "verifyTarget",
                failDuringRollbackAt: "quiescent"
            )
            let coordinator = SwitchCoordinator(
                driver: driver,
                onPhaseChange: { phase in await driver.recordPhase(phase) }
            )

            do {
                _ = try await coordinator.switchAccount(switchRequest())
                throw TestFailure(description: "unsafe rollback completed")
            } catch let failure as SwitchCoordinatorFailure {
                try expect(failure == .rollbackFailed, "rollback gate failure returned the wrong status")
            }

            let events = await driver.events
            let phases = await driver.phases
            try expect(!events.contains("restorePrevious"), "auth was restored with a live writer")
            try expect(!events.contains("launchPrevious"), "previous app launched after rollback gate failure")
            try expect(events.contains("journal:rollbackFailed"), "rollback failure was not persisted")
            try expect(
                phases == Array(SwitchStateMachine.canonicalPhases.dropLast())
                    + [.rollbackStarted, .rollbackFailed],
                "rollback failure phases were not emitted in durable order"
            )
        },
        TestCase("SwitchCoordinator never overwrites a pending recovery journal") {
            let driver = RecordingSwitchDriver(pendingRecovery: true)
            let coordinator = SwitchCoordinator(driver: driver)

            do {
                _ = try await coordinator.switchAccount(switchRequest())
                throw TestFailure(description: "switch ignored pending recovery")
            } catch let failure as SwitchCoordinatorFailure {
                try expect(failure == .recoveryRequired, "pending recovery returned the wrong status")
            }

            let events = await driver.events
            try expect(events == ["lock", "recoveryGate", "unlock"], "pending journal was mutated")
        },
        TestCase("SwitchCoordinator preserves journal when target child exit is unconfirmed") {
            let driver = RecordingSwitchDriver(targetChildUnconfirmed: true)
            let coordinator = SwitchCoordinator(driver: driver)

            do {
                _ = try await coordinator.switchAccount(switchRequest())
                throw TestFailure(description: "unconfirmed target child was ignored")
            } catch let failure as SwitchCoordinatorFailure {
                try expect(failure == .recoveryRequired, "unconfirmed child returned the wrong status")
            }

            let events = await driver.events
            try expect(!events.contains("verifyPrevious"), "source verification ran with a live child")
            try expect(!events.contains("removeJournal"), "live child recovery evidence was deleted")
            try expect(!events.contains("launchPrevious"), "app launched with a live child")
        },
    ]
}

private actor RecordingSwitchDriver: SwitchTransactionDriving {
    private(set) var events = [String]()
    private(set) var phases = [SwitchPhase]()
    private(set) var journalDates = [Date]()
    private let failAt: String?
    private let failDuringRollbackAt: String?
    private let pendingRecovery: Bool
    private let targetChildUnconfirmed: Bool

    init(
        failAt: String? = nil,
        failDuringRollbackAt: String? = nil,
        pendingRecovery: Bool = false,
        targetChildUnconfirmed: Bool = false
    ) {
        self.failAt = failAt
        self.failDuringRollbackAt = failDuringRollbackAt
        self.pendingRecovery = pendingRecovery
        self.targetChildUnconfirmed = targetChildUnconfirmed
    }

    func beginExclusiveTransaction() async throws -> Bool {
        events.append("lock")
        return true
    }

    func endExclusiveTransaction() async {
        events.append("unlock")
    }

    func pendingRecoveryExists() async throws -> Bool {
        events.append("recoveryGate")
        return pendingRecovery
    }

    func createJournalIfAbsent(_ record: SwitchJournalRecord) async throws -> Bool {
        journalDates.append(record.updatedAt)
        try self.record("journal:\(record.phase.rawValue)")
        return true
    }

    func persistJournal(_ record: SwitchJournalRecord) async throws {
        journalDates.append(record.updatedAt)
        try self.record("journal:\(record.phase.rawValue)")
    }

    func recordPhase(_ phase: SwitchPhase) {
        phases.append(phase)
        events.append("phase:\(phase.rawValue)")
    }

    func validatePreparation(source: ProfileMetadata, target: ProfileMetadata) async throws {
        try record("validate")
    }

    func requestNormalQuit() async throws { try record("quit") }
    func waitForQuiescence() async throws { try record("quiescent") }
    func revalidateCredentialMutationGate() async throws { try record("mutationGate") }
    func verifyActiveSource(expectedEmail: String) async throws { try record("verifySource") }
    func refreshAndSaveCurrent(profile: ProfileMetadata) async throws { try record("refreshCurrent") }
    func validateAndSaveTarget(profile: ProfileMetadata) async throws {
        try record("validateTarget")
        if targetChildUnconfirmed {
            throw TargetValidationFailure.childStillAlive
        }
    }
    func replaceActiveAuth(with profileID: ProfileID) async throws { try record("replaceAuth") }
    func launchTarget() async throws { try record("launchTarget") }
    func verifyLaunchedTarget(expectedEmail: String) async throws { try record("verifyTarget") }
    func commitActiveProfile(_ profileID: ProfileID) async throws { try record("commit") }
    func removeJournalDurably() async throws { try record("removeJournal") }
    func activateExistingApplication() async throws { try record("activate") }
    func restorePreviousCredential(_ profileID: ProfileID) async throws { try record("restorePrevious") }
    func verifyPrevious(expectedEmail: String) async throws { try record("verifyPrevious") }
    func launchPrevious() async throws { try record("launchPrevious") }

    private func record(_ event: String) throws {
        events.append(event)
        if failAt == event {
            throw RecordingDriverFailure.injected
        }
        if failDuringRollbackAt == event,
           events.contains("journal:rollbackStarted") {
            throw RecordingDriverFailure.injected
        }
    }
}

private enum RecordingDriverFailure: Error {
    case injected
}

private func switchRequest() -> SwitchRequest {
    let now = Date(timeIntervalSince1970: 0)
    return SwitchRequest(
        source: ProfileMetadata(
            id: ProfileID(UUID()),
            label: "source",
            email: "source@example.invalid",
            planType: nil,
            needsRelogin: false,
            createdAt: now,
            updatedAt: now
        ),
        target: ProfileMetadata(
            id: ProfileID(UUID()),
            label: "target",
            email: "target@example.invalid",
            planType: nil,
            needsRelogin: false,
            createdAt: now,
            updatedAt: now
        ),
        applicationWasRunning: true
    )
}
