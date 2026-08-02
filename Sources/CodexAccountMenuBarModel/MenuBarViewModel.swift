import Combine
import CodexAccountCore

@MainActor
public final class MenuBarViewModel: ObservableObject {
    public struct RecoveryConfirmation: Equatable, Sendable {
        public let profile: ProfileListItem
        public let transactionID: String
    }

    public typealias LoadProfiles = @Sendable () async throws -> [ProfileListItem]
    public typealias LoadRecoveryStatus = @Sendable () async throws -> RecoveryCLIStatus
    public typealias CaptureProfile = @Sendable (String) async throws -> ProfileListItem
    public typealias RemoveProfile = @Sendable (ProfileID) async throws -> ProfileListItem
    public typealias SyncActiveProfile = @Sendable () async throws -> ProfileListItem
    public typealias SwitchProgress = @Sendable (SwitchPhase) async -> Void
    public typealias SwitchProfile = @Sendable (
        String,
        @escaping SwitchProgress
    ) async throws -> ProfileListItem
    public typealias ReloginProfile = @Sendable (String) async throws -> ProfileReloginOutcome
    public typealias RestoreRecoveryProfile = @Sendable (String, String) async throws -> RecoveryRestoreOutcome
    public typealias RetryPendingRecovery = @Sendable (String) async throws -> RecoveryOutcome
    public typealias AttemptAutomaticRecovery = @Sendable () async -> Void

    @Published public private(set) var profiles = [ProfileListItem]()
    @Published public private(set) var pendingProfile: ProfileListItem?
    @Published public private(set) var pendingRemovalProfile: ProfileListItem?
    @Published public private(set) var pendingReloginProfile: ProfileListItem?
    @Published public private(set) var pendingRecoveryConfirmation: RecoveryConfirmation?
    @Published public private(set) var recoveryStatus = RecoveryCLIStatus.blocked
    @Published public private(set) var switchPhase: SwitchPhase?
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?

    private let loadProfiles: LoadProfiles
    private let loadRecoveryStatus: LoadRecoveryStatus
    private let captureProfile: CaptureProfile
    private let removeProfile: RemoveProfile?
    private let syncActiveProfile: SyncActiveProfile
    private let switchProfile: SwitchProfile
    private let reloginProfile: ReloginProfile
    private let restoreRecoveryProfile: RestoreRecoveryProfile
    private let retryPendingRecovery: RetryPendingRecovery?
    private let attemptAutomaticRecovery: AttemptAutomaticRecovery

    public init(
        loadProfiles: @escaping LoadProfiles,
        loadRecoveryStatus: @escaping LoadRecoveryStatus,
        captureProfile: @escaping CaptureProfile,
        removeProfile: RemoveProfile? = nil,
        syncActiveProfile: @escaping SyncActiveProfile,
        switchProfile: @escaping SwitchProfile,
        reloginProfile: @escaping ReloginProfile,
        restoreRecoveryProfile: @escaping RestoreRecoveryProfile,
        retryPendingRecovery: RetryPendingRecovery? = nil,
        attemptAutomaticRecovery: @escaping AttemptAutomaticRecovery = {}
    ) {
        self.loadProfiles = loadProfiles
        self.loadRecoveryStatus = loadRecoveryStatus
        self.captureProfile = captureProfile
        self.removeProfile = removeProfile
        self.syncActiveProfile = syncActiveProfile
        self.switchProfile = switchProfile
        self.reloginProfile = reloginProfile
        self.restoreRecoveryProfile = restoreRecoveryProfile
        self.retryPendingRecovery = retryPendingRecovery
        self.attemptAutomaticRecovery = attemptAutomaticRecovery
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
        } else if profile.needsRelogin {
            pendingReloginProfile = profile
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

    public func requestRemoval(_ profile: ProfileListItem) {
        statusMessage = nil
        pendingRemovalProfile = nil
        guard !isWorking, !recoveryRequired,
              let current = profiles.first(where: { $0.id == profile.id }),
              current == profile,
              !current.active else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        pendingRemovalProfile = current
    }

    public func confirmRemoval(_ confirmedProfile: ProfileListItem? = nil) async {
        guard !isWorking, !recoveryRequired,
              let removeProfile,
              let profile = confirmedProfile ?? pendingRemovalProfile else {
            cancelRemoval()
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        cancelRemoval()
        isWorking = true
        defer { isWorking = false }
        do {
            try await refreshState()
            guard !recoveryRequired,
                  let current = profiles.first(where: { $0.id == profile.id }),
                  current == profile,
                  !current.active else {
                errorMessage = recoveryRequired
                    ? recoveryErrorMessage
                    : "삭제 대상 상태가 변경되었습니다. 계정 정보를 다시 확인하세요."
                return
            }
            _ = try await removeProfile(current.id)
            try await refreshState()
            guard profileRemovalIsComplete(profile.id) else {
                recoveryStatus = .blocked
                errorMessage = "계정 삭제 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                return
            }
            reportRemovalSuccess(profile)
        } catch {
            await refreshAfterMutationFailure()
            if profileRemovalIsComplete(profile.id) {
                reportRemovalSuccess(profile)
            } else if recoveryRequired {
                errorMessage = recoveryErrorMessage
            } else if case LocalCLIDataProviderFailure.activeProfileRemovalForbidden = error {
                errorMessage = "삭제 대상 상태가 변경되었습니다. 계정 정보를 다시 확인하세요."
            } else {
                errorMessage = "계정의 로컬 저장본을 삭제하지 못했습니다."
            }
        }
    }

    public func cancelRemoval() {
        pendingRemovalProfile = nil
    }

    public func confirmRelogin(_ confirmedProfile: ProfileListItem? = nil) async {
        guard !isWorking, !recoveryRequired,
              let profile = confirmedProfile ?? pendingReloginProfile else {
            cancelRelogin()
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        cancelRelogin()
        isWorking = true
        defer { isWorking = false }
        var reloginStarted = false
        var reloginOutcome: ProfileReloginOutcome?
        do {
            try await refreshState()
            guard !recoveryRequired,
                  let current = profiles.first(where: { $0.id == profile.id }),
                  !current.active,
                  current.needsRelogin else {
                errorMessage = recoveryRequired
                    ? recoveryErrorMessage
                    : "재로그인 상태가 변경되었습니다. 계정 정보를 다시 확인하세요."
                return
            }
            reloginStarted = true
            let outcome = try await reloginProfile(current.id.description)
            reloginOutcome = outcome
            try await refreshState()
            if case let .activated(activated) = outcome, activated.id != current.id {
                recoveryStatus = .blocked
            }
            guard profileIsSoleActive(current.id) else {
                if recoveryRequired {
                    errorMessage = recoveryErrorMessage
                } else {
                    recoveryStatus = .blocked
                    errorMessage = "재로그인 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                }
                return
            }
            errorMessage = nil
            statusMessage = if outcome == .journalFinalizationUncertain {
                "\(current.label) 계정 재로그인을 재확인했습니다. Codex 앱을 직접 여세요."
            } else {
                "\(current.label) 계정 재로그인을 반영했습니다. Codex 앱을 직접 여세요."
            }
        } catch {
            await refreshAfterMutationFailure()
            guard reloginStarted else {
                errorMessage = recoveryRequired ? recoveryErrorMessage : "계정 재로그인을 완료하지 못했습니다."
                return
            }
            if case let .activated(activated) = reloginOutcome, activated.id != profile.id {
                recoveryStatus = .blocked
                errorMessage = "재로그인 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                return
            }
            guard profileIsSoleActive(profile.id) else {
                if recoveryRequired {
                    errorMessage = recoveryErrorMessage
                } else if reloginOutcome != nil {
                    recoveryStatus = .blocked
                    errorMessage = "재로그인 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                } else {
                    errorMessage = "계정 재로그인을 완료하지 못했습니다."
                }
                return
            }
            errorMessage = nil
            statusMessage = if reloginOutcome == .journalFinalizationUncertain {
                "\(profile.label) 계정 재로그인을 재확인했습니다. Codex 앱을 직접 여세요."
            } else {
                "\(profile.label) 계정 재로그인을 반영했습니다. Codex 앱을 직접 여세요."
            }
        }
    }

    public func cancelRelogin() {
        pendingReloginProfile = nil
    }

    public var recoveryProfile: ProfileListItem? {
        recoveryCandidate?.profile
    }

    public var pendingRecoveryProfile: ProfileListItem? {
        pendingRecoveryConfirmation?.profile
    }

    public func requestRecovery() {
        statusMessage = nil
        guard !isWorking, let candidate = recoveryCandidate else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        pendingRecoveryConfirmation = RecoveryConfirmation(
            profile: candidate.profile,
            transactionID: candidate.transactionID
        )
    }

    public func confirmRecovery(_ confirmed: RecoveryConfirmation? = nil) async {
        guard !isWorking,
              let confirmation = confirmed ?? pendingRecoveryConfirmation else {
            cancelRecovery()
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        cancelRecovery()
        isWorking = true
        defer { isWorking = false }
        let currentRecoveryStatus: RecoveryCLIStatus
        do {
            currentRecoveryStatus = try await loadRecoveryStatus()
        } catch {
            recoveryStatus = .blocked
            errorMessage = recoveryErrorMessage
            return
        }
        recoveryStatus = currentRecoveryStatus
        guard case let .pending(transactionID, .rollbackFailed, previousProfileID) = currentRecoveryStatus,
              transactionID == confirmation.transactionID,
              previousProfileID == confirmation.profile.id,
              !confirmation.profile.needsRelogin else {
            errorMessage = currentRecoveryStatus == .none
                ? "복구 상태가 변경되었습니다. 계정 정보를 다시 확인하세요."
                : recoveryErrorMessage
            return
        }
        await performRecovery(
            to: confirmation.profile,
            transactionID: confirmation.transactionID
        )
    }

    public func cancelRecovery() {
        pendingRecoveryConfirmation = nil
    }

    public var canRetryRecovery: Bool {
        retryPendingRecovery != nil && retryRecoveryTransactionID != nil
    }

    public func retryRecovery() async {
        guard !isWorking,
              let retryPendingRecovery,
              let transactionID = retryRecoveryTransactionID else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        statusMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await retryPendingRecovery(transactionID)
            try await reloadState()
            if !recoveryRequired {
                errorMessage = nil
                statusMessage = "중단된 계정 작업을 복구했습니다. Codex 앱을 직접 여세요."
                return
            }
            switch outcome {
            case let .stopped(reason):
                errorMessage = recoveryRetryErrorMessage(for: reason)
            case .none, .completed:
                errorMessage = recoveryErrorMessage
            }
        } catch {
            do {
                try await reloadState()
            } catch {
                recoveryStatus = .blocked
            }
            if !recoveryRequired {
                errorMessage = nil
                statusMessage = "중단된 계정 작업을 복구했습니다. Codex 앱을 직접 여세요."
                return
            }
            switch error {
            case LocalCLIDataProviderFailure.pendingRecovery:
                errorMessage = "복구 상태가 변경되었습니다. 다시 확인한 뒤 재시도하세요."
            case RecoveryCoordinatorFailure.snapshotInvalid:
                errorMessage = "복구 상태를 확인하지 못했습니다. Codex 앱을 열지 말고 다시 시도하세요."
            default:
                errorMessage = recoveryRequired
                    ? "중단된 계정 작업을 복구하지 못했습니다."
                    : nil
            }
        }
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
            switch error {
            case is CodexAppLocatorFailure,
                 LocalCLIDataProviderFailure.incompatibleApplication:
                errorMessage = "설치된 Codex 앱의 무결성 또는 호환성을 확인하지 못했습니다. 공식 앱을 다시 설치하거나 업데이트하세요."
            case LocalCLIDataProviderFailure.processBlocked:
                errorMessage = "독립 Codex CLI와 IDE 작업을 종료한 뒤 다시 시도하세요."
            default:
                errorMessage = "계정 등록을 완료하지 못했습니다."
            }
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

    public var switchProgressMessage: String? {
        guard let switchPhase else { return nil }
        return Self.switchProgressMessage(for: switchPhase)
    }

    package static func switchProgressMessage(for phase: SwitchPhase) -> String {
        switch phase {
        case .preparing:
            return "전환 준비 중…"
        case .quitRequested:
            return "Codex 앱 종료 및 프로세스 확인 중…"
        case .quiescent:
            return "현재 계정 확인 중…"
        case .refreshingCurrent:
            return "현재 계정 인증 갱신 중…"
        case .currentSaved:
            return "대상 계정 준비 중…"
        case .validatingTarget:
            return "대상 계정 인증 확인 중…"
        case .targetValidated:
            return "대상 계정 인증 적용 중…"
        case .authReplaced:
            return "Codex 앱 실행 중…"
        case .targetLaunched, .verifyingTarget:
            return "대상 계정 확인 중…"
        case .targetVerified:
            return "전환 완료 처리 중…"
        case .rollbackStarted:
            return "문제가 발생해 이전 계정 복구 중…"
        case .rollbackFailed:
            return "자동 복구 실패. 앱을 열지 말고 복구하세요."
        }
    }

    private var recoveryCandidate: (transactionID: String, profile: ProfileListItem)? {
        guard case let .pending(transactionID, .rollbackFailed, previousProfileID) = recoveryStatus,
              let profile = profiles.first(where: { $0.id == previousProfileID }),
              !profile.needsRelogin else {
            return nil
        }
        return (transactionID, profile)
    }

    private var retryRecoveryTransactionID: String? {
        guard case let .pending(transactionID, _, _) = recoveryStatus else {
            return nil
        }
        return transactionID
    }

    private func performSwitch(to profile: ProfileListItem) async {
        statusMessage = nil
        guard !recoveryRequired else {
            errorMessage = recoveryErrorMessage
            return
        }
        isWorking = true
        switchPhase = nil
        defer {
            switchPhase = nil
            isWorking = false
        }
        do {
            _ = try await switchProfile(profile.id.description) { [weak self] phase in
                await self?.setSwitchPhase(phase)
            }
            try await refreshState()
            errorMessage = recoveryRequired ? recoveryErrorMessage : nil
        } catch {
            await refreshAfterMutationFailure()
            if recoveryRequired {
                errorMessage = recoveryErrorMessage
            } else if profiles.contains(where: { $0.id == profile.id && $0.needsRelogin }) {
                errorMessage = "\(profile.label) 계정은 재로그인이 필요합니다."
            } else {
                errorMessage = "계정 작업을 완료하지 못했습니다."
            }
        }
    }

    private func performRecovery(to profile: ProfileListItem, transactionID: String) async {
        statusMessage = nil
        do {
            let outcome = try await restoreRecoveryProfile(profile.id.description, transactionID)
            do {
                try await refreshState()
            } catch {
                recoveryStatus = .blocked
            }
            switch outcome {
            case let .restoredAndLaunched(restored):
                guard restored.id == profile.id, profileIsSoleActive(profile.id) else {
                    recoveryStatus = .blocked
                    errorMessage = "복구 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                    return
                }
                errorMessage = nil
                statusMessage = "\(profile.label) 계정을 복구하고 Codex 앱을 열었습니다."
            case let .restoredButLaunchUnconfirmed(restored):
                guard restored.id == profile.id, profileIsSoleActive(profile.id) else {
                    recoveryStatus = .blocked
                    errorMessage = "복구 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                    return
                }
                errorMessage = "\(profile.label) 계정은 복구했지만 Codex 앱 실행을 확인하지 못했습니다. 복구를 다시 시도하지 말고 앱만 직접 여세요."
            case .journalFinalizationUncertain:
                guard profileIsSoleActive(profile.id) else {
                    recoveryStatus = .blocked
                    errorMessage = "복구 완료 여부가 불명확합니다. 앱을 열거나 계정 작업을 하지 마세요."
                    return
                }
                errorMessage = nil
                statusMessage = "\(profile.label) 계정 복구를 재확인했습니다. Codex 앱은 열지 않았습니다."
            }
        } catch {
            await refreshAfterMutationFailure()
            errorMessage = recoveryRequired
                ? recoveryErrorMessage
                : "계정 복구를 완료하지 못했습니다."
        }
    }

    private func profileIsSoleActive(_ profileID: ProfileID) -> Bool {
        recoveryStatus == .none
            && profiles.filter(\.active).count == 1
            && profiles.contains { $0.id == profileID && $0.active && !$0.needsRelogin }
    }

    private func profileRemovalIsComplete(_ profileID: ProfileID) -> Bool {
        recoveryStatus == .none
            && !profiles.contains(where: { $0.id == profileID })
            && profiles.filter(\.active).count == 1
    }

    private func reportRemovalSuccess(_ profile: ProfileListItem) {
        errorMessage = nil
        statusMessage = "\(profile.label) 계정의 로컬 저장본을 삭제했습니다."
    }

    private func setSwitchPhase(_ phase: SwitchPhase) {
        switchPhase = phase
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

    private func recoveryRetryErrorMessage(for reason: RecoveryStopReason) -> String {
        switch reason {
        case .processBlockerPresent, .helperChildAlive:
            return "Codex 앱 또는 관련 프로세스가 남아 복구하지 못했습니다."
        case .activeCredentialUnverified:
            return "현재 로그인 계정을 확인하지 못했습니다. 이전 활성 계정으로 로그인한 뒤 재시도하세요."
        case .rollbackPreviouslyFailed:
            return recoveryErrorMessage
        case .durabilityUnknown, .invalidProfileReference, .registryMismatch:
            return "복구 상태가 불명확합니다. 계정 작업을 중단했습니다."
        }
    }

    private func reloadState() async throws {
        let loadedProfiles = try await loadProfiles()
        let loadedRecoveryStatus = try await loadRecoveryStatus()
        profiles = loadedProfiles
        recoveryStatus = loadedRecoveryStatus
    }

    private func refreshState() async throws {
        recoveryStatus = .blocked
        await attemptAutomaticRecovery()
        try await reloadState()
    }

    private func refreshAfterMutationFailure() async {
        try? await refreshState()
        pendingProfile = nil
        cancelRemoval()
        cancelRelogin()
        cancelRecovery()
    }
}
