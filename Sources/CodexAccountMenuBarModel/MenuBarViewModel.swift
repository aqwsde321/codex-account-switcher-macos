import Combine
import CodexAccountCore

@MainActor
public final class MenuBarViewModel: ObservableObject {
    public typealias LoadProfiles = @Sendable () async throws -> [ProfileListItem]
    public typealias SwitchProfile = @Sendable (String) async throws -> ProfileListItem

    @Published public private(set) var profiles = [ProfileListItem]()
    @Published public private(set) var pendingProfile: ProfileListItem?
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?

    private let loadProfiles: LoadProfiles
    private let switchProfile: SwitchProfile

    public init(
        loadProfiles: @escaping LoadProfiles,
        switchProfile: @escaping SwitchProfile
    ) {
        self.loadProfiles = loadProfiles
        self.switchProfile = switchProfile
    }

    public func load() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            profiles = try await loadProfiles()
            errorMessage = nil
        } catch {
            errorMessage = "계정 정보를 불러오지 못했습니다."
        }
    }

    public func select(_ profile: ProfileListItem) async {
        guard !isWorking else { return }
        if profile.active {
            await performSwitch(to: profile)
        } else {
            // ponytail: first slice confirms every inactive selection; add typed app-running state before skipping confirmation.
            pendingProfile = profile
        }
    }

    public func confirmSwitch(_ confirmedProfile: ProfileListItem? = nil) async {
        guard !isWorking, let profile = confirmedProfile ?? pendingProfile else { return }
        pendingProfile = nil
        await performSwitch(to: profile)
    }

    public func cancelSwitch() {
        pendingProfile = nil
    }

    private func performSwitch(to profile: ProfileListItem) async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await switchProfile(profile.id.description)
            profiles = try await loadProfiles()
            errorMessage = nil
        } catch {
            errorMessage = "계정 작업을 완료하지 못했습니다."
        }
    }
}
