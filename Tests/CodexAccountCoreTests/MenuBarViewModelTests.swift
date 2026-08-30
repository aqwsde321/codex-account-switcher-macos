import Foundation
import CodexAccountCore
import CodexAccountMenuBarModel
import CodexSleepGuardCore

func menuBarViewModelTests() -> [TestCase] {
    [
        TestCase("SleepPreventionViewModel parses and verifies pmset mutations") {
            let probe = SleepPreventionProbe(enabled: true)
            let model = await MainActor.run {
                SleepPreventionViewModel(
                    readEnabled: { try await probe.read() },
                    setEnabled: { await probe.set($0) }
                )
            }

            await model.load()
            await model.setEnabled(false)
            await probe.stopApplyingChanges()
            await model.setEnabled(true)
            let mismatchState = await MainActor.run {
                (model.isEnabled, model.errorMessage)
            }
            await probe.failReads()
            await model.load()

            let unknownState = await MainActor.run {
                (model.isEnabled, model.errorMessage)
            }
            let requests = await probe.requests
            try expect(
                mismatchState.0 == false
                    && mismatchState.1 != nil
                    && unknownState.0 == true
                    && unknownState.1?.contains("켜짐으로 표시") == true
                    && requests == [false, true]
                    && SleepPreventionViewModel.parsePMSetOutput("SleepDisabled 1") == true
                    && SleepPreventionViewModel.parsePMSetOutput("SleepDisabled 0") == false
                    && SleepPreventionViewModel.parsePMSetOutput("SleepDisabled unknown") == nil
                    && SleepPreventionViewModel.parsePMSetOutput("sleep 1") == nil,
                "sleep prevention state was not parsed or verified fail-closed"
            )
        },
        TestCase("SleepPreventionViewModel persists only a successful auto-disable threshold") {
            guard let initialThreshold = SleepGuardThreshold(rawValue: 15),
                  let savedThreshold = SleepGuardThreshold(rawValue: 99),
                  let failedThreshold = SleepGuardThreshold(rawValue: 1) else {
                throw TestFailure(description: "valid sleep guard threshold was rejected")
            }
            let probe = SleepGuardSettingProbe()
            let model = await MainActor.run {
                SleepPreventionViewModel(
                    readEnabled: { false },
                    setEnabled: { _ in },
                    initialAutoDisableThreshold: initialThreshold,
                    saveAutoDisableThreshold: { try await probe.save($0) }
                )
            }

            await model.setAutoDisableThreshold(savedThreshold)
            await probe.failWrites()
            await model.setAutoDisableThreshold(failedThreshold)
            let state = await MainActor.run {
                (model.autoDisableThreshold, model.errorMessage)
            }
            let requests = await probe.requests

            try expect(
                state.0 == savedThreshold
                    && state.1?.contains("저장하지 못했습니다") == true
                    && requests == [savedThreshold, failedThreshold],
                "sleep guard threshold changed after a failed persistence"
            )
        },
        TestCase("MenuBarViewModel attempts recovery before loading state") {
            let provider = MenuBarProviderSpy(profiles: menuBarProfiles())
            let order = RefreshOrderRecorder()
            let model = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: {
                        await order.record("profiles")
                        return await provider.profiles()
                    },
                    loadRecoveryStatus: {
                        await order.record("status")
                        return await provider.recoveryStatus()
                    },
                    captureProfile: { try await provider.captureProfile(label: $0) },
                    syncActiveProfile: { try await provider.syncActiveProfile() },
                    switchProfile: { try await provider.switchProfile(target: $0, onPhaseChange: $1) },
                    reloginProfile: { try await provider.reloginProfile(target: $0) },
                    restoreRecoveryProfile: {
                        try await provider.restoreRecoveryProfile(target: $0, expectedTransactionID: $1)
                    },
                    attemptAutomaticRecovery: { await order.record("recovery") }
                )
            }

            await model.load()
            let events = await order.events

            try expect(
                events == ["recovery", "profiles", "status"],
                "menu bar loaded stale state before recovery"
            )
        },
        TestCase("MenuBarViewModel loads per-account usage and derives the active remaining limit") {
            let profiles = menuBarProfiles()
            let activeID = profiles[0].id
            let inactiveID = profiles[1].id
            let failedID = profiles[2].id
            let report = ProfileUsageReport(
                usageByProfileID: [
                    activeID: AppServerRateLimitsRead(
                        planType: "pro",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 20,
                                windowDurationMinutes: 300,
                                resetsAt: nil
                            ),
                            AppServerRateLimitWindow(
                                usedPercent: 90,
                                windowDurationMinutes: 10_080,
                                resetsAt: nil
                            ),
                        ]
                    ),
                    inactiveID: AppServerRateLimitsRead(
                        planType: "team",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 15,
                                windowDurationMinutes: 43_200,
                                resetsAt: nil
                            ),
                        ]
                    ),
                ],
                failedProfileIDs: [failedID]
            )
            let provider = MenuBarProviderSpy(profiles: profiles)
            let usageLoads = RefreshOrderRecorder()
            let model = await makeMenuBarModel(
                provider: provider,
                loadProfileUsage: { _ in
                    await usageLoads.record("usage")
                    return report
                }
            )

            await model.load()

            let loadedUsage = await MainActor.run { model.usageByProfileID }
            let failures = await MainActor.run { model.usageFailedProfileIDs }
            let remaining = await MainActor.run { model.activeRemainingPercent }
            try expect(loadedUsage.count == 2, "inactive account usage was not retained")
            try expect(failures == [failedID], "one account failure affected other accounts")
            try expect(remaining == 10, "menu bar did not use the tightest active limit")
            try expect(
                MenuBarViewModel.periodLabel(minutes: 300) == "5h"
                    && MenuBarViewModel.periodLabel(minutes: 10_080) == "7d"
                    && MenuBarViewModel.periodLabel(minutes: 43_200) == "30d",
                "dynamic rate-limit period labels changed"
            )
            await model.select(profiles[1])
            await model.confirmSwitch(profiles[1])
            let switchedRemaining = await MainActor.run { model.activeRemainingPercent }
            try expect(switchedRemaining == 85, "switch left the previous active usage in the menu bar")

            await model.syncActive()
            let usageLoadEvents = await usageLoads.events
            try expect(
                usageLoadEvents == ["usage", "usage", "usage"],
                "credential changes did not reload usage"
            )
        },
        TestCase("MenuBarViewModel uses a token for one account and refreshes only that usage") {
            let profiles = menuBarProfiles()
            let target = profiles[1]
            let tokenUses = TokenUseProbe()
            let usageLoads = ProfileUsageLoadProbe()
            let provider = MenuBarProviderSpy(profiles: profiles)
            let model = await makeMenuBarModel(
                provider: provider,
                loadProfileUsage: { profileIDs in
                    await usageLoads.record(profileIDs)
                    return ProfileUsageReport(usageByProfileID: [:], failedProfileIDs: [])
                },
                useToken: { profileID in
                    await tokenUses.record(profileID)
                }
            )

            await model.load()
            await model.useToken(for: target)

            let usedProfileIDs = await tokenUses.profileIDs
            let requestedUsage = await usageLoads.profileIDs
            let state = await MainActor.run {
                (model.tokenUsingProfileID, model.statusMessage, model.errorMessage)
            }
            try expect(usedProfileIDs == [target.id], "token use targeted the wrong account")
            try expect(
                requestedUsage == [nil, Set([target.id])],
                "token use refreshed more than the selected account"
            )
            try expect(
                state.0 == nil && state.1?.contains(target.label) == true && state.2 == nil,
                "token use did not finish with a selected-account success state"
            )
        },
        TestCase("MenuBarViewModel selects the limiting reset and rounds its countdown up") {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let windows = [
                AppServerRateLimitWindow(
                    usedPercent: 20,
                    windowDurationMinutes: 300,
                    resetsAt: now.addingTimeInterval(10 * 3_600)
                ),
                AppServerRateLimitWindow(
                    usedPercent: 90,
                    windowDurationMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(59 * 60)
                ),
            ]
            let limitingWindow = MenuBarViewModel.limitingWindow(in: windows)
            try expect(
                limitingWindow?.windowDurationMinutes == 10_080
                    && MenuBarViewModel.resetCountdownLabel(
                        resetAt: now.addingTimeInterval(243_480),
                        now: now
                    ) == "3d"
                    && MenuBarViewModel.resetCountdownLabel(
                        resetAt: now.addingTimeInterval(81_000),
                        now: now
                    ) == "23h"
                    && MenuBarViewModel.resetCountdownLabel(
                        resetAt: now.addingTimeInterval(24 * 3_600),
                        now: now
                    ) == "24h"
                    && MenuBarViewModel.resetCountdownLabel(
                        resetAt: now.addingTimeInterval(3_600),
                        now: now
                    ) == "1h"
                    && MenuBarViewModel.resetCountdownLabel(
                        resetAt: now.addingTimeInterval(3_510),
                        now: now
                    ) == "59m"
                    && MenuBarViewModel.resetCountdownLabel(resetAt: nil, now: now) == nil,
                "menu bar did not select or format the active reset countdown"
            )
        },
        TestCase("MenuBarViewModel refreshes active usage at two minutes and all usage at thirty") {
            let profiles = menuBarProfiles()
            let activeID = profiles[0].id
            let inactiveID = profiles[1].id
            let fullReport = ProfileUsageReport(
                usageByProfileID: [
                    activeID: AppServerRateLimitsRead(
                        planType: "pro",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 20,
                                windowDurationMinutes: 300,
                                resetsAt: nil
                            ),
                        ]
                    ),
                    inactiveID: AppServerRateLimitsRead(
                        planType: "team",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 15,
                                windowDurationMinutes: 10_080,
                                resetsAt: nil
                            ),
                        ]
                    ),
                ],
                failedProfileIDs: []
            )
            let activeReport = ProfileUsageReport(
                usageByProfileID: [
                    activeID: AppServerRateLimitsRead(
                        planType: "pro",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 40,
                                windowDurationMinutes: 300,
                                resetsAt: nil
                            ),
                        ]
                    ),
                ],
                failedProfileIDs: []
            )
            let partialFullReport = ProfileUsageReport(
                usageByProfileID: [activeID: activeReport.usageByProfileID[activeID]!],
                failedProfileIDs: [inactiveID]
            )
            let provider = MenuBarProviderSpy(profiles: profiles)
            let usageLoads = UsageReportSequence(
                reports: [fullReport, activeReport, partialFullReport]
            )
            let model = await makeMenuBarModel(
                provider: provider,
                loadProfileUsage: { profileIDs in
                    await usageLoads.load(profileIDs: profileIDs)
                }
            )

            await model.load()
            let now = Date.now
            await model.refreshUsageAutomatically(now: now.addingTimeInterval(120))

            let activeRefreshUsage = await MainActor.run { model.usageByProfileID }
            try expect(
                activeRefreshUsage[activeID]?.windows.first?.usedPercent == 40,
                "two-minute refresh did not update the active account"
            )
            try expect(
                activeRefreshUsage[inactiveID]?.windows.first?.usedPercent == 15,
                "active refresh discarded cached inactive usage"
            )

            await model.refreshUsageAutomatically(now: now.addingTimeInterval(1_801))
            let usageLoadEvents = await usageLoads.events
            let fullRefreshUsage = await MainActor.run { model.usageByProfileID }
            try expect(
                usageLoadEvents == ["all", "active", "all"],
                "automatic refresh did not use the 2-minute/30-minute scopes"
            )
            try expect(
                fullRefreshUsage[inactiveID]?.windows.first?.usedPercent == 15,
                "automatic partial failure discarded cached inactive usage"
            )
            try expect(
                MenuBarViewModel.activeUsageRefreshInterval == .seconds(120)
                    && MenuBarViewModel.inactiveUsageRefreshInterval == 1_800,
                "automatic refresh intervals changed"
            )
        },
        TestCase("MenuBarViewModel rechecks all accounts after one reset and uses full accounts") {
            let profiles = menuBarProfiles()
            let firstID = profiles[0].id
            let secondID = profiles[1].id
            let baselineReset = Date(timeIntervalSince1970: 10_000)
            let firstChangedReset = Date(timeIntervalSince1970: 20_000)
            let secondChangedReset = Date(timeIntervalSince1970: 30_000)
            let baseline = ProfileUsageReport(
                usageByProfileID: [
                    firstID: AppServerRateLimitsRead(
                        planType: "pro",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 20,
                                windowDurationMinutes: 300,
                                resetsAt: baselineReset
                            ),
                        ]
                    ),
                    secondID: AppServerRateLimitsRead(
                        planType: "team",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 15,
                                windowDurationMinutes: 300,
                                resetsAt: baselineReset
                            ),
                        ]
                    ),
                ],
                failedProfileIDs: []
            )
            let changed = ProfileUsageReport(
                usageByProfileID: [
                    firstID: AppServerRateLimitsRead(
                        planType: "pro",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 0,
                                windowDurationMinutes: 300,
                                resetsAt: firstChangedReset
                            ),
                        ]
                    ),
                ],
                failedProfileIDs: []
            )
            let fullRecheck = ProfileUsageReport(
                usageByProfileID: [
                    firstID: AppServerRateLimitsRead(
                        planType: "pro",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 0,
                                windowDurationMinutes: 300,
                                resetsAt: firstChangedReset
                            ),
                        ]
                    ),
                    secondID: AppServerRateLimitsRead(
                        planType: "team",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 0,
                                windowDurationMinutes: 300,
                                resetsAt: baselineReset
                            ),
                        ]
                    ),
                ],
                failedProfileIDs: []
            )
            let afterFirst = ProfileUsageReport(
                usageByProfileID: [
                    firstID: AppServerRateLimitsRead(
                        planType: "pro",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 1,
                                windowDurationMinutes: 300,
                                resetsAt: firstChangedReset
                            ),
                        ]
                    ),
                ],
                failedProfileIDs: []
            )
            let afterSecond = ProfileUsageReport(
                usageByProfileID: [
                    secondID: AppServerRateLimitsRead(
                        planType: "team",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 1,
                                windowDurationMinutes: 300,
                                resetsAt: secondChangedReset
                            ),
                        ]
                    ),
                ],
                failedProfileIDs: []
            )
            let provider = MenuBarProviderSpy(profiles: profiles)
            let usageLoads = UsageReportSequence(
                reports: [baseline, changed, fullRecheck, afterFirst, afterSecond]
            )
            let tokenUses = TokenUseProbe()
            let model = await makeMenuBarModel(
                provider: provider,
                loadProfileUsage: { profileIDs in
                    await usageLoads.load(profileIDs: profileIDs)
                },
                useToken: { profileID in
                    await tokenUses.record(profileID)
                },
                initialAutomaticTokenUseEnabled: true
            )

            await model.load()
            await model.refreshUsageAutomatically(now: Date.now.addingTimeInterval(121))

            let usedProfileIDs = await tokenUses.profileIDs
            let usageLoadEvents = await usageLoads.events
            try expect(
                usedProfileIDs == [firstID, secondID],
                "one reset did not trigger all full accounts sequentially"
            )
            try expect(
                usageLoadEvents == ["all", "active", "all", "active", "active"],
                "reset detection did not recheck all accounts before token use"
            )
        },
        TestCase("MenuBarViewModel cancels automatic usage before an account action") {
            let profiles = menuBarProfiles()
            let activeID = profiles[0].id
            let report = ProfileUsageReport(
                usageByProfileID: [
                    activeID: AppServerRateLimitsRead(
                        planType: "pro",
                        windows: [
                            AppServerRateLimitWindow(
                                usedPercent: 20,
                                windowDurationMinutes: 300,
                                resetsAt: nil
                            ),
                        ]
                    ),
                ],
                failedProfileIDs: []
            )
            let provider = MenuBarProviderSpy(profiles: profiles)
            let usageProbe = AutomaticUsageRefreshProbe(report: report)
            let model = await makeMenuBarModel(
                provider: provider,
                loadProfileUsage: { try await usageProbe.load(profileIDs: $0) }
            )

            await model.load()
            let automaticRefresh = Task {
                await model.refreshUsageAutomatically(
                    now: Date.now.addingTimeInterval(120)
                )
            }
            await usageProbe.waitUntilAutomaticRefreshStarted()

            let refreshState = await MainActor.run {
                (model.isWorking, model.isAutomaticallyRefreshing)
            }
            try expect(
                !refreshState.0 && refreshState.1,
                "automatic refresh did not expose a non-blocking visual state"
            )
            let firstSelection = Task { await model.select(profiles[0]) }
            await usageProbe.waitUntilCancellationStarted()
            let secondSelection = Task { await model.select(profiles[0]) }
            for _ in 0..<10 { await Task.yield() }
            let eventsBeforeCancellationFinished = await provider.events
            try expect(
                eventsBeforeCancellationFinished.isEmpty,
                "a second account action bypassed automatic refresh cancellation"
            )
            await usageProbe.finishCancellation()
            await firstSelection.value
            await secondSelection.value
            await automaticRefresh.value

            let cancellationCount = await usageProbe.cancellationCount
            let events = await provider.events
            let stillRefreshing = await MainActor.run { model.isAutomaticallyRefreshing }
            try expect(
                cancellationCount == 1 && events == ["activate"] && !stillRefreshing,
                "account action did not preempt automatic refresh"
            )
        },
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
        TestCase("MenuBarViewModel explains an independent CLI switch blocker") {
            let provider = MenuBarProviderSpy(profiles: menuBarProfiles())
            let model = await makeMenuBarModel(
                provider: provider,
                switchProfile: { _, _ in
                    throw SwitchCoordinatorFailure.independentCodexBlocked
                }
            )
            await model.load()
            guard let target = await MainActor.run(body: {
                model.profiles.first(where: { !$0.active })
            }) else {
                throw TestFailure(description: "switch blocker fixture has no inactive profile")
            }

            await model.select(target)
            await model.confirmSwitch()
            let message = await MainActor.run { model.errorMessage }

            try expect(
                message == "Codex CLI 또는 IDE 작업이 실행 중입니다. 해당 작업을 종료한 뒤 다시 시도하세요.",
                "independent CLI switch blocker was reported as a generic failure"
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
            let additionalStatus = await MainActor.run { model.statusMessage }
            let labelsAfterAdditional = await provider.capturedLabels
            try expect(additionalRegistered, "additional menu bar registration reported failure")
            try expect(labelsAfterAdditional == ["개인", "회사"], "additional registration label changed")
            try expect(
                profilesAfterAdditional.count == 2
                    && profilesAfterAdditional[0].active
                    && !profilesAfterAdditional[1].active,
                "additional registration changed the active profile"
            )
            try expect(
                additionalStatus == "회사 계정을 등록했습니다. 현재 계정은 유지됩니다. 전환하려면 계정을 선택하세요.",
                "additional registration status changed"
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
            let launchFailureRecovery = await MainActor.run { launchFailureModel.recoveryStatus }
            try expect(!committedDespiteLaunchFailure, "thrown Core registration was reported successful")
            try expect(launchFailureProfiles.count == 2, "committed profile was not reloaded after launch failure")
            try expect(
                launchFailureMessage == "계정 등록 완료 여부를 확인하지 못했습니다. 계정 작업을 중단했습니다.",
                "thrown Core registration did not fail closed"
            )
            try expect(launchFailureRecovery == .blocked, "uncertain registration did not block mutations")

            let refreshFailureProvider = MenuBarProviderSpy(profiles: [menuBarProfiles()[0]])
            let refreshFailureModel = await makeMenuBarModel(
                provider: refreshFailureProvider,
                useInjectedProfileLoad: true
            )
            await refreshFailureModel.load()
            await refreshFailureProvider.failNextProfileLoad()
            let reconciledRefreshFailure = await refreshFailureModel.register(label: "회사")
            let refreshFailureMessage = await MainActor.run { refreshFailureModel.errorMessage }
            let refreshFailureStatus = await MainActor.run { refreshFailureModel.statusMessage }
            try expect(reconciledRefreshFailure, "returned registration was lost after reload failure")
            try expect(refreshFailureMessage == nil, "reconciled registration left an error")
            try expect(
                refreshFailureStatus == "회사 계정을 등록했습니다. 현재 계정은 유지됩니다. 전환하려면 계정을 선택하세요.",
                "reconciled registration status changed"
            )

            let precommitFailureProvider = MenuBarProviderSpy(
                profiles: [menuBarProfiles()[0]],
                captureFailureAfterMutation: true,
                captureRecoveryStatusAfterFailure: .none,
                captureNeedsRelogin: true
            )
            let precommitFailureModel = await makeMenuBarModel(provider: precommitFailureProvider)
            await precommitFailureModel.load()
            let precommitSucceeded = await precommitFailureModel.register(label: "회사")
            let precommitProfiles = await MainActor.run { precommitFailureModel.profiles }
            let precommitMessage = await MainActor.run { precommitFailureModel.errorMessage }

            try expect(!precommitSucceeded, "inactive preserved profile was reported as committed")
            try expect(
                precommitProfiles.count == 2
                    && precommitProfiles[0].active
                    && !precommitProfiles[1].active
                    && precommitProfiles[1].needsRelogin,
                "pre-commit rollback state was not reloaded"
            )
            try expect(
                precommitMessage == "계정 등록을 완료하지 못했습니다.",
                "pre-commit failure was reported as a launch failure"
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
        TestCase("MenuBarViewModel explains registration compatibility and process blockers") {
            let provider = MenuBarProviderSpy(profiles: [])
            let model = await makeMenuBarModel(
                provider: provider,
                captureProfile: { label in
                    if label == "호환성" {
                        throw CodexAppLocatorFailure.invalidSignature
                    }
                    throw LocalCLIDataProviderFailure.processBlocked
                }
            )

            await model.load()
            _ = await model.register(label: "호환성")
            let compatibilityMessage = await MainActor.run { model.errorMessage }
            try expect(
                compatibilityMessage == "설치된 Codex 앱의 무결성 또는 호환성을 확인하지 못했습니다. 공식 앱을 다시 설치하거나 업데이트하세요.",
                "registration compatibility failure was not actionable"
            )

            _ = await model.register(label: "프로세스")
            let processMessage = await MainActor.run { model.errorMessage }
            try expect(
                processMessage == "독립 Codex CLI와 IDE 작업을 종료한 뒤 다시 시도하세요.",
                "registration process blocker was not actionable"
            )
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
            let rollbackRetry = await MainActor.run { model.canRetryRecovery }
            try expect(
                rollbackMessage == "자동 복구에 실패했습니다. 회사 계정 복구가 필요합니다.",
                "rollback recovery did not identify the exact previous profile"
            )
            try expect(rollbackProfile?.id == previous.id, "rollback recovery action targeted another profile")
            try expect(!rollbackRetry, "rollbackFailed exposed the non-terminal retry action")

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
            let interruptedRetry = await MainActor.run { interruptedModel.canRetryRecovery }
            try expect(
                interruptedMessage == "중단된 계정 작업 복구가 필요합니다. 단계: currentSaved",
                "pending recovery phase was not shown safely"
            )
            try expect(interruptedRecoveryProfile == nil, "non-rollback recovery exposed a restore action")
            try expect(!interruptedRetry, "model without a retry implementation exposed a retry action")
        },
        TestCase("MenuBarViewModel explicitly retries a non-terminal recovery once") {
            let previous = menuBarProfiles()[0]
            let transactionID = "00000000-0000-0000-0000-000000000012"
            let provider = MenuBarProviderSpy(
                profiles: menuBarProfiles(),
                recoveryStatus: .pending(
                    transactionID: transactionID,
                    phase: .quiescent,
                    previousProfileID: previous.id
                )
            )
            let retries = RefreshOrderRecorder()
            let model = await makeMenuBarModel(
                provider: provider,
                useInjectedProfileLoad: true,
                retryPendingRecovery: { requestedTransactionID in
                    await retries.record(requestedTransactionID)
                    await provider.setRecoveryStatus(.none)
                    await provider.failNextProfileLoad()
                    return .completed(.cancelBeforeMutation)
                }
            )

            await model.load()
            let availableBefore = await MainActor.run { model.canRetryRecovery }
            await model.retryRecovery()
            await model.retryRecovery()
            let requestedTransactions = await retries.events
            let availableAfter = await MainActor.run { model.canRetryRecovery }
            let recoveryStatus = await MainActor.run { model.recoveryStatus }
            let statusMessage = await MainActor.run { model.statusMessage }
            let errorMessage = await MainActor.run { model.errorMessage }

            try expect(availableBefore, "quiescent recovery did not expose retry")
            try expect(requestedTransactions == [transactionID], "explicit recovery retried a stale transaction")
            try expect(!availableAfter, "completed recovery left retry enabled")
            try expect(recoveryStatus == .none, "completed recovery left pending status")
            try expect(statusMessage == "중단된 계정 작업을 복구했습니다. Codex 앱을 직접 여세요.", "recovery success message changed")
            try expect(errorMessage == nil, "completed recovery left an error")
        },
        TestCase("MenuBarViewModel exposes an explicit rollbackFailed retry") {
            let previous = menuBarProfiles()[0]
            let transactionID = "00000000-0000-0000-0000-000000000014"
            let pending = RecoveryCLIStatus.pending(
                transactionID: transactionID,
                phase: .rollbackFailed,
                previousProfileID: previous.id
            )
            let provider = MenuBarProviderSpy(profiles: menuBarProfiles(), recoveryStatus: pending)
            let retries = RefreshOrderRecorder()
            let model = await makeMenuBarModel(
                provider: provider,
                retryPendingRecovery: { requestedTransactionID in
                    await retries.record(requestedTransactionID)
                    return .stopped(.processBlockerPresent)
                }
            )

            await model.load()
            let available = await MainActor.run { model.canRetryRecovery }
            await model.retryRecovery()
            let requestedTransactions = await retries.events
            let errorMessage = await MainActor.run { model.errorMessage }

            try expect(available, "rollbackFailed recovery did not expose the safe retry")
            try expect(requestedTransactions == [transactionID], "rollbackFailed retry used the wrong transaction")
            try expect(
                errorMessage == "Codex 앱 또는 관련 프로세스가 남아 복구하지 못했습니다.",
                "rollbackFailed retry did not explain the process blocker"
            )
        },
        TestCase("MenuBarViewModel explains an unverified explicit recovery") {
            let previous = menuBarProfiles()[0]
            let pending = RecoveryCLIStatus.pending(
                transactionID: "00000000-0000-0000-0000-000000000013",
                phase: .quiescent,
                previousProfileID: previous.id
            )
            let provider = MenuBarProviderSpy(profiles: menuBarProfiles(), recoveryStatus: pending)
            let model = await makeMenuBarModel(
                provider: provider,
                retryPendingRecovery: { _ in .stopped(.activeCredentialUnverified) }
            )

            await model.load()
            await model.retryRecovery()
            let recoveryStatus = await MainActor.run { model.recoveryStatus }
            let retryAvailable = await MainActor.run { model.canRetryRecovery }
            let errorMessage = await MainActor.run { model.errorMessage }

            try expect(recoveryStatus == pending, "stopped retry lost the pending journal")
            try expect(retryAvailable, "safe STOP removed the retry action")
            try expect(
                errorMessage == "현재 로그인 계정을 확인하지 못했습니다. 이전 활성 계정으로 로그인한 뒤 재시도하세요.",
                "unverified recovery was not actionable"
            )
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
                profiles.contains { $0.id == target.id && !$0.active && !$0.needsRelogin },
                "relogin did not refresh the inactive target"
            )
            try expect(
                profiles.contains { $0.id != target.id && $0.active },
                "relogin changed the active source"
            )
            try expect(
                statusMessage == "회사 계정 인증을 갱신했습니다. 현재 계정은 유지됩니다. 전환하려면 계정을 다시 선택하세요.",
                "relogin success did not explain the preserved active account"
            )
        },
        TestCase("MenuBarViewModel cancels an isolated profile login without mutation") {
            let initialProfiles = menuBarReloginProfiles()
            let provider = MenuBarProviderSpy(profiles: initialProfiles)
            let cancellation = ProfileLoginCancellationProbe()
            let model = await makeMenuBarModel(
                provider: provider,
                reloginProfile: { try await cancellation.relogin(target: $0) },
                cancelProfileLogin: { await cancellation.cancel() }
            )
            await model.load()
            guard let target = await MainActor.run(body: {
                model.profiles.first(where: { !$0.active && $0.needsRelogin })
            }) else {
                throw TestFailure(description: "cancel fixture has no relogin target")
            }

            await model.select(target)
            let reloginTask = Task { await model.confirmRelogin(target) }
            await cancellation.waitUntilStarted()
            let inProgress = await MainActor.run { model.isProfileLoginInProgress }
            try expect(inProgress, "profile login did not expose cancellable progress")

            await model.cancelProfileLogin()
            await reloginTask.value

            let cancelCount = await cancellation.cancelCount
            let targets = await cancellation.targets
            let profiles = await MainActor.run { model.profiles }
            let statusMessage = await MainActor.run { model.statusMessage }
            let errorMessage = await MainActor.run { model.errorMessage }
            let isWorking = await MainActor.run { model.isWorking }
            let isLoginInProgress = await MainActor.run { model.isProfileLoginInProgress }
            try expect(cancelCount == 1, "profile login cancellation did not reach Core exactly once")
            try expect(targets == [target.id.description], "cancelled login changed the exact target")
            try expect(profiles == initialProfiles, "cancelled login mutated source or target state")
            try expect(
                statusMessage == "로그인을 취소했습니다. 현재 계정과 저장된 인증은 바뀌지 않았습니다.",
                "cancelled login did not report preserved account state"
            )
            try expect(errorMessage == nil, "cancelled login was reported as an error")
            try expect(!isWorking, "cancelled login left the menu busy")
            try expect(!isLoginInProgress, "cancelled login left cancellation controls visible")
        },
        TestCase("MenuBarViewModel cancels isolated account registration without mutation") {
            let initialProfiles = [menuBarProfiles()[0]]
            let provider = MenuBarProviderSpy(profiles: initialProfiles)
            let cancellation = ProfileLoginCancellationProbe()
            let model = await makeMenuBarModel(
                provider: provider,
                captureProfile: { try await cancellation.capture(label: $0) },
                cancelProfileLogin: { await cancellation.cancel() }
            )
            await model.load()

            let registrationTask = Task { await model.register(label: "회사") }
            await cancellation.waitUntilStarted()
            let inProgress = await MainActor.run { model.isProfileLoginInProgress }
            try expect(inProgress, "additional registration did not expose cancellable progress")

            await model.cancelProfileLogin()
            let registered = await registrationTask.value

            let cancelCount = await cancellation.cancelCount
            let labels = await cancellation.labels
            let profiles = await MainActor.run { model.profiles }
            let statusMessage = await MainActor.run { model.statusMessage }
            let errorMessage = await MainActor.run { model.errorMessage }
            let isWorking = await MainActor.run { model.isWorking }
            let isLoginInProgress = await MainActor.run { model.isProfileLoginInProgress }
            try expect(!registered, "cancelled registration reported success")
            try expect(cancelCount == 1, "registration cancellation did not reach Core exactly once")
            try expect(labels == ["회사"], "cancelled registration changed its label")
            try expect(profiles == initialProfiles, "cancelled registration mutated profiles")
            try expect(
                statusMessage == "로그인을 취소했습니다. 현재 계정과 저장된 인증은 바뀌지 않았습니다.",
                "cancelled registration did not report preserved account state"
            )
            try expect(errorMessage == nil, "cancelled registration was reported as an error")
            try expect(!isWorking, "cancelled registration left the menu busy")
            try expect(!isLoginInProgress, "cancelled registration left cancellation controls visible")
        },
        TestCase("MenuBarViewModel does not lose cancellation before registration starts") {
            let initialProfiles = [menuBarProfiles()[0]]
            let provider = MenuBarProviderSpy(profiles: initialProfiles)
            let model = await makeMenuBarModel(
                provider: provider,
                captureProfile: { _ in
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch is CancellationError {
                        throw CodexLoginFailure(code: .cancelled, childDisposition: .notStarted)
                    }
                    throw MenuBarProviderSpyFailure.captureFailed
                }
            )
            await model.load()

            let registrationTask = Task { await model.register(label: "회사") }
            while await MainActor.run(body: { !model.isProfileLoginInProgress }) {
                await Task.yield()
            }
            await model.cancelProfileLogin()
            let registered = await registrationTask.value

            let profiles = await MainActor.run { model.profiles }
            let statusMessage = await MainActor.run { model.statusMessage }
            try expect(!registered, "early cancellation reported registration success")
            try expect(profiles == initialProfiles, "early cancellation mutated profiles")
            try expect(
                statusMessage == "로그인을 취소했습니다. 현재 계정과 저장된 인증은 바뀌지 않았습니다.",
                "early cancellation was lost before Core started"
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
        TestCase("MenuBarViewModel fails closed when relogin throws after mutation") {
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
            let committedRecovery = await MainActor.run { committedModel.recoveryStatus }
            try expect(committedTargets == [committedTarget.id.description], "committed throw retried relogin")
            try expect(
                committedError == "계정 재로그인 완료 여부를 확인하지 못했습니다. 계정 작업을 중단했습니다.",
                "committed throw was reported as successful"
            )
            try expect(committedStatus == nil, "committed throw kept a success status")
            try expect(committedRecovery == .blocked, "committed throw did not fail closed")

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
                reloginOutcome: .refreshed(
                    ProfileListItem(
                        id: wrongProfile.id,
                        label: wrongProfile.label,
                        email: wrongProfile.email,
                        active: false,
                        needsRelogin: false
                    )
                ),
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
        TestCase("MenuBarViewModel confirms and removes the exact inactive profile") {
            let provider = MenuBarProviderSpy(profiles: menuBarProfiles())
            let model = await makeMenuBarModel(provider: provider)
            await model.load()
            guard let target = await MainActor.run(body: {
                model.profiles.first(where: { !$0.active })
            }) else {
                throw TestFailure(description: "removal fixture has no inactive target")
            }

            await MainActor.run { model.requestRemoval(target) }
            let pending = await MainActor.run { model.pendingRemovalProfile }
            await model.confirmRemoval()

            let removedProfileIDs = await provider.removedProfileIDs
            let remainingProfiles = await MainActor.run { model.profiles }
            let statusMessage = await MainActor.run { model.statusMessage }
            try expect(pending == target, "removal confirmation changed the target")
            try expect(removedProfileIDs == [target.id], "removal reached Core with another target")
            try expect(
                !remainingProfiles.contains(where: { $0.id == target.id }),
                "removed profile remains in the menu"
            )
            try expect(
                remainingProfiles.filter(\.active).count == 1,
                "removal changed the active profile invariant"
            )
            try expect(
                statusMessage == "\(target.label) 계정의 로컬 저장본을 삭제했습니다.",
                "removal success was not reported"
            )
        },
        TestCase("MenuBarViewModel blocks cancelled active and stale removals") {
            let provider = MenuBarProviderSpy(profiles: menuBarProfiles())
            let model = await makeMenuBarModel(provider: provider)
            await model.load()
            let loaded = await MainActor.run { model.profiles }
            guard let active = loaded.first(where: \.active),
                  let target = loaded.first(where: { !$0.active }) else {
                throw TestFailure(description: "removal gate fixture is incomplete")
            }

            await MainActor.run { model.requestRemoval(active) }
            let activePending = await MainActor.run { model.pendingRemovalProfile }
            try expect(activePending == nil, "active profile exposed removal confirmation")

            await MainActor.run {
                model.requestRemoval(target)
                model.cancelRemoval()
            }
            await model.confirmRemoval()
            let removedAfterCancel = await provider.removedProfileIDs
            try expect(removedAfterCancel.isEmpty, "cancelled removal reached Core")

            await MainActor.run { model.requestRemoval(target) }
            await provider.setProfiles(loaded.map { profile in
                guard profile.id == target.id else { return profile }
                return ProfileListItem(
                    id: profile.id,
                    label: "변경됨",
                    email: profile.email,
                    active: profile.active,
                    needsRelogin: profile.needsRelogin
                )
            })
            await model.confirmRemoval()

            let removedProfileIDs = await provider.removedProfileIDs
            let errorMessage = await MainActor.run { model.errorMessage }
            try expect(removedProfileIDs.isEmpty, "stale removal reached Core")
            try expect(
                errorMessage == "삭제 대상 상태가 변경되었습니다. 계정 정보를 다시 확인하세요.",
                "stale removal did not explain the rejection"
            )
        },
        TestCase("MenuBarViewModel reconciles a committed removal throw") {
            let provider = MenuBarProviderSpy(profiles: menuBarProfiles())
            let model = await makeMenuBarModel(
                provider: provider,
                removeProfile: { profileID in
                    _ = try await provider.removeProfile(profileID)
                    throw MenuBarProviderSpyFailure.removeFailed
                }
            )
            await model.load()
            guard let target = await MainActor.run(body: {
                model.profiles.first(where: { !$0.active })
            }) else {
                throw TestFailure(description: "committed removal fixture has no inactive target")
            }

            await MainActor.run { model.requestRemoval(target) }
            await model.confirmRemoval()

            let statusMessage = await MainActor.run { model.statusMessage }
            let errorMessage = await MainActor.run { model.errorMessage }
            try expect(
                statusMessage == "\(target.label) 계정의 로컬 저장본을 삭제했습니다.",
                "committed removal throw was not reconciled"
            )
            try expect(errorMessage == nil, "committed removal throw remained an error")
        },
    ]
}

private actor RefreshOrderRecorder {
    private(set) var events = [String]()

    func record(_ event: String) {
        events.append(event)
    }
}

private actor UsageReportSequence {
    private var reports: [ProfileUsageReport]
    private(set) var events = [String]()

    init(reports: [ProfileUsageReport]) {
        self.reports = reports
    }

    func load(profileIDs: Set<ProfileID>?) -> ProfileUsageReport {
        events.append(profileIDs == nil ? "all" : "active")
        return reports.removeFirst()
    }
}

private actor AutomaticUsageRefreshProbe {
    private let report: ProfileUsageReport
    private var loadCount = 0
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var cancellationStartedContinuation: CheckedContinuation<Void, Never>?
    private var finishCancellationContinuation: CheckedContinuation<Void, Never>?
    private var automaticRefreshStarted = false
    private var cancellationStarted = false
    private(set) var cancellationCount = 0

    init(report: ProfileUsageReport) {
        self.report = report
    }

    func load(profileIDs: Set<ProfileID>?) async throws -> ProfileUsageReport {
        loadCount += 1
        guard loadCount == 2 else { return report }
        automaticRefreshStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        do {
            try await Task.sleep(for: .seconds(10))
            return report
        } catch is CancellationError {
            cancellationCount += 1
            cancellationStarted = true
            cancellationStartedContinuation?.resume()
            cancellationStartedContinuation = nil
            await withCheckedContinuation { continuation in
                finishCancellationContinuation = continuation
            }
            throw CancellationError()
        }
    }

    func waitUntilAutomaticRefreshStarted() async {
        guard !automaticRefreshStarted else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func waitUntilCancellationStarted() async {
        guard !cancellationStarted else { return }
        await withCheckedContinuation { continuation in
            cancellationStartedContinuation = continuation
        }
    }

    func finishCancellation() {
        finishCancellationContinuation?.resume()
        finishCancellationContinuation = nil
    }
}

private actor ProfileLoginCancellationProbe {
    private var loginContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var cancellationRequested = false
    private(set) var cancelCount = 0
    private(set) var targets = [String]()
    private(set) var labels = [String]()

    func capture(label: String) async throws -> ProfileListItem {
        labels.append(label)
        try await suspendUntilCancelled()
        throw CodexLoginFailure(code: .cancelled, childDisposition: .confirmedExited)
    }

    func relogin(target: String) async throws -> ProfileReloginOutcome {
        targets.append(target)
        try await suspendUntilCancelled()
        throw CodexLoginFailure(code: .cancelled, childDisposition: .confirmedExited)
    }

    private func suspendUntilCancelled() async throws {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { continuation in
            if cancellationRequested {
                continuation.resume()
            } else {
                loginContinuation = continuation
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func cancel() {
        cancelCount += 1
        cancellationRequested = true
        loginContinuation?.resume()
        loginContinuation = nil
    }
}

private func makeMenuBarModel(
    provider: MenuBarProviderSpy,
    useInjectedProfileLoad: Bool = false,
    loadProfileUsage: MenuBarViewModel.LoadProfileUsage? = nil,
    useToken: MenuBarViewModel.UseToken? = nil,
    initialAutomaticTokenUseEnabled: Bool? = nil,
    captureProfile: MenuBarViewModel.CaptureProfile? = nil,
    removeProfile: MenuBarViewModel.RemoveProfile? = nil,
    retryPendingRecovery: MenuBarViewModel.RetryPendingRecovery? = nil,
    switchProfile: MenuBarViewModel.SwitchProfile? = nil,
    reloginProfile: MenuBarViewModel.ReloginProfile? = nil,
    cancelProfileLogin: @escaping MenuBarViewModel.CancelProfileLogin = {}
) async -> MenuBarViewModel {
    await MainActor.run {
        MenuBarViewModel(
            loadProfiles: {
                if useInjectedProfileLoad {
                    return try await provider.profilesWithInjectedFailure()
                }
                return await provider.profiles()
            },
            loadProfileUsage: loadProfileUsage,
            loadRecoveryStatus: { await provider.recoveryStatus() },
            useToken: useToken,
            captureProfile: captureProfile ?? { try await provider.captureProfile(label: $0) },
            removeProfile: removeProfile ?? { try await provider.removeProfile($0) },
            syncActiveProfile: { try await provider.syncActiveProfile() },
            switchProfile: switchProfile ?? {
                try await provider.switchProfile(target: $0, onPhaseChange: $1)
            },
            reloginProfile: reloginProfile ?? { try await provider.reloginProfile(target: $0) },
            cancelProfileLogin: cancelProfileLogin,
            restoreRecoveryProfile: {
                try await provider.restoreRecoveryProfile(target: $0, expectedTransactionID: $1)
            },
            retryPendingRecovery: retryPendingRecovery,
            attemptAutomaticRecovery: {},
            initialAutomaticTokenUseEnabled: initialAutomaticTokenUseEnabled
        )
    }
}

private actor TokenUseProbe {
    private(set) var profileIDs = [ProfileID]()

    func record(_ profileID: ProfileID) {
        profileIDs.append(profileID)
    }
}

private actor ProfileUsageLoadProbe {
    private(set) var profileIDs = [Set<ProfileID>?]()

    func record(_ profileIDs: Set<ProfileID>?) {
        self.profileIDs.append(profileIDs)
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

private actor SleepPreventionProbe {
    private var enabled: Bool
    private var appliesChanges = true
    private var readsFail = false
    private(set) var requests = [Bool]()

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func read() throws -> Bool {
        if readsFail { throw SleepPreventionProbeError.readFailed }
        return enabled
    }

    func set(_ enabled: Bool) {
        requests.append(enabled)
        if appliesChanges { self.enabled = enabled }
    }

    func stopApplyingChanges() {
        appliesChanges = false
    }

    func failReads() {
        readsFail = true
    }
}

private enum SleepPreventionProbeError: Error {
    case readFailed
}

private actor SleepGuardSettingProbe {
    private var writesFail = false
    private(set) var requests = [SleepGuardThreshold]()

    func save(_ threshold: SleepGuardThreshold) throws {
        requests.append(threshold)
        if writesFail { throw SleepGuardSettingProbeError.writeFailed }
    }

    func failWrites() {
        writesFail = true
    }
}

private enum SleepGuardSettingProbeError: Error {
    case writeFailed
}

private actor MenuBarProviderSpy {
    private var storedProfiles: [ProfileListItem]
    private let applicationIsRunning: Bool
    private let captureFailureAfterMutation: Bool
    private let captureActivatesProfile: Bool?
    private let captureNeedsRelogin: Bool
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
    private(set) var removedProfileIDs = [ProfileID]()
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
        captureActivatesProfile: Bool? = nil,
        captureNeedsRelogin: Bool = false,
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
        self.captureActivatesProfile = captureActivatesProfile
        self.captureNeedsRelogin = captureNeedsRelogin
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

    func setProfiles(_ profiles: [ProfileListItem]) {
        storedProfiles = profiles
    }

    func failNextProfileLoad() {
        injectedProfileLoadFailurePending = true
    }

    func captureProfile(label: String) throws -> ProfileListItem {
        guard storedProfiles.count < ProfileRegistry.maximumProfileCount else {
            throw MenuBarProviderSpyFailure.captureFailed
        }
        capturedLabels.append(label)
        let activatesProfile = captureActivatesProfile ?? storedProfiles.isEmpty
        if activatesProfile {
            storedProfiles = storedProfiles.map {
                ProfileListItem(
                    id: $0.id,
                    label: $0.label,
                    email: $0.email,
                    active: false,
                    needsRelogin: $0.needsRelogin
                )
            }
        }
        let profile = ProfileListItem(
            id: ProfileID(UUID()),
            label: label,
            email: "captured@example.invalid",
            active: activatesProfile,
            needsRelogin: captureNeedsRelogin
        )
        storedProfiles.append(profile)
        if captureFailureAfterMutation {
            storedRecoveryStatus = captureRecoveryStatusAfterFailure
            throw MenuBarProviderSpyFailure.captureFailed
        }
        return profile
    }

    func removeProfile(_ profileID: ProfileID) throws -> ProfileListItem {
        guard let index = storedProfiles.firstIndex(where: { $0.id == profileID }),
              !storedProfiles[index].active else {
            throw MenuBarProviderSpyFailure.removeFailed
        }
        removedProfileIDs.append(profileID)
        return storedProfiles.remove(at: index)
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
                active: profile.active,
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
        return reloginOutcome ?? .refreshed(updated)
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
    case removeFailed
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
