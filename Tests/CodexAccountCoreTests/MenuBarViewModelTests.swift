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
                    switchProfile: { try await provider.switchProfile(target: $0) }
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
            let mutationsAfterActive = await provider.mutationCount
            let pendingAfterActive = await MainActor.run { model.pendingProfile }
            try expect(targetsAfterActive == [active.id.description], "active selection did not reach Core once")
            try expect(eventsAfterActive == ["activate"], "running active selection did not only activate the app")
            try expect(mutationsAfterActive == 0, "running active selection mutated account state")
            try expect(pendingAfterActive == nil, "active selection requested switch confirmation")

            await model.select(inactive)
            let targetsBeforeConfirmation = await provider.targets
            let pendingBeforeConfirmation = await MainActor.run { model.pendingProfile }
            try expect(targetsBeforeConfirmation == targetsAfterActive, "inactive selection mutated before confirmation")
            try expect(pendingBeforeConfirmation?.id == inactive.id, "inactive confirmation target changed")

            await MainActor.run { model.cancelSwitch() }
            await model.confirmSwitch(pendingBeforeConfirmation)
            let targetsAfterConfirmation = await provider.targets
            let mutationsAfterConfirmation = await provider.mutationCount
            let finalProfiles = await MainActor.run { model.profiles }
            try expect(
                targetsAfterConfirmation == [active.id.description, inactive.id.description],
                "confirmed inactive selection did not reach Core once"
            )
            try expect(mutationsAfterConfirmation == 1, "confirmed inactive selection mutation count changed")
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
                    switchProfile: { try await closedProvider.switchProfile(target: $0) }
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
        },
        TestCase("MenuBarViewModel registers the current login and reloads profiles") {
            let provider = MenuBarProviderSpy(profiles: [])
            let model = await MainActor.run {
                MenuBarViewModel(
                    loadProfiles: { await provider.profiles() },
                    loadRecoveryStatus: { await provider.recoveryStatus() },
                    captureProfile: { try await provider.captureProfile(label: $0) },
                    switchProfile: { try await provider.switchProfile(target: $0) }
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
                    switchProfile: { try await launchFailureProvider.switchProfile(target: $0) }
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
                    switchProfile: { try await partialFailureProvider.switchProfile(target: $0) }
                )
            }
            await failureModel.load()
            let failed = await failureModel.register(label: "회사")
            let failureMessage = await MainActor.run { failureModel.errorMessage }
            let profilesAfterFailure = await MainActor.run { failureModel.profiles }
            let isWorkingAfterFailure = await MainActor.run { failureModel.isWorking }
            try expect(!failed, "failed registration reported success")
            try expect(
                failureMessage == "복구가 필요합니다. 계정 작업을 중단했습니다.",
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
    ]
}

private actor MenuBarProviderSpy {
    private var storedProfiles: [ProfileListItem]
    private let applicationIsRunning: Bool
    private let captureFailureAfterMutation: Bool
    private let captureRecoveryStatusAfterFailure: RecoveryCLIStatus
    private var storedRecoveryStatus: RecoveryCLIStatus
    private(set) var targets = [String]()
    private(set) var events = [String]()
    private(set) var capturedLabels = [String]()
    private(set) var mutationCount = 0

    init(
        profiles: [ProfileListItem],
        applicationIsRunning: Bool = true,
        captureFailureAfterMutation: Bool = false,
        captureRecoveryStatusAfterFailure: RecoveryCLIStatus = .pending(
            transactionID: "00000000-0000-0000-0000-000000000001",
            phase: .rollbackFailed
        ),
        recoveryStatus: RecoveryCLIStatus = .none
    ) {
        storedProfiles = profiles
        self.applicationIsRunning = applicationIsRunning
        self.captureFailureAfterMutation = captureFailureAfterMutation
        self.captureRecoveryStatusAfterFailure = captureRecoveryStatusAfterFailure
        storedRecoveryStatus = recoveryStatus
    }

    func profiles() -> [ProfileListItem] {
        storedProfiles
    }

    func recoveryStatus() -> RecoveryCLIStatus {
        storedRecoveryStatus
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

    func switchProfile(target: String) throws -> ProfileListItem {
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
}

private enum MenuBarProviderSpyFailure: Error {
    case missingProfile
    case captureFailed
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
