import Combine
import CodexAccountCore
import Foundation

@MainActor
public final class MenuBarViewModel: ObservableObject {
    public struct RecoveryConfirmation: Equatable, Sendable {
        public let profile: ProfileListItem
        public let transactionID: String
    }

    public typealias LoadProfiles = @Sendable () async throws -> [ProfileListItem]
    public typealias LoadProfileUsage = @Sendable (Set<ProfileID>?) async throws -> ProfileUsageReport
    public typealias LoadRecoveryStatus = @Sendable () async throws -> RecoveryCLIStatus
    public typealias UseToken = @Sendable (ProfileID) async throws -> Void
    public typealias CaptureProfile = @Sendable (String) async throws -> ProfileListItem
    public typealias RemoveProfile = @Sendable (ProfileID) async throws -> ProfileListItem
    public typealias SyncActiveProfile = @Sendable () async throws -> ProfileListItem
    public typealias SwitchProgress = @Sendable (SwitchPhase) async -> Void
    public typealias SwitchProfile = @Sendable (
        String,
        @escaping SwitchProgress
    ) async throws -> ProfileListItem
    public typealias ReloginProfile = @Sendable (String) async throws -> ProfileReloginOutcome
    public typealias CancelProfileLogin = @Sendable () async -> Void
    public typealias RestoreRecoveryProfile = @Sendable (String, String) async throws -> RecoveryRestoreOutcome
    public typealias RetryPendingRecovery = @Sendable (String) async throws -> RecoveryOutcome
    public typealias AttemptAutomaticRecovery = @Sendable () async -> Void

    public nonisolated static let activeUsageRefreshInterval: Duration = .seconds(120)
    public nonisolated static let inactiveUsageRefreshInterval: TimeInterval = 30 * 60

    private static let automaticTokenUseDefaultsKey =
        "local.codex.account-switcher.automatic-token-use"

    @Published public private(set) var profiles = [ProfileListItem]()
    @Published public private(set) var usageByProfileID = [ProfileID: AppServerRateLimitsRead]()
    @Published public private(set) var usageFailedProfileIDs = Set<ProfileID>()
    @Published public private(set) var pendingProfile: ProfileListItem?
    @Published public private(set) var pendingRemovalProfile: ProfileListItem?
    @Published public private(set) var pendingReloginProfile: ProfileListItem?
    @Published public private(set) var pendingRecoveryConfirmation: RecoveryConfirmation?
    @Published public private(set) var recoveryStatus = RecoveryCLIStatus.blocked
    @Published public private(set) var switchPhase: SwitchPhase?
    @Published public private(set) var isWorking = false
    @Published public private(set) var isAutomaticallyRefreshing = false
    @Published public private(set) var isProfileLoginInProgress = false
    @Published public private(set) var tokenUsingProfileID: ProfileID?
    @Published public private(set) var isAutomaticTokenUseEnabled: Bool
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?

    private let loadProfiles: LoadProfiles
    private let loadProfileUsage: LoadProfileUsage?
    private let loadRecoveryStatus: LoadRecoveryStatus
    private let useTokenOperation: UseToken?
    private let captureProfile: CaptureProfile
    private let removeProfile: RemoveProfile?
    private let syncActiveProfile: SyncActiveProfile
    private let switchProfile: SwitchProfile
    private let reloginProfile: ReloginProfile
    private let cancelProfileLoginOperation: CancelProfileLogin
    private let restoreRecoveryProfile: RestoreRecoveryProfile
    private let retryPendingRecovery: RetryPendingRecovery?
    private let attemptAutomaticRecovery: AttemptAutomaticRecovery
    private var cancelCurrentProfileLoginTask: (() -> Void)?
    private var lastFullUsageRefreshAt: Date?
    private var automaticUsageRefreshTask: Task<ProfileUsageReport, Error>?
    private var isCancellingAutomaticUsageRefresh = false
    private var automaticTokenUseRetryProfileIDs = Set<ProfileID>()

    public init(
        loadProfiles: @escaping LoadProfiles,
        loadProfileUsage: LoadProfileUsage? = nil,
        loadRecoveryStatus: @escaping LoadRecoveryStatus,
        useToken: UseToken? = nil,
        captureProfile: @escaping CaptureProfile,
        removeProfile: RemoveProfile? = nil,
        syncActiveProfile: @escaping SyncActiveProfile,
        switchProfile: @escaping SwitchProfile,
        reloginProfile: @escaping ReloginProfile,
        cancelProfileLogin: @escaping CancelProfileLogin = {},
        restoreRecoveryProfile: @escaping RestoreRecoveryProfile,
        retryPendingRecovery: RetryPendingRecovery? = nil,
        attemptAutomaticRecovery: @escaping AttemptAutomaticRecovery = {},
        initialAutomaticTokenUseEnabled: Bool? = nil
    ) {
        self.loadProfiles = loadProfiles
        self.loadProfileUsage = loadProfileUsage
        self.loadRecoveryStatus = loadRecoveryStatus
        useTokenOperation = useToken
        isAutomaticTokenUseEnabled = initialAutomaticTokenUseEnabled
            ?? UserDefaults.standard.bool(forKey: Self.automaticTokenUseDefaultsKey)
        self.captureProfile = captureProfile
        self.removeProfile = removeProfile
        self.syncActiveProfile = syncActiveProfile
        self.switchProfile = switchProfile
        self.reloginProfile = reloginProfile
        cancelProfileLoginOperation = cancelProfileLogin
        self.restoreRecoveryProfile = restoreRecoveryProfile
        self.retryPendingRecovery = retryPendingRecovery
        self.attemptAutomaticRecovery = attemptAutomaticRecovery
    }

    public func load() async {
        await cancelAutomaticUsageRefresh()
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await refreshState()
            if !recoveryRequired {
                await reloadUsage()
            }
            errorMessage = recoveryRequired ? recoveryErrorMessage : nil
        } catch {
            errorMessage = "계정 정보를 불러오지 못했습니다."
        }
    }

    public func refreshUsage() async {
        await cancelAutomaticUsageRefresh()
        await performUsageRefresh(profileIDs: nil, at: .now)
    }

    public func refreshUsageAutomatically(now: Date = .now) async {
        guard !isWorking, !recoveryRequired,
              !isCancellingAutomaticUsageRefresh,
              automaticUsageRefreshTask == nil,
              let loadProfileUsage,
              let activeProfileID = profiles.first(where: \.active)?.id else {
            return
        }
        let fullRefreshDue = lastFullUsageRefreshAt.map {
            now.timeIntervalSince($0) >= Self.inactiveUsageRefreshInterval
        } ?? true
        let profileIDs: Set<ProfileID>? = fullRefreshDue ? nil : [activeProfileID]
        let previousUsage = usageByProfileID
        let task = Task { try await loadProfileUsage(profileIDs) }
        automaticUsageRefreshTask = task
        isAutomaticallyRefreshing = true
        defer { isAutomaticallyRefreshing = false }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        guard !isCancellingAutomaticUsageRefresh,
              automaticUsageRefreshTask != nil else {
            return
        }
        automaticUsageRefreshTask = nil
        guard case let .success(report) = result else { return }
        let changedResetWindows = Self.changedResetWindows(
            from: previousUsage,
            to: report.usageByProfileID
        )
        applyUsageReport(
            report,
            profileIDs: profileIDs,
            at: now,
            preservingMissingUsage: true
        )
        guard isAutomaticTokenUseEnabled else { return }
        let resetDetected = !changedResetWindows.isEmpty
        if resetDetected || !automaticTokenUseRetryProfileIDs.isEmpty {
            await reloadUsage()
            await automaticallyUseTokens(afterResetDetection: resetDetected)
        }
    }

    private func performUsageRefresh(profileIDs: Set<ProfileID>?, at date: Date) async {
        guard !isWorking, !recoveryRequired, loadProfileUsage != nil else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        isWorking = true
        defer { isWorking = false }
        await reloadUsage(profileIDs: profileIDs, at: date)
    }

    public var canRefreshUsage: Bool {
        loadProfileUsage != nil && !profiles.isEmpty && !recoveryRequired
    }

    public var canUseAutomaticTokenUse: Bool {
        loadProfileUsage != nil
            && useTokenOperation != nil
            && !profiles.isEmpty
            && !recoveryRequired
    }

    public func setAutomaticTokenUseEnabled(_ enabled: Bool) {
        guard isAutomaticTokenUseEnabled != enabled else { return }
        isAutomaticTokenUseEnabled = enabled
        if !enabled {
            automaticTokenUseRetryProfileIDs.removeAll()
        }
        UserDefaults.standard.set(enabled, forKey: Self.automaticTokenUseDefaultsKey)
    }

    public func canUseToken(for profile: ProfileListItem) -> Bool {
        useTokenOperation != nil && !profile.needsRelogin && !recoveryRequired
    }

    public func useToken(for profile: ProfileListItem) async {
        await cancelAutomaticUsageRefresh()
        statusMessage = nil
        guard !isWorking, !recoveryRequired,
              let useTokenOperation,
              let current = profiles.first(where: { $0.id == profile.id }),
              current == profile,
              !current.needsRelogin else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return
        }
        isWorking = true
        tokenUsingProfileID = current.id
        defer {
            tokenUsingProfileID = nil
            isWorking = false
        }
        do {
            try await useTokenOperation(current.id)
            await reloadUsage(profileIDs: [current.id])
            automaticTokenUseRetryProfileIDs.remove(current.id)
            errorMessage = nil
            statusMessage = "\(current.label) 계정으로 토큰을 사용했습니다."
        } catch {
            errorMessage = "\(current.label) 계정의 토큰 사용 요청에 실패했습니다."
        }
    }

    private func automaticallyUseTokens(afterResetDetection resetDetected: Bool) async {
        guard let useTokenOperation else { return }
        let retryProfileIDs = automaticTokenUseRetryProfileIDs
        let targets = profiles.filter { profile in
            guard !profile.needsRelogin,
                  let usage = usageByProfileID[profile.id] else {
                return false
            }
            let hasFullWindow = usage.windows.contains { Self.remainingPercent($0) == 100 }
            return hasFullWindow && (resetDetected || retryProfileIDs.contains(profile.id))
        }
        guard !targets.isEmpty else { return }

        isWorking = true
        var usedLabels = [String]()
        var failedLabels = [String]()
        defer {
            tokenUsingProfileID = nil
            isWorking = false
        }

        for profile in targets {
            guard !Task.isCancelled else { return }
            tokenUsingProfileID = profile.id
            do {
                try await useTokenOperation(profile.id)
                await reloadUsage(profileIDs: [profile.id])
                automaticTokenUseRetryProfileIDs.remove(profile.id)
                usedLabels.append(profile.label)
            } catch {
                automaticTokenUseRetryProfileIDs.insert(profile.id)
                failedLabels.append(profile.label)
            }
        }

        if !usedLabels.isEmpty {
            statusMessage = "자동 토큰 사용: \(usedLabels.joined(separator: ", "))"
        }
        if !failedLabels.isEmpty {
            errorMessage = "자동 토큰 사용 실패: \(failedLabels.joined(separator: ", "))"
        } else if !usedLabels.isEmpty {
            errorMessage = nil
        }
    }

    public var activeRateLimitWindow: AppServerRateLimitWindow? {
        Self.limitingWindow(in: activeRateLimitWindows)
    }

    public var activeRateLimitWindows: [AppServerRateLimitWindow] {
        guard let activeID = profiles.first(where: \.active)?.id else {
            return []
        }
        return usageByProfileID[activeID]?.windows.sorted {
            $0.windowDurationMinutes < $1.windowDurationMinutes
        } ?? []
    }

    public var activeResetAt: Date? {
        activeRateLimitWindow?.resetsAt
    }

    public var activeRemainingPercent: Int? {
        activeRateLimitWindow.map(Self.remainingPercent)
    }

    public nonisolated static func limitingWindow(
        in windows: [AppServerRateLimitWindow]
    ) -> AppServerRateLimitWindow? {
        windows.min { remainingPercent($0) < remainingPercent($1) }
    }

    public nonisolated static func remainingPercent(_ window: AppServerRateLimitWindow) -> Int {
        Int(max(0, min(100, 100 - window.usedPercent)).rounded(.down))
    }

    public nonisolated static func periodLabel(minutes: Int) -> String {
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)d" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    public nonisolated static func resetCountdownLabel(
        resetAt: Date?,
        now: Date
    ) -> String? {
        guard let resetAt else { return nil }
        let seconds = max(0, resetAt.timeIntervalSince(now))
        if seconds > 86_400 { return "\(Int((seconds / 86_400).rounded(.up)))d" }
        if seconds >= 3_600 { return "\(Int((seconds / 3_600).rounded(.up)))h" }
        return "\(Int((seconds / 60).rounded(.up)))m"
    }

    public func select(_ profile: ProfileListItem) async {
        await cancelAutomaticUsageRefresh()
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
        await cancelAutomaticUsageRefresh()
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
        await cancelAutomaticUsageRefresh()
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
        await cancelAutomaticUsageRefresh()
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
        var sourceID: ProfileID?
        do {
            try await refreshState()
            guard !recoveryRequired,
                  let currentSource = profiles.first(where: \.active),
                  profiles.lazy.filter(\.active).count == 1,
                  let current = profiles.first(where: { $0.id == profile.id }),
                  !current.active,
                  current.needsRelogin else {
                errorMessage = recoveryRequired
                    ? recoveryErrorMessage
                    : "재로그인 상태가 변경되었습니다. 계정 정보를 다시 확인하세요."
                return
            }
            sourceID = currentSource.id
            reloginStarted = true
            let task = Task { try await reloginProfile(current.id.description) }
            cancelCurrentProfileLoginTask = { task.cancel() }
            isProfileLoginInProgress = true
            defer {
                cancelCurrentProfileLoginTask = nil
                isProfileLoginInProgress = false
            }
            let outcome = try await task.value
            reloginOutcome = outcome
            try await refreshState()
            guard reloginOutcomeMatches(outcome, targetID: current.id) else {
                recoveryStatus = .blocked
                errorMessage = "재로그인 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                return
            }
            guard profileReloginIsComplete(targetID: current.id, sourceID: currentSource.id) else {
                if recoveryRequired {
                    errorMessage = recoveryErrorMessage
                } else {
                    recoveryStatus = .blocked
                    errorMessage = "재로그인 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                }
                return
            }
            await reloadUsage()
            errorMessage = nil
            statusMessage = "\(current.label) 계정 인증을 갱신했습니다. 현재 계정은 유지됩니다. 전환하려면 계정을 다시 선택하세요."
        } catch {
            await refreshAfterMutationFailure()
            guard reloginStarted, let sourceID else {
                errorMessage = recoveryRequired ? recoveryErrorMessage : "계정 재로그인을 완료하지 못했습니다."
                return
            }
            if let reloginOutcome, !reloginOutcomeMatches(reloginOutcome, targetID: profile.id) {
                recoveryStatus = .blocked
                errorMessage = "재로그인 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                return
            }
            guard profileReloginIsComplete(targetID: profile.id, sourceID: sourceID) else {
                if recoveryRequired {
                    errorMessage = recoveryErrorMessage
                } else if reloginOutcome != nil {
                    recoveryStatus = .blocked
                    errorMessage = "재로그인 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                } else if let failure = error as? CodexLoginFailure, failure.code == .cancelled {
                    errorMessage = nil
                    statusMessage = "로그인을 취소했습니다. 현재 계정과 저장된 인증은 바뀌지 않았습니다."
                } else if let failure = error as? CodexLoginFailure, failure.code == .timeout {
                    errorMessage = "로그인 시간이 만료되었습니다. 현재 계정은 유지됩니다. 다시 시도하세요."
                } else if error is ProfileCaptureFailure {
                    errorMessage = "다른 계정으로 로그인했습니다. \(profile.email) 계정으로 다시 시도하세요."
                } else {
                    errorMessage = "브라우저 로그인을 완료하지 못했습니다. 현재 계정은 유지됩니다."
                }
                return
            }
            guard reloginOutcome != nil else {
                recoveryStatus = .blocked
                errorMessage = "계정 재로그인 완료 여부를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                return
            }
            await reloadUsage()
            errorMessage = nil
            statusMessage = "\(profile.label) 계정 인증을 갱신했습니다. 현재 계정은 유지됩니다. 전환하려면 계정을 다시 선택하세요."
        }
    }

    public func cancelProfileLogin() async {
        guard isProfileLoginInProgress else { return }
        cancelCurrentProfileLoginTask?()
        await cancelProfileLoginOperation()
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
        await cancelAutomaticUsageRefresh()
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
        await cancelAutomaticUsageRefresh()
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
        await cancelAutomaticUsageRefresh()
        statusMessage = nil
        guard !isWorking, !recoveryRequired else {
            if recoveryRequired { errorMessage = recoveryErrorMessage }
            return false
        }
        let existingProfileIDs = Set(profiles.map(\.id))
        let additional = !profiles.isEmpty
        let activeProfiles = profiles.filter(\.active)
        guard !additional || activeProfiles.count == 1 else {
            errorMessage = "현재 활성 계정을 확인하지 못했습니다."
            return false
        }
        let sourceID = activeProfiles.first?.id
        isWorking = true
        let task: Task<ProfileListItem, Error>? = additional
            ? Task { try await captureProfile(label) }
            : nil
        cancelCurrentProfileLoginTask = task.map { task in { task.cancel() } }
        isProfileLoginInProgress = additional
        defer {
            cancelCurrentProfileLoginTask = nil
            isProfileLoginInProgress = false
            isWorking = false
        }
        var captureReturned = false
        do {
            let captured: ProfileListItem
            if let task {
                captured = try await task.value
            } else {
                captured = try await captureProfile(label)
            }
            captureReturned = true
            try await refreshState()
            guard !recoveryRequired else {
                errorMessage = recoveryErrorMessage
                return false
            }
            guard registrationIsComplete(
                existingProfileIDs: existingProfileIDs,
                sourceID: sourceID,
                additional: additional,
                capturedID: captured.id
            ) else {
                recoveryStatus = .blocked
                errorMessage = "계정 등록 결과를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                return false
            }
            await reloadUsage()
            reportRegistrationSuccess(label: label, additional: additional)
            return true
        } catch {
            await refreshAfterMutationFailure()
            if recoveryRequired {
                errorMessage = recoveryErrorMessage
                return false
            }
            if registrationIsComplete(
                existingProfileIDs: existingProfileIDs,
                sourceID: sourceID,
                additional: additional,
                capturedID: nil
            ) {
                if additional {
                    guard captureReturned else {
                        recoveryStatus = .blocked
                        errorMessage = "계정 등록 완료 여부를 확인하지 못했습니다. 계정 작업을 중단했습니다."
                        return false
                    }
                    await reloadUsage()
                    reportRegistrationSuccess(label: label, additional: true)
                } else {
                    errorMessage = "계정은 등록했지만 Codex 앱을 다시 열지 못했습니다."
                }
                return true
            }
            switch error {
            case let failure as CodexLoginFailure where failure.code == .cancelled:
                errorMessage = nil
                statusMessage = "로그인을 취소했습니다. 현재 계정과 저장된 인증은 바뀌지 않았습니다."
            case let failure as CodexLoginFailure where failure.code == .timeout:
                errorMessage = "로그인 시간이 만료되었습니다. 현재 계정은 유지됩니다. 다시 시도하세요."
            case ProfileCaptureFailure.accountAlreadyRegistered:
                errorMessage = "이미 등록된 계정입니다. 다른 계정으로 로그인하세요."
            case ProfileCaptureFailure.identityMismatch:
                errorMessage = "로그인 중 계정 정보가 변경되었습니다. 다시 시도하세요."
            case LocalCLIDataProviderFailure.profileAlreadyExists:
                errorMessage = "같은 이름이 있거나 계정을 3개까지 등록했습니다."
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
        await cancelAutomaticUsageRefresh()
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
            await reloadUsage()
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
            if recoveryRequired {
                errorMessage = recoveryErrorMessage
            } else {
                await reloadUsage()
                errorMessage = nil
            }
        } catch {
            await refreshAfterMutationFailure()
            if recoveryRequired {
                errorMessage = recoveryErrorMessage
            } else if let failure = error as? SwitchCoordinatorFailure,
                      failure == .independentCodexBlocked {
                errorMessage = "Codex CLI 또는 IDE 작업이 실행 중입니다. 해당 작업을 종료한 뒤 다시 시도하세요."
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

    private func profileReloginIsComplete(targetID: ProfileID, sourceID: ProfileID) -> Bool {
        recoveryStatus == .none
            && profiles.lazy.filter(\.active).count == 1
            && profiles.contains { $0.id == sourceID && $0.active && !$0.needsRelogin }
            && profiles.contains { $0.id == targetID && !$0.active && !$0.needsRelogin }
    }

    private func registrationIsComplete(
        existingProfileIDs: Set<ProfileID>,
        sourceID: ProfileID?,
        additional: Bool,
        capturedID: ProfileID?
    ) -> Bool {
        guard recoveryStatus == .none else { return false }
        let added = profiles.filter { !existingProfileIDs.contains($0.id) }
        guard added.count == 1,
              !added[0].needsRelogin,
              capturedID == nil || added[0].id == capturedID else {
            return false
        }
        if additional {
            guard let sourceID else { return false }
            return !added[0].active
                && profiles.lazy.filter(\.active).count == 1
                && profiles.contains { $0.id == sourceID && $0.active && !$0.needsRelogin }
        }
        return added[0].active && profiles.lazy.filter(\.active).count == 1
    }

    private func reportRegistrationSuccess(label: String, additional: Bool) {
        errorMessage = nil
        statusMessage = additional
            ? "\(label) 계정을 등록했습니다. 현재 계정은 유지됩니다. 전환하려면 계정을 선택하세요."
            : nil
    }

    private func reloginOutcomeMatches(
        _ outcome: ProfileReloginOutcome,
        targetID: ProfileID
    ) -> Bool {
        guard case let .refreshed(profile) = outcome else { return false }
        return profile.id == targetID && !profile.active && !profile.needsRelogin
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
        let profileIDs = Set(loadedProfiles.map(\.id))
        usageByProfileID = usageByProfileID.filter { profileIDs.contains($0.key) }
        usageFailedProfileIDs.formIntersection(profileIDs)
        automaticTokenUseRetryProfileIDs.formIntersection(profileIDs)
    }

    private func reloadUsage(
        profileIDs requestedProfileIDs: Set<ProfileID>? = nil,
        at date: Date = .now
    ) async {
        guard let loadProfileUsage else { return }
        do {
            let report = try await loadProfileUsage(requestedProfileIDs)
            applyUsageReport(report, profileIDs: requestedProfileIDs, at: date)
        } catch {
            let failedProfileIDs = requestedProfileIDs ?? Set(profiles.map(\.id))
            for profileID in failedProfileIDs {
                usageByProfileID[profileID] = nil
            }
            usageFailedProfileIDs.formUnion(failedProfileIDs)
        }
    }

    private func applyUsageReport(
        _ report: ProfileUsageReport,
        profileIDs requestedProfileIDs: Set<ProfileID>?,
        at date: Date,
        preservingMissingUsage: Bool = false
    ) {
        if requestedProfileIDs == nil {
            lastFullUsageRefreshAt = date
        }
        if preservingMissingUsage {
            let targetProfileIDs = requestedProfileIDs ?? Set(profiles.map(\.id))
            for profileID in targetProfileIDs {
                if let usage = report.usageByProfileID[profileID] {
                    usageByProfileID[profileID] = usage
                    usageFailedProfileIDs.remove(profileID)
                } else if usageByProfileID[profileID] == nil {
                    usageFailedProfileIDs.insert(profileID)
                }
            }
        } else if let requestedProfileIDs {
            for profileID in requestedProfileIDs {
                if let usage = report.usageByProfileID[profileID] {
                    usageByProfileID[profileID] = usage
                    usageFailedProfileIDs.remove(profileID)
                } else {
                    usageByProfileID[profileID] = nil
                    usageFailedProfileIDs.insert(profileID)
                }
            }
        } else {
            usageByProfileID = report.usageByProfileID
            usageFailedProfileIDs = report.failedProfileIDs
        }
    }

    private static func changedResetWindows(
        from previous: [ProfileID: AppServerRateLimitsRead],
        to current: [ProfileID: AppServerRateLimitsRead]
    ) -> [ProfileID: Set<Int>] {
        var changed = [ProfileID: Set<Int>]()
        for (profileID, currentUsage) in current {
            guard let previousUsage = previous[profileID] else { continue }
            for currentWindow in currentUsage.windows {
                guard let previousWindow = previousUsage.windows.first(where: {
                    $0.windowDurationMinutes == currentWindow.windowDurationMinutes
                }),
                    let previousReset = previousWindow.resetsAt,
                    let currentReset = currentWindow.resetsAt,
                    previousReset != currentReset else {
                    continue
                }
                changed[profileID, default: []].insert(currentWindow.windowDurationMinutes)
            }
        }
        return changed
    }

    private func cancelAutomaticUsageRefresh() async {
        if isCancellingAutomaticUsageRefresh, let task = automaticUsageRefreshTask {
            _ = await task.result
            return
        }
        guard let task = automaticUsageRefreshTask else { return }
        isCancellingAutomaticUsageRefresh = true
        defer {
            automaticUsageRefreshTask = nil
            isCancellingAutomaticUsageRefresh = false
        }
        task.cancel()
        _ = await task.result
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
