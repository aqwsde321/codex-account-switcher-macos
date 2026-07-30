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
    ]
}

private actor MenuBarProviderSpy {
    private var storedProfiles: [ProfileListItem]
    private let applicationIsRunning: Bool
    private(set) var targets = [String]()
    private(set) var events = [String]()
    private(set) var mutationCount = 0

    init(profiles: [ProfileListItem], applicationIsRunning: Bool = true) {
        storedProfiles = profiles
        self.applicationIsRunning = applicationIsRunning
    }

    func profiles() -> [ProfileListItem] {
        storedProfiles
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
