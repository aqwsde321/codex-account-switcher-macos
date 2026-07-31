import Foundation
import CodexAccountCore
import CodexAccountMenuBarModel

func menuBarViewModelTests() -> [TestCase] {
    [
        TestCase("MenuBarViewModel loads three cards and confirms only inactive selection") {
            let provider = MenuBarProviderSpy(profiles: menuBarProfiles())
            let model = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await provider.profiles() },
                    loadRecoveryStatus: { await provider.recoveryStatus() },
                    captureProfile: { try await provider.captureProfile(label: $0) },
                    syncActiveProfile: { try await provider.syncActiveProfile() },
                    switchProfile: { try await provider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await provider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await provider.restoreRecoveryProfile(target: $0, expectedTransactionID: $1)
                    }
                )
            }

            await model.load()
            let loaded = await MainActor.run { model.profiles }
            try expect(loaded.count == 3, "menu bar did not load three profiles")
            try expect(loaded.filter(\.active).count == 1, "menu bar active card count changed")
            try expect(loaded.filter { !$0.active }.count == 2, "menu bar inactive card count changed")

            guard let active = loaded.first(where: \.active),
                  let inactive = loaded.first(where: { !$0.active }) else {
                throw TestFailure(description: "menu bar fixture has no selectable profiles")
            }
            await model.select(active)
            let targetsAfterActive = await provider.targets
            let eventsAfterActive = await provider.events
            let phasesAfterActive = await provider.switchPhases
            let mutationsAfterActive = await provider.mutationCount
            let pendingAfterActive = await MainActor.run { model.pendingProfile }
            try expect(targetsAfterActive == [active.id.description], "active selection did not reach Core once")
            try expect(eventsAfterActive == ["activate"], "running active selection did not only activate the app")
            try expect(phasesAfterActive.isEmpty, "active selection emitted switch phases")
            try expect(mutationsAfterActive == 0, "running active selection mutated account state")
            try expect(pendingAfterActive == nil, "active selection requested switch confirmation")

            await model.select(inactive)
            let targetsBeforeConfirmation = await provider.targets
            let phasesBeforeConfirmation = await provider.switchPhases
            let pendingBeforeConfirmation = await MainActor.run { model.pendingProfile }
            try expect(targetsBeforeConfirmation == targetsAfterActive, "inactive selection mutated before confirmation")
            try expect(phasesBeforeConfirmation.isEmpty, "inactive selection emitted progress before confirmation")
            try expect(pendingBeforeConfirmation?.id == inactive.id, "inactive confirmation target changed")

            await MainActor.run { model.cancelSwitch() }
            await model.confirmSwitch(pendingBeforeConfirmation)
            let targetsAfterConfirmation = await provider.targets
            let phasesAfterConfirmation = await provider.switchPhases
            let mutationsAfterConfirmation = await provider.mutationCount
            let finalProfiles = await MainActor.run { model.profiles }
            let finalSwitchPhase = await MainActor.run { model.switchPhase }
            try expect(
                targetsAfterConfirmation == [active.id.description, inactive.id.description],
                "confirmed inactive selection did not reach Core once"
            )
            try expect(mutationsAfterConfirmation == 1, "confirmed inactive selection mutation count changed")
            try expect(
                phasesAfterConfirmation == SwitchStateMachine.canonicalPhases,
                "confirmed switch did not forward canonical progress phases"
            )
            try expect(finalSwitchPhase == nil, "completed switch left stale progress visible")
            try expect(finalProfiles.first(where: { $0.id == inactive.id })?.active == true, "selected card did not become active")
            try expect(finalProfiles.filter(\.active).count == 1, "confirmation produced multiple active cards")

            let closedProvider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                applicationIsRunning: false
            )
            let closedModel = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await closedProvider.profiles() },
                    loadRecoveryStatus: { await closedProvider.recoveryStatus() },
                    captureProfile: { try await closedProvider.captureProfile(label: $0) },
                    syncActiveProfile: { try await closedProvider.syncActiveProfile() },
                    switchProfile: { try await closedProvider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await closedProvider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await closedProvider.restoreRecoveryProfile(target: $0, expectedTransactionID: $1)
                    }
                )
            }
            await closedModel.load()
            guard let closedActive = await MainActor.run(body: { closedModel.profiles.first(where: \.active) }) else {
                throw TestFailure(description: "closed-app fixture has no active profile")
            }
            await closedModel.select(closedActive)
            let closedEvents = await closedProvider.events
            let closedMutations = await closedProvider.mutationCount
            try expect(closedEvents == ["verify", "launch"], "closed active selection did not verify then launch")
            try expect(closedMutations == 0, "closed active selection mutated account state")

            let failureProvider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                switchFailureAfterProgress: true
            )
            let failureModel = await makeMenuBarModel(provider: failureProvider)
            await failureModel.load()
            guard let failingTarget = await MainActor.run(body: {
                failureModel.profiles.first(where: { !$0.active })
            }) else {
                throw TestFailure(description: "failure fixture has no inactive profile")
            }
            await failureModel.select(failingTarget)
            await failureModel.confirmSwitch()
            let failedSwitchPhase = await MainActor.run { failureModel.switchPhase }
            let failedSwitchMessage = await MainActor.run { failureModel.errorMessage }
            try expect(failedSwitchPhase == nil, "failed switch left stale progress visible")
            try expect(
                failedSwitchMessage == "계정 작업을 완료하지 못했습니다.",
                "failed switch did not replace progress with a safe error"
            )
        },
        TestCase("MenuBarViewModel maps durable switch phases to safe progress text") {
            let messages = await MainActor.run {
                SwitchPhase.allCases.map(MenuBarViewModel.switchProgressMessage(for:))
            }
            try expect(
                messages == [
                    "전환 준비 중…",
                    "Codex 앱 종료 및 프로세스 확인 중…",
                    "현재 계정 확인 중…",
                    "현재 계정 인증 갱신 중…",
                    "대상 계정 준비 중…",
                    "대상 계정 인증 확인 중…",
                    "대상 계정 인증 적용 중…",
                    "Codex 앱 실행 중…",
                    "대상 계정 확인 중…",
                    "대상 계정 확인 중…",
                    "전환 완료 처리 중…",
                    "문제가 발생해 이전 계정 복구 중…",
                    "자동 복구 실패. 앱을 열지 말고 복구하세요.",
                ],
                "switch phase progress text changed"
            )
        },
        TestCase("MenuBarViewModel registers the current login and reloads profiles") {
            let provider = MenuBarProviderSpy(profiles: [])
            let model = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await provider.profiles() },
                    loadRecoveryStatus: { await provider.recoveryStatus() },
                    captureProfile: { try await provider.captureProfile(label: $0) },
                    syncActiveProfile: { try await provider.syncActiveProfile() },
                    switchProfile: { try await provider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await provider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await provider.restoreRecoveryProfile(target: $0, expectedTransactionID: $1)
                    }
                )
            }

            await model.load()
            let registered = await model.register(label: "개인")
            let labels = await provider.capturedLabels
            let profiles = await MainActor.run { model.profiles }
            let isWorking = await MainActor.run { model.isWorking }
            let errorMessage = await MainActor.run { model.errorMessage }

            try expect(registered, "menu bar registration reported failure")
            try expect(labels == ["개인"], "menu bar changed the registration label")
            try expect(profiles.count == 1 && profiles[0].active, "registered profile was not reloaded as active")
            try expect(!isWorking, "menu bar remained busy after registration")
            try expect(errorMessage == nil, "successful registration left an error")

            let additionalRegistered = await model.register(label: "회사")
            let profilesAfterAdditional = await MainActor.run { model.profiles }
            let labelsAfterAdditional = await provider.capturedLabels
            try expect(additionalRegistered, "additional menu bar registration reported failure")
            try expect(labelsAfterAdditional == ["개인", "회사"], "additional registration label changed")
            try expect(
                profilesAfterAdditional.count == 2
                    && profilesAfterAdditional[0].active
                    && !profilesAfterAdditional[1].active,
                "additional registration changed the existing active profile"
            )

            let launchFailureProvider = MenuBarProviderSpy(
                profiles: [menuBarProfiles()[0]],
                captureFailureAfterMutation: true,
                captureRecoveryStatusAfterFailure: .none
            )
            let launchFailureModel = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await launchFailureProvider.profiles() },
                    loadRecoveryStatus: { await launchFailureProvider.recoveryStatus() },
                    captureProfile: { try await launchFailureProvider.captureProfile(label: $0) },
                    syncActiveProfile: { try await launchFailureProvider.syncActiveProfile() },
                    switchProfile: { try await launchFailureProvider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await launchFailureProvider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await launchFailureProvider.restoreRecoveryProfile(
                            target: $0,
                            expectedTransactionID: $1
                        )
                    }
                )
            }
            await launchFailureModel.load()
            let committedDespiteLaunchFailure = await launchFailureModel.register(label: "회사")
            let launchFailureProfiles = await MainActor.run { launchFailureModel.profiles }
            let launchFailureMessage = await MainActor.run { launchFailureModel.errorMessage }
            try expect(committedDespiteLaunchFailure, "durably committed registration allowed a duplicate retry")
            try expect(launchFailureProfiles.count == 2, "committed profile was not reloaded after launch failure")
            try expect(
                launchFailureMessage == "계정은 등록했지만 Codex 앱을 다시 열지 못했습니다.",
                "post-commit launch failure was not distinguished from registration failure"
            )

            let partialFailureProvider = MenuBarProviderSpy(
                profiles: [],
                captureFailureAfterMutation: true
            )
            let failureModel = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await partialFailureProvider.profiles() },
                    loadRecoveryStatus: { await partialFailureProvider.recoveryStatus() },
                    captureProfile: { try await partialFailureProvider.captureProfile(label: $0) },
                    syncActiveProfile: { try await partialFailureProvider.syncActiveProfile() },
                    switchProfile: { try await partialFailureProvider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await partialFailureProvider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await partialFailureProvider.restoreRecoveryProfile(
                            target: $0,
                            expectedTransactionID: $1
                        )
                    }
                )
            }
            await failureModel.load()
            let failed = await failureModel.register(label: "회사")
            let failureMessage = await MainActor.run { failureModel.errorMessage }
            let profilesAfterFailure = await MainActor.run { failureModel.profiles }
            let isWorkingAfterFailure = await MainActor.run { failureModel.isWorking }
            try expect(!failed, "failed registration reported success")
            try expect(
                failureMessage == "자동 복구에 실패했습니다. 이전 계정 복구가 필요합니다.",
                "registration recovery error was not safe"
            )
            try expect(
                profilesAfterFailure.count == 1,
                "partial registration failure did not reload durable profiles"
            )
            try expect(!isWorkingAfterFailure, "menu bar remained busy after registration failure")

            _ = await failureModel.register(label: "재시도")
            if let partiallyRegistered = profilesAfterFailure.first {
                await failureModel.select(partiallyRegistered)
            }
            let labelsAfterBlockedRetry = await partialFailureProvider.capturedLabels
            let targetsAfterBlockedRetry = await partialFailureProvider.targets
            try expect(labelsAfterBlockedRetry == ["회사"], "recovery gate retried registration")
            try expect(targetsAfterBlockedRetry.isEmpty, "recovery gate allowed profile selection")
        },
        TestCase("MenuBarViewModel syncs the active credential and stops on recovery") {
            let provider = MenuBarProviderSpy(profiles: menuBarProfiles())
            let model = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await provider.profiles() },
                    loadRecoveryStatus: { await provider.recoveryStatus() },
                    captureProfile: { try await provider.captureProfile(label: $0) },
                    syncActiveProfile: { try await provider.syncActiveProfile() },
                    switchProfile: { try await provider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await provider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await provider.restoreRecoveryProfile(target: $0, expectedTransactionID: $1)
                    }
                )
            }

            await model.load()
            let syncCountAfterLoad = await provider.syncCount
            try expect(syncCountAfterLoad == 0, "active credential synced automatically during load")
            await model.syncActive()
            let syncMessage = await MainActor.run { model.statusMessage }
            let syncError = await MainActor.run { model.errorMessage }
            let isWorkingAfterSync = await MainActor.run { model.isWorking }
            let syncCount = await provider.syncCount
            let profileLoadCount = await provider.profileLoadCount
            let recoveryLoadCount = await provider.recoveryLoadCount
            try expect(syncCount == 1, "active credential sync did not reach Core once")
            try expect(profileLoadCount == 2, "profiles were not reloaded after active sync")
            try expect(recoveryLoadCount == 2, "recovery was not reloaded after active sync")
            try expect(
                syncMessage == "현재 인증을 활성 프로필 저장본에 반영했습니다.",
                "active sync success was not reported"
            )
            try expect(syncError == nil, "active sync success left an error")
            try expect(!isWorkingAfterSync, "menu bar remained busy after active sync")

            let failureProvider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                syncFailureAfterMutation: true
            )
            let failureModel = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await failureProvider.profiles() },
                    loadRecoveryStatus: { await failureProvider.recoveryStatus() },
                    captureProfile: { try await failureProvider.captureProfile(label: $0) },
                    syncActiveProfile: { try await failureProvider.syncActiveProfile() },
                    switchProfile: { try await failureProvider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await failureProvider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await failureProvider.restoreRecoveryProfile(
                            target: $0,
                            expectedTransactionID: $1
                        )
                    }
                )
            }
            await failureModel.load()
            await failureModel.syncActive()
            let recoveryRequired = await MainActor.run { failureModel.recoveryRequired }
            let failureMessage = await MainActor.run { failureModel.errorMessage }
            try expect(recoveryRequired, "active sync failure did not reload recovery state")
            try expect(
                failureMessage == "복구 상태가 불명확합니다. 계정 작업을 중단했습니다.",
                "active sync recovery error was not safe"
            )

            await failureModel.syncActive()
            _ = await failureModel.register(label: "재시도")
            if let active = await MainActor.run(body: { failureModel.profiles.first(where: \.active) }) {
                await failureModel.select(active)
            }
            let syncCountAfterBlockedRetry = await failureProvider.syncCount
            let labelsAfterBlockedRetry = await failureProvider.capturedLabels
            let targetsAfterBlockedRetry = await failureProvider.targets
            try expect(syncCountAfterBlockedRetry == 1, "recovery gate retried active sync")
            try expect(labelsAfterBlockedRetry.isEmpty, "recovery gate allowed registration after active sync failure")
            try expect(targetsAfterBlockedRetry.isEmpty, "recovery gate allowed selection after active sync failure")
        },
        TestCase("MenuBarViewModel identifies the previous profile in recovery status") {
            let previous = menuBarProfiles()[1]
            let provider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                recoveryStatus: .pending(
                    transactionID: "00000000-0000-0000-0000-000000000010",
                    phase: .rollbackFailed,
                    previousProfileID: previous.id
                )
            )
            let model = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await provider.profiles() },
                    loadRecoveryStatus: { await provider.recoveryStatus() },
                    captureProfile: { try await provider.captureProfile(label: $0) },
                    syncActiveProfile: { try await provider.syncActiveProfile() },
                    switchProfile: { try await provider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await provider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await provider.restoreRecoveryProfile(target: $0, expectedTransactionID: $1)
                    }
                )
            }

            await model.load()
            let rollbackMessage = await MainActor.run { model.errorMessage }
            let rollbackProfile = await MainActor.run { model.recoveryProfile }
            try expect(
                rollbackMessage == "자동 복구에 실패했습니다. 회사 계정 복구가 필요합니다.",
                "rollback recovery did not identify the exact previous profile"
            )
            try expect(rollbackProfile?.id == previous.id, "rollback recovery action targeted another profile")

            let interruptedProvider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                recoveryStatus: .pending(
                    transactionID: "00000000-0000-0000-0000-000000000011",
                    phase: .currentSaved,
                    previousProfileID: previous.id
                )
            )
            let interruptedModel = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await interruptedProvider.profiles() },
                    loadRecoveryStatus: { await interruptedProvider.recoveryStatus() },
                    captureProfile: { try await interruptedProvider.captureProfile(label: $0) },
                    syncActiveProfile: { try await interruptedProvider.syncActiveProfile() },
                    switchProfile: { try await interruptedProvider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await interruptedProvider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await interruptedProvider.restoreRecoveryProfile(
                            target: $0,
                            expectedTransactionID: $1
                        )
                    }
                )
            }
            await interruptedModel.load()
            let interruptedMessage = await MainActor.run { interruptedModel.errorMessage }
            let interruptedRecoveryProfile = await MainActor.run { interruptedModel.recoveryProfile }
            try expect(
                interruptedMessage == "중단된 계정 작업 복구가 필요합니다. 단계: currentSaved",
                "pending recovery phase was not shown safely"
            )
            try expect(interruptedRecoveryProfile == nil, "non-rollback recovery exposed a restore action")
        },
        TestCase("MenuBarViewModel restores only after exact confirmation") {
            let previous = menuBarProfiles()[1]
            let firstTransactionID = "00000000-0000-0000-0000-000000000020"
            let nextTransactionID = "00000000-0000-0000-0000-000000000024"
            let provider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                recoveryStatus: .pending(
                    transactionID: firstTransactionID,
                    phase: .rollbackFailed,
                    previousProfileID: previous.id
                ),
                restoreOutcome: .restoredAndLaunched(restoredProfile(previous))
            )
            let model = await makeMenuBarModel(provider: provider)

            await model.load()
            await MainActor.run { model.requestRecovery() }
            let pending = await MainActor.run { model.pendingRecoveryProfile }
            let targetsBeforeConfirmation = await provider.restoreTargets
            await MainActor.run { model.cancelRecovery() }
            let targetsAfterCancellation = await provider.restoreTargets
            await MainActor.run { model.requestRecovery() }
            guard let staleConfirmation = await MainActor.run(body: {
                model.pendingRecoveryConfirmation
            }) else {
                throw TestFailure(description: "stale recovery confirmation was not created")
            }
            await provider.setRecoveryStatus(
                .pending(
                    transactionID: nextTransactionID,
                    phase: .rollbackFailed,
                    previousProfileID: previous.id
                )
            )
            await MainActor.run { model.cancelRecovery() }
            await model.confirmRecovery(staleConfirmation)
            let targetsAfterStaleConfirmation = await provider.restoreTargets
            await MainActor.run { model.requestRecovery() }
            guard let currentConfirmation = await MainActor.run(body: {
                model.pendingRecoveryConfirmation
            }) else {
                throw TestFailure(description: "current recovery confirmation was not created")
            }
            await MainActor.run { model.cancelRecovery() }
            await model.confirmRecovery(currentConfirmation)
            let targetsAfterConfirmation = await provider.restoreTargets
            let transactionIDsAfterConfirmation = await provider.restoreTransactionIDs
            let profiles = await MainActor.run { model.profiles }
            let statusMessage = await MainActor.run { model.statusMessage }
            let errorMessage = await MainActor.run { model.errorMessage }

            try expect(pending?.id == previous.id, "recovery confirmation targeted another profile")
            try expect(targetsBeforeConfirmation.isEmpty, "recovery mutated before confirmation")
            try expect(targetsAfterCancellation.isEmpty, "cancelled recovery reached Core")
            try expect(
                targetsAfterStaleConfirmation.isEmpty,
                "stale confirmation restored a replacement transaction"
            )
            try expect(
                targetsAfterConfirmation == [previous.id.description],
                "confirmed recovery did not use the exact previous profile ID once"
            )
            try expect(
                transactionIDsAfterConfirmation == [nextTransactionID],
                "confirmed recovery did not bind the exact transaction ID"
            )
            try expect(
                profiles.filter(\.active).count == 1
                    && profiles.first(where: { $0.id == previous.id })?.active == true,
                "successful recovery did not reload one active previous profile"
            )
            try expect(
                statusMessage == "회사 계정을 복구하고 Codex 앱을 열었습니다.",
                "successful recovery status changed"
            )
            try expect(errorMessage == nil, "successful recovery left an error")
        },
        TestCase("MenuBarViewModel never retries a launch-unconfirmed recovery") {
            let previous = menuBarProfiles()[1]
            let provider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                recoveryStatus: .pending(
                    transactionID: "00000000-0000-0000-0000-000000000021",
                    phase: .rollbackFailed,
                    previousProfileID: previous.id
                ),
                restoreOutcome: .restoredButLaunchUnconfirmed(restoredProfile(previous))
            )
            let model = await makeMenuBarModel(provider: provider)

            await model.load()
            await MainActor.run { model.requestRecovery() }
            await model.confirmRecovery()
            await MainActor.run { model.requestRecovery() }
            await model.confirmRecovery()
            let targets = await provider.restoreTargets
            let recoveryStatus = await MainActor.run { model.recoveryStatus }
            let recoveryProfile = await MainActor.run { model.recoveryProfile }
            let errorMessage = await MainActor.run { model.errorMessage }

            try expect(targets == [previous.id.description], "launch uncertainty retried auth recovery")
            try expect(recoveryStatus == .none, "launch uncertainty reopened recovery state")
            try expect(recoveryProfile == nil, "launch uncertainty left a recovery action")
            try expect(
                errorMessage == "회사 계정은 복구했지만 Codex 앱 실행을 확인하지 못했습니다. 복구를 다시 시도하지 말고 앱만 직접 여세요.",
                "launch uncertainty did not prohibit restore retry"
            )
        },
        TestCase("MenuBarViewModel keeps uncertain recovery fail-closed") {
            let previous = menuBarProfiles()[1]
            let blockedProvider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                recoveryStatus: .pending(
                    transactionID: "00000000-0000-0000-0000-000000000022",
                    phase: .rollbackFailed,
                    previousProfileID: previous.id
                ),
                restoreOutcome: .journalFinalizationUncertain,
                recoveryStatusAfterRestore: .blocked
            )
            let blockedModel = await makeMenuBarModel(provider: blockedProvider)

            await blockedModel.load()
            await MainActor.run { blockedModel.requestRecovery() }
            await blockedModel.confirmRecovery()
            _ = await blockedModel.register(label: "재시도")
            await blockedModel.syncActive()
            if let active = await MainActor.run(body: { blockedModel.profiles.first(where: \.active) }) {
                await blockedModel.select(active)
            }
            let blockedRestoreTargets = await blockedProvider.restoreTargets
            let blockedLabels = await blockedProvider.capturedLabels
            let blockedSyncCount = await blockedProvider.syncCount
            let blockedSwitchTargets = await blockedProvider.targets
            let blockedMessage = await MainActor.run { blockedModel.errorMessage }

            try expect(blockedRestoreTargets == [previous.id.description], "uncertain recovery retried restore")
            try expect(blockedLabels.isEmpty, "uncertain recovery allowed registration")
            try expect(blockedSyncCount == 0, "uncertain recovery allowed active sync")
            try expect(blockedSwitchTargets.isEmpty, "uncertain recovery allowed profile selection")
            try expect(
                blockedMessage == "복구 상태가 불명확합니다. 계정 작업을 중단했습니다.",
                "uncertain recovery did not keep STOP state"
            )

            let reconciledProvider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                recoveryStatus: .pending(
                    transactionID: "00000000-0000-0000-0000-000000000023",
                    phase: .rollbackFailed,
                    previousProfileID: previous.id
                ),
                restoreOutcome: .journalFinalizationUncertain,
                recoveryStatusAfterRestore: .none
            )
            let reconciledModel = await makeMenuBarModel(provider: reconciledProvider)
            await reconciledModel.load()
            await MainActor.run { reconciledModel.requestRecovery() }
            await reconciledModel.confirmRecovery()
            let reconciledMessage = await MainActor.run { reconciledModel.statusMessage }
            let reconciledError = await MainActor.run { reconciledModel.errorMessage }
            try expect(
                reconciledMessage == "회사 계정 복구를 재확인했습니다. Codex 앱은 열지 않았습니다.",
                "reconciled finalization did not report app launch omission"
            )
            try expect(reconciledError == nil, "reconciled finalization remained blocked")
        },
        TestCase("MenuBarViewModel confirms the exact relogin target") {
            let provider = MenuBarProviderSpy(profiles: menuBarReloginProfiles())
            let model = await makeMenuBarModel(provider: provider)
            await model.load()
            guard let target = await MainActor.run(body: {
                model.profiles.first(where: { !$0.active && $0.needsRelogin })
            }) else {
                throw TestFailure(description: "relogin fixture has no target")
            }

            await model.select(target)
            let firstConfirmation = await MainActor.run { model.pendingReloginProfile }
            let switchConfirmation = await MainActor.run { model.pendingProfile }
            await MainActor.run { model.cancelRelogin() }
            let targetsAfterCancellation = await provider.reloginTargets

            await model.select(target)
            guard let capturedConfirmation = await MainActor.run(body: {
                model.pendingReloginProfile
            }) else {
                throw TestFailure(description: "relogin confirmation was not created")
            }
            await MainActor.run { model.cancelRelogin() }
            await model.confirmRelogin(capturedConfirmation)

            let reloginTargets = await provider.reloginTargets
            let switchTargets = await provider.targets
            let profiles = await MainActor.run { model.profiles }
            let statusMessage = await MainActor.run { model.statusMessage }
            try expect(firstConfirmation?.id == target.id, "relogin confirmation changed target")
            try expect(switchConfirmation == nil, "relogin target entered normal switch confirmation")
            try expect(targetsAfterCancellation.isEmpty, "cancelled relogin reached Core")
            try expect(reloginTargets == [target.id.description], "relogin did not use the exact ID once")
            try expect(switchTargets.isEmpty, "relogin called the normal switch path")
            try expect(profiles.filter(\.active).count == 1, "relogin produced multiple active profiles")
            try expect(
                profiles.contains { $0.id == target.id && $0.active && !$0.needsRelogin },
                "relogin did not activate the verified target"
            )
            try expect(
                statusMessage == "회사 계정 재로그인을 반영했습니다. Codex 앱을 직접 여세요.",
                "relogin success did not require manual app launch"
            )
        },
        TestCase("MenuBarViewModel rejects a stale relogin confirmation") {
            let profiles = menuBarReloginProfiles()
            let provider = MenuBarProviderSpy(profiles: profiles)
            let model = await makeMenuBarModel(provider: provider)
            await model.load()
            guard let target = await MainActor.run(body: {
                model.profiles.first(where: { !$0.active && $0.needsRelogin })
            }) else {
                throw TestFailure(description: "stale relogin fixture has no target")
            }
            await model.select(target)
            guard let confirmation = await MainActor.run(body: { model.pendingReloginProfile }) else {
                throw TestFailure(description: "stale relogin confirmation was not created")
            }
            await provider.setRecoveryStatus(
                .pending(
                    transactionID: "00000000-0000-0000-0000-000000000030",
                    phase: .validatingTarget,
                    previousProfileID: profiles[0].id
                )
            )
            await MainActor.run { model.cancelRelogin() }
            await model.confirmRelogin(confirmation)

            let reloginTargets = await provider.reloginTargets
            let recoveryRequired = await MainActor.run { model.recoveryRequired }
            try expect(reloginTargets.isEmpty, "stale relogin confirmation reached Core")
            try expect(recoveryRequired, "stale relogin confirmation ignored recovery state")
        },
        TestCase("MenuBarViewModel reconciles uncertain relogin once") {
            let blockedProvider = MenuBarProviderSpy(
                profiles: menuBarReloginProfiles(),
                reloginOutcome: .journalFinalizationUncertain,
                recoveryStatusAfterRelogin: .blocked
            )
            let blockedModel = await makeMenuBarModel(provider: blockedProvider)
            await blockedModel.load()
            guard let blockedTarget = await MainActor.run(body: {
                blockedModel.profiles.first(where: { !$0.active && $0.needsRelogin })
            }) else {
                throw TestFailure(description: "blocked relogin fixture has no target")
            }
            await blockedModel.select(blockedTarget)
            await blockedModel.confirmRelogin()
            await blockedModel.confirmRelogin(blockedTarget)
            let blockedTargets = await blockedProvider.reloginTargets
            let blockedError = await MainActor.run { blockedModel.errorMessage }
            try expect(blockedTargets == [blockedTarget.id.description], "uncertain relogin retried Core")
            try expect(
                blockedError == "복구 상태가 불명확합니다. 계정 작업을 중단했습니다.",
                "uncertain relogin did not remain stopped"
            )

            let reconciledProvider = MenuBarProviderSpy(
                profiles: menuBarReloginProfiles(),
                reloginOutcome: .journalFinalizationUncertain
            )
            let reconciledModel = await makeMenuBarModel(provider: reconciledProvider)
            await reconciledModel.load()
            guard let reconciledTarget = await MainActor.run(body: {
                reconciledModel.profiles.first(where: { !$0.active && $0.needsRelogin })
            }) else {
                throw TestFailure(description: "reconciled relogin fixture has no target")
            }
            await reconciledModel.select(reconciledTarget)
            await reconciledModel.confirmRelogin()
            let reconciledMessage = await MainActor.run { reconciledModel.statusMessage }
            let reconciledError = await MainActor.run { reconciledModel.errorMessage }
            try expect(
                reconciledMessage == "회사 계정 재로그인을 재확인했습니다. Codex 앱을 직접 여세요.",
                "reconciled relogin did not report manual app launch"
            )
            try expect(reconciledError == nil, "reconciled relogin remained blocked")
        },
        TestCase("MenuBarViewModel reconciles relogin throws from durable state") {
            let committedProvider = MenuBarProviderSpy(
                profiles: menuBarReloginProfiles(),
                reloginFailurePoint: .afterMutation
            )
            let committedModel = await makeMenuBarModel(provider: committedProvider)
            await committedModel.load()
            guard let committedTarget = await MainActor.run(body: {
                committedModel.profiles.first(where: { !$0.active && $0.needsRelogin })
            }) else {
                throw TestFailure(description: "committed throw fixture has no target")
            }
            await committedModel.select(committedTarget)
            await committedModel.confirmRelogin()
            let committedTargets = await committedProvider.reloginTargets
            let committedStatus = await MainActor.run { committedModel.statusMessage }
            let committedError = await MainActor.run { committedModel.errorMessage }
            try expect(committedTargets == [committedTarget.id.description], "committed throw retried relogin")
            try expect(
                committedStatus == "회사 계정 재로그인을 반영했습니다. Codex 앱을 직접 여세요.",
                "committed throw was not reconciled from durable state"
            )
            try expect(committedError == nil, "committed throw remained an error")

            let rolledBackProvider = MenuBarProviderSpy(
                profiles: menuBarReloginProfiles(),
                reloginFailurePoint: .beforeMutation
            )
            let rolledBackModel = await makeMenuBarModel(provider: rolledBackProvider)
            await rolledBackModel.load()
            guard let rolledBackTarget = await MainActor.run(body: {
                rolledBackModel.profiles.first(where: { !$0.active && $0.needsRelogin })
            }) else {
                throw TestFailure(description: "rolled-back throw fixture has no target")
            }
            await rolledBackModel.select(rolledBackTarget)
            await rolledBackModel.confirmRelogin()
            await rolledBackModel.select(rolledBackTarget)
            let rolledBackTargets = await rolledBackProvider.reloginTargets
            let rolledBackRecovery = await MainActor.run { rolledBackModel.recoveryStatus }
            let retryConfirmation = await MainActor.run { rolledBackModel.pendingReloginProfile }
            try expect(rolledBackTargets == [rolledBackTarget.id.description], "safe rollback retried automatically")
            try expect(rolledBackRecovery == .none, "safe rollback was forced into STOP")
            try expect(retryConfirmation?.id == rolledBackTarget.id, "safe rollback did not allow manual retry")

            let pendingStatus = RecoveryCLIStatus.pending(
                transactionID: "00000000-0000-0000-0000-000000000031",
                phase: .validatingTarget,
                previousProfileID: menuBarReloginProfiles()[0].id
            )
            let pendingProvider = MenuBarProviderSpy(
                profiles: menuBarReloginProfiles(),
                reloginFailurePoint: .beforeMutation,
                recoveryStatusAfterRelogin: pendingStatus
            )
            let pendingModel = await makeMenuBarModel(provider: pendingProvider)
            await pendingModel.load()
            guard let pendingTarget = await MainActor.run(body: {
                pendingModel.profiles.first(where: { !$0.active && $0.needsRelogin })
            }) else {
                throw TestFailure(description: "pending throw fixture has no target")
            }
            await pendingModel.select(pendingTarget)
            await pendingModel.confirmRelogin()
            await pendingModel.confirmRelogin(pendingTarget)
            let pendingTargets = await pendingProvider.reloginTargets
            let pendingRecovery = await MainActor.run { pendingModel.recoveryStatus }
            try expect(pendingTargets == [pendingTarget.id.description], "pending throw retried relogin")
            try expect(pendingRecovery == pendingStatus, "pending throw lost recovery state")
        },
        TestCase("MenuBarViewModel validates relogin outcome after a transient reload failure") {
            let wrongProfile = menuBarProfiles()[2]
            let provider = MenuBarProviderSpy(
                profiles: menuBarReloginProfiles(),
                reloginOutcome: .activated(restoredProfile(wrongProfile)),
                failFirstProfileLoadAfterRelogin: true
            )
            let model = await makeMenuBarModel(provider: provider, useInjectedProfileLoad: true)
            await model.load()
            guard let target = await MainActor.run(body: {
                model.profiles.first(where: { !$0.active && $0.needsRelogin })
            }) else {
                throw TestFailure(description: "transient reload fixture has no target")
            }
            await model.select(target)
            await model.confirmRelogin()

            let reloginTargets = await provider.reloginTargets
            let recoveryStatus = await MainActor.run { model.recoveryStatus }
            let statusMessage = await MainActor.run { model.statusMessage }
            try expect(reloginTargets == [target.id.description], "wrong outcome retried relogin")
            try expect(recoveryStatus == .blocked, "wrong outcome ID bypassed STOP after reload failure")
            try expect(statusMessage == nil, "wrong outcome ID reported relogin success")
        },
    ]
}

private func makeMenuBarModel(
    provider: MenuBarProviderSpy,
    useInjectedProfileLoad: Bool = false
) async -> MenuBarViewModel {
    await MainActor.run {
        MenuBarViewModel(
            loadProfiles: {
                if useInjectedProfileLoad {
                    return try await provider.profilesWithInjectedFailure()
                }
                return await provider.profiles()
            },
            loadRecoveryStatus: { await provider.recoveryStatus() },
            captureProfile: { try await provider.captureProfile(label: $0) },
            syncActiveProfile: { try await provider.syncActiveProfile() },
            switchProfile: { try await provider.switchProfile(target: $0, onPhaseChange: $1) },
            reloginProfile: { try await provider.reloginProfile(target: $0) },
            restoreRecoveryProfile: {
                try await provider.restoreRecoveryProfile(target: $0, expectedTransactionID: $1)
            }
        )
    }
}

private func restoredProfile(_ profile: ProfileListItem) -> ProfileListItem {
    ProfileListItem(
        id: profile.id,
        label: profile.label,
        email: profile.email,
        active: true,
        needsRelogin: profile.needsRelogin
    )
}

private actor MenuBarProviderSpy {
    private var storedProfiles: [ProfileListItem]
    private let applicationIsRunning: Bool
    private let captureFailureAfterMutation: Bool
    private let captureRecoveryStatusAfterFailure: RecoveryCLIStatus
    private let syncFailureAfterMutation: Bool
    private let switchFailureAfterProgress: Bool
    private let reloginOutcome: ProfileReloginOutcome?
    private let reloginFailurePoint: ReloginFailurePoint?
    private let failFirstProfileLoadAfterRelogin: Bool
    private let recoveryStatusAfterRelogin: RecoveryCLIStatus
    private let restoreOutcome: RecoveryRestoreOutcome?
    private let recoveryStatusAfterRestore: RecoveryCLIStatus
    private var storedRecoveryStatus: RecoveryCLIStatus
    private var injectedProfileLoadFailurePending = false
    private(set) var profileLoadCount = 0
    private(set) var recoveryLoadCount = 0
    private(set) var syncCount = 0
    private(set) var targets = [String]()
    private(set) var events = [String]()
    private(set) var capturedLabels = [String]()
    private(set) var switchPhases = [SwitchPhase]()
    private(set) var reloginTargets = [String]()
    private(set) var restoreTargets = [String]()
    private(set) var restoreTransactionIDs = [String]()
    private(set) var mutationCount = 0

    init(
        profiles: [ProfileListItem],
        applicationIsRunning: Bool = true,
        captureFailureAfterMutation: Bool = false,
        captureRecoveryStatusAfterFailure: RecoveryCLIStatus = .pending(
            transactionID: "00000000-0000-0000-0000-000000000001",
            phase: .rollbackFailed,
            previousProfileID: ProfileID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            )
        ),
        syncFailureAfterMutation: Bool = false,
        switchFailureAfterProgress: Bool = false,
        recoveryStatus: RecoveryCLIStatus = .none,
        reloginOutcome: ProfileReloginOutcome? = nil,
        reloginFailurePoint: ReloginFailurePoint? = nil,
        failFirstProfileLoadAfterRelogin: Bool = false,
        recoveryStatusAfterRelogin: RecoveryCLIStatus = .none,
        restoreOutcome: RecoveryRestoreOutcome? = nil,
        recoveryStatusAfterRestore: RecoveryCLIStatus = .none
    ) {
        storedProfiles = profiles
        self.applicationIsRunning = applicationIsRunning
        self.captureFailureAfterMutation = captureFailureAfterMutation
        self.captureRecoveryStatusAfterFailure = captureRecoveryStatusAfterFailure
        self.syncFailureAfterMutation = syncFailureAfterMutation
        self.switchFailureAfterProgress = switchFailureAfterProgress
        self.reloginOutcome = reloginOutcome
        self.reloginFailurePoint = reloginFailurePoint
        self.failFirstProfileLoadAfterRelogin = failFirstProfileLoadAfterRelogin
        self.recoveryStatusAfterRelogin = recoveryStatusAfterRelogin
        self.restoreOutcome = restoreOutcome
        self.recoveryStatusAfterRestore = recoveryStatusAfterRestore
        storedRecoveryStatus = recoveryStatus
    }

    func profiles() -> [ProfileListItem] {
        profileLoadCount += 1
        return storedProfiles
    }

    func profilesWithInjectedFailure() throws -> [ProfileListItem] {
        profileLoadCount += 1
        if injectedProfileLoadFailurePending {
            injectedProfileLoadFailurePending = false
            throw MenuBarProviderSpyFailure.profileLoadFailed
        }
        return storedProfiles
    }

    func recoveryStatus() -> RecoveryCLIStatus {
        recoveryLoadCount += 1
        return storedRecoveryStatus
    }

    func setRecoveryStatus(_ status: RecoveryCLIStatus) {
        storedRecoveryStatus = status
    }

    func captureProfile(label: String) throws -> ProfileListItem {
        guard storedProfiles.count < ProfileRegistry.maximumProfileCount else {
            throw MenuBarProviderSpyFailure.captureFailed
        }
        capturedLabels.append(label)
        let profile = ProfileListItem(
            id: ProfileID(UUID()),
            label: label,
            email: "captured@example.invalid",
            active: storedProfiles.isEmpty,
            needsRelogin: false
        )
        storedProfiles.append(profile)
        if captureFailureAfterMutation {
            storedRecoveryStatus = captureRecoveryStatusAfterFailure
            throw MenuBarProviderSpyFailure.captureFailed
        }
        return profile
    }

    func syncActiveProfile() throws -> ProfileListItem {
        syncCount += 1
        guard let active = storedProfiles.first(where: \.active) else {
            throw MenuBarProviderSpyFailure.missingProfile
        }
        if syncFailureAfterMutation {
            storedRecoveryStatus = .blocked
            throw MenuBarProviderSpyFailure.syncFailed
        }
        return active
    }

    func switchProfile(
        target: String,
        onPhaseChange: @Sendable (SwitchPhase) async -> Void
    ) async throws -> ProfileListItem {
        targets.append(target)
        guard let selected = storedProfiles.first(where: { $0.id.description == target }) else {
            throw MenuBarProviderSpyFailure.missingProfile
        }
        if selected.active {
            if applicationIsRunning {
                events.append("activate")
            } else {
                events.append("verify")
                events.append("launch")
            }
            return selected
        }
        for phase in SwitchStateMachine.canonicalPhases {
            switchPhases.append(phase)
            await onPhaseChange(phase)
        }
        if switchFailureAfterProgress {
            throw MenuBarProviderSpyFailure.switchFailed
        }
        mutationCount += 1
        storedProfiles = storedProfiles.map { profile in
            ProfileListItem(
                id: profile.id,
                label: profile.label,
                email: profile.email,
                active: profile.id == selected.id,
                needsRelogin: profile.needsRelogin
            )
        }
        guard let updated = storedProfiles.first(where: { $0.id == selected.id }) else {
            throw MenuBarProviderSpyFailure.missingProfile
        }
        return updated
    }

    func reloginProfile(target: String) throws -> ProfileReloginOutcome {
        reloginTargets.append(target)
        guard let selected = storedProfiles.first(where: { $0.id.description == target }),
              !selected.active,
              selected.needsRelogin else {
            throw MenuBarProviderSpyFailure.reloginFailed
        }
        if reloginFailurePoint == .beforeMutation {
            storedRecoveryStatus = recoveryStatusAfterRelogin
            throw MenuBarProviderSpyFailure.reloginFailed
        }
        storedProfiles = storedProfiles.map { profile in
            ProfileListItem(
                id: profile.id,
                label: profile.label,
                email: profile.email,
                active: profile.id == selected.id,
                needsRelogin: profile.id == selected.id ? false : profile.needsRelogin
            )
        }
        storedRecoveryStatus = recoveryStatusAfterRelogin
        injectedProfileLoadFailurePending = failFirstProfileLoadAfterRelogin
        if reloginFailurePoint == .afterMutation {
            throw MenuBarProviderSpyFailure.reloginFailed
        }
        guard let updated = storedProfiles.first(where: { $0.id == selected.id }) else {
            throw MenuBarProviderSpyFailure.missingProfile
        }
        return reloginOutcome ?? .activated(updated)
    }

    func restoreRecoveryProfile(
        target: String,
        expectedTransactionID: String
    ) throws -> RecoveryRestoreOutcome {
        restoreTargets.append(target)
        restoreTransactionIDs.append(expectedTransactionID)
        guard case let .pending(transactionID, .rollbackFailed, previousProfileID) = storedRecoveryStatus,
              transactionID == expectedTransactionID,
              previousProfileID.description == target,
              let restoreOutcome,
              storedProfiles.contains(where: { $0.id == previousProfileID }) else {
            throw MenuBarProviderSpyFailure.recoveryFailed
        }
        storedProfiles = storedProfiles.map { profile in
            ProfileListItem(
                id: profile.id,
                label: profile.label,
                email: profile.email,
                active: profile.id.description == target,
                needsRelogin: profile.needsRelogin
            )
        }
        storedRecoveryStatus = recoveryStatusAfterRestore
        return restoreOutcome
    }
}

private enum ReloginFailurePoint {
    case beforeMutation
    case afterMutation
}

private enum MenuBarProviderSpyFailure: Error {
    case missingProfile
    case profileLoadFailed
    case captureFailed
    case syncFailed
    case switchFailed
    case reloginFailed
    case recoveryFailed
}

private func menuBarProfiles() -> [ProfileListItem] {
    [
        ProfileListItem(
            id: ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            label: "개인",
            email: "personal@example.invalid",
            active: true,
            needsRelogin: false
        ),
        ProfileListItem(
            id: ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            label: "회사",
            email: "work@example.invalid",
            active: false,
            needsRelogin: false
        ),
        ProfileListItem(
            id: ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
            label: "프로젝트",
            email: "project@example.invalid",
            active: false,
            needsRelogin: false
        ),
    ]
}

private func menuBarReloginProfiles() -> [ProfileListItem] {
    menuBarProfiles().map { profile in
        guard profile.label == "회사" else { return profile }
        return ProfileListItem(
            id: profile.id,
            label: profile.label,
            email: profile.email,
            active: false,
            needsRelogin: true
        )
    }
}
