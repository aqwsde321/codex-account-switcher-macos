import Combine
import CodexAccountCore

@MainActor
public final class MenuBarViewModel: ObservableObject {
    public typealias LoadProfiles = @Sendable () async throws -> [ProfileListItem]
    public typealias LoadRecoveryStatus = @Sendable () async throws -> RecoveryCLIStatus
    public typealias CaptureProfile = @Sendable (String) async throws -> ProfileListItem
    public typealias SyncActiveProfile = @Sendable () async throws -> ProfileListItem
    public typealias SwitchProfile = @Sendable (String) async throws -> ProfileListItem

    @Published public private(set) var profiles = [ProfileListItem]()
    @Published public private(set) var pendingProfile: ProfileListItem?
    @Published public private(set) var recoveryStatus = RecoveryCLIStatus.blocked
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?

    private let loadProfiles: LoadProfiles
    private let loadRecoveryStatus: LoadRecoveryStatus
    private let captureProfile: CaptureProfile
    private let syncActiveProfile: SyncActiveProfile
    private let switchProfile: SwitchProfile

    public init(
        loadProfiles: @escaping LoadProfiles,
        loadRecoveryStatus: @escaping LoadRecoveryStatus,
        captureProfile: @escaping CaptureProfile,
        syncActiveProfile: @escaping SyncActiveProfile,
        switchProfile: @escaping SwitchProfile
    ) {
        self.loadProfiles = loadProfiles
        self.loadRecoveryStatus = loadRecoveryStatus
        self.captureProfile = captureProfile
        self.syncActiveProfile = syncActiveProfile
        self.switchProfile = switchProfile
    }

    public func load() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await refreshState()
            errorMessage = recoveryRequired ? recoveryErrorMessage : nil
        } catch {
            errorMessage = "계정 정보를 불러오지 못했습니다."
        }
    }

    public func select(_ profile: ProfileListItem) async {
        statusMessage = nil
        guard !isWorking, !recoveryRequired else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        if profile.active {
            await performSwitch(to: profile)
        } else {
            // ponytail: first slice confirms every inactive selection; add typed app-running state before skipping confirmation.
            pendingProfile = profile
        }
    }

    public func confirmSwitch(_ confirmedProfile: ProfileListItem? = nil) async {
        guard !isWorking, !recoveryRequired,
              let profile = confirmedProfile ?? pendingProfile else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        pendingProfile = nil
        await performSwitch(to: profile)
    }

    public func cancelSwitch() {
        pendingProfile = nil
    }

    @discardableResult
    public func register(label: String) async -> Bool {
        statusMessage = nil
        guard !isWorking, !recoveryRequired else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return false
        }
        let existingProfileIDs = Set(profiles.map(\.id))
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await captureProfile(label)
            try await refreshState()
            guard !recoveryRequired else {
                errorMessage = recoveryErrorMessage
                return false
            }
            errorMessage = nil
            return true
        } catch {
            await refreshAfterMutationFailure()
            if recoveryRequired {
                errorMessage = recoveryErrorMessage
                return false
            }
            if profiles.contains(where: { !existingProfileIDs.contains($0.id) }) {
                errorMessage = "계정은 등록했지만 Codex 앱을 다시 열지 못했습니다."
                return true
            }
            errorMessage = "계정 등록을 완료하지 못했습니다."
            return false
        }
    }

    public func syncActive() async {
        statusMessage = nil
        guard !isWorking, !recoveryRequired else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await syncActiveProfile()
            try await refreshState()
            guard !recoveryRequired else {
                errorMessage = recoveryErrorMessage
                return
            }
            errorMessage = nil
            statusMessage = "현재 인증을 활성 프로필 저장본에 반영했습니다."
        } catch {
            await refreshAfterMutationFailure()
            errorMessage = recoveryRequired
                ? recoveryErrorMessage
                : "현재 인증을 동기화하지 못했습니다."
        }
    }

    public var recoveryRequired: Bool {
        recoveryStatus != .none
    }

    private func performSwitch(to profile: ProfileListItem) async {
        statusMessage = nil
        guard !recoveryRequired else {
            errorMessage = recoveryErrorMessage
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await switchProfile(profile.id.description)
            try await refreshState()
            errorMessage = recoveryRequired ? recoveryErrorMessage : nil
        } catch {
            await refreshAfterMutationFailure()
            errorMessage = recoveryRequired
                ? recoveryErrorMessage
                : "계정 작업을 완료하지 못했습니다."
        }
    }

    private var recoveryErrorMessage: String {
        switch recoveryStatus {
        case .none:
            return "복구가 필요합니다. 계정 작업을 중단했습니다."
        case let .pending(_, .rollbackFailed, previousProfileID):
            if let profile = profiles.first(where: { $0.id == previousProfileID }) {
                return "자동 복구에 실패했습니다. \(profile.label) 계정 복구가 필요합니다."
            }
            return "자동 복구에 실패했습니다. 이전 계정 복구가 필요합니다."
        case let .pending(_, phase, _):
            return "중단된 계정 작업 복구가 필요합니다. 단계: \(phase.rawValue)"
        case .blocked:
            return "복구 상태가 불명확합니다. 계정 작업을 중단했습니다."
        }
    }

    private func refreshState() async throws {
        recoveryStatus = .blocked
        let loadedProfiles = try await loadProfiles()
        let loadedRecoveryStatus = try await loadRecoveryStatus()
        profiles = loadedProfiles
        recoveryStatus = loadedRecoveryStatus
    }

    private func refreshAfterMutationFailure() async {
        try? await refreshState()
        pendingProfile = nil
    }
}
