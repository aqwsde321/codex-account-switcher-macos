import AppKit
import CodexAccountCore
import CodexAccountMenuBarModel
import CodexSleepGuardCore
import SwiftUI
import notify

@main
struct CodexAccountMenuBarApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: MenuBarViewModel
    @StateObject private var sleepPrevention: SleepPreventionViewModel
    @State private var menuBarNow = Date.now
    @State private var steamFrame = 0
    private let menuBarSteamFrames: [NSImage]

    private static let steamFrameCount = 15

    init() {
        menuBarSteamFrames = Self.makeMenuBarSteamFrames()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let storeURL = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        let authURL = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        let initialAutoDisableThreshold = (
            try? SpikeStore.create(at: storeURL).loadSleepGuardThresholdIfPresent()
        ) ?? .defaultValue
        let provider = LocalCLIDataProvider(
            storeURL: storeURL,
            activeAuthURL: authURL,
            credentialStore: FileCredentialStore(rootURL: storeURL),
            confirmAppOwnedTermination: { count in
                await MainActor.run {
                    confirmAppOwnedTermination(count: count)
                }
            },
            reportAppOwnedTermination: { before, remaining in
                await MainActor.run {
                    showAppOwnedTerminationResult(before: before, remaining: remaining)
                }
            }
        )
        _model = StateObject(
            wrappedValue: MenuBarViewModel(
                loadProfiles: {
                    try await provider.profiles()
                },
                loadProfileUsage: { profileIDs in
                    try await provider.profileUsage(profileIDs: profileIDs)
                },
                loadRecoveryStatus: {
                    try await provider.recoveryStatus()
                },
                useToken: { profileID in
                    try await provider.useToken(profileID: profileID)
                },
                captureProfile: {
                    try await provider.captureProfile(label: $0)
                },
                removeProfile: { profileID in
                    try await provider.removeProfile(profileID)
                },
                syncActiveProfile: {
                    try await provider.syncActiveProfile()
                },
                switchProfile: { target, onPhaseChange in
                    try await provider.switchProfile(
                        target: target,
                        onPhaseChange: onPhaseChange
                    )
                },
                reloginProfile: { target in
                    try await provider.reloginProfile(target: target)
                },
                cancelProfileLogin: {
                    await provider.cancelProfileLogin()
                },
                restoreRecoveryProfile: { target, transactionID in
                    try await provider.restoreRecoveryProfile(
                        target: target,
                        expectedTransactionID: transactionID
                    )
                },
                retryPendingRecovery: { transactionID in
                    try await provider.retryPendingRecovery(
                        expectedTransactionID: transactionID
                    )
                },
                attemptAutomaticRecovery: {
                    _ = try? await provider.recoverPendingTransaction()
                }
            )
        )
        _sleepPrevention = StateObject(
            wrappedValue: SleepPreventionViewModel(
                readEnabled: {
                    try await SleepPreventionSystem.readEnabled()
                },
                setEnabled: { enabled in
                    try await SleepPreventionSystem.setEnabled(enabled)
                    SleepGuardSystem.postReevaluation()
                },
                initialAutoDisableThreshold: initialAutoDisableThreshold,
                saveAutoDisableThreshold: { threshold in
                    let store = try SpikeStore.create(at: storeURL)
                    _ = try store.saveSleepGuardThreshold(threshold)
                    SleepGuardSystem.postReevaluation()
                }
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            AccountMenuView(
                model: model,
                sleepPrevention: sleepPrevention,
                now: menuBarNow,
                steamProgress: steamProgress
            )
        } label: {
            HStack(spacing: 4) {
                Group {
                    if steamAnimationIsActive,
                       menuBarSteamFrames.count == Self.steamFrameCount {
                        Image(nsImage: menuBarSteamFrames[steamFrame])
                    } else {
                        SleepPreventionStatusIcon(
                            isEnabled: sleepPrevention.isEnabled == true,
                            reduceMotion: reduceMotion,
                            steamProgress: steamProgress
                        )
                    }
                }
                    .frame(width: 23, height: 22)
                    .scaleEffect(model.isAutomaticallyRefreshing && !reduceMotion ? 1.06 : 1)
                    .opacity(model.isAutomaticallyRefreshing ? 0.55 : 1)
                    .animation(refreshAnimation, value: model.isAutomaticallyRefreshing)
                if let remaining = model.activeRemainingPercent {
                    let resetCountdown = activeResetCountdown.map { " · \($0)" } ?? ""
                    Text("\(remaining)%\(resetCountdown)")
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statusAccessibilityLabel)
            .task { await sleepPrevention.load() }
            .task {
                await model.load()
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: MenuBarViewModel.activeUsageRefreshInterval)
                    } catch {
                        return
                    }
                    await model.refreshUsageAutomatically()
                }
            }
            .task {
                while !Task.isCancelled {
                    menuBarNow = .now
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        return
                    }
                }
            }
            .task(id: steamAnimationIsActive) {
                steamFrame = 0
                guard steamAnimationIsActive else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(120))
                    } catch {
                        return
                    }
                    steamFrame = (steamFrame + 1) % Self.steamFrameCount
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var activeResetCountdown: String? {
        MenuBarViewModel.resetCountdownLabel(
            resetAt: model.activeResetAt,
            now: menuBarNow
        )
    }

    private var statusAccessibilityLabel: String {
        let resetCountdown = activeResetCountdown.map { ", \($0) 후 초기화" } ?? ""
        let usage = model.activeRemainingPercent.map {
            model.isAutomaticallyRefreshing
                ? "Codex 계정 한도 자동 조회 중, \($0)% 남음\(resetCountdown)"
                : "Codex 계정 \($0)% 남음\(resetCountdown)"
        } ?? (model.isAutomaticallyRefreshing
            ? "Codex 계정 한도 자동 조회 중"
            : "Codex 계정")
        return usage + (sleepPrevention.isEnabled == true ? ", 잠자기 방지 켜짐" : "")
    }

    private var steamAnimationIsActive: Bool {
        sleepPrevention.isEnabled == true && !reduceMotion
    }

    private var steamProgress: CGFloat {
        CGFloat(steamFrame) / CGFloat(Self.steamFrameCount - 1)
    }

    private static func makeMenuBarSteamFrames() -> [NSImage] {
        (0..<steamFrameCount).compactMap { frame in
            let renderer = ImageRenderer(
                content: SleepPreventionStatusIcon(
                    isEnabled: true,
                    reduceMotion: false,
                    steamProgress: CGFloat(frame) / CGFloat(steamFrameCount - 1)
                )
                .foregroundStyle(.black)
            )
            renderer.scale = 2
            guard let image = renderer.nsImage else { return nil }
            image.isTemplate = true
            return image
        }
    }

    private var refreshAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return model.isAutomaticallyRefreshing
            ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.2)
    }
}

private struct SleepPreventionStatusIcon: View {
    let isEnabled: Bool
    let reduceMotion: Bool
    let steamProgress: CGFloat

    var body: some View {
        ZStack {
            if isEnabled, !reduceMotion {
                Image(systemName: "cup.and.heat.waves.fill")
                    .font(.system(size: 18, weight: .medium))
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: 14)
                    }
                ZStack {
                    Image(systemName: "cup.and.heat.waves.fill")
                        .font(.system(size: 18, weight: .medium))
                        .mask(alignment: .top) {
                            Rectangle().frame(height: 8)
                        }
                        .opacity(0.28)
                    Image(systemName: "cup.and.heat.waves.fill")
                        .font(.system(size: 18, weight: .medium))
                        .mask(alignment: .top) {
                            Rectangle().frame(height: 8)
                        }
                        .mask(alignment: .top) {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white, location: 0.25),
                                    .init(color: .white, location: 0.75),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 4)
                            .offset(y: 7 - (9 * steamProgress))
                        }
                }
                .offset(y: 1.5 - (3 * steamProgress))
            } else {
                Image(systemName: isEnabled ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                    .font(.system(size: 18, weight: .medium))
            }
        }
        .frame(width: 23, height: 22)
    }
}

private final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let url = Bundle.main.url(
            forResource: "CodexAccountSwitcher",
            withExtension: "png"
        ), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
}

private enum SleepPreventionSystem {
    static func readEnabled() async throws -> Bool {
        let output = try await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g"]
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                throw SleepPreventionSystemError.commandFailed
            }
            return output
        }.value
        guard let enabled = SleepPreventionViewModel.parsePMSetOutput(output) else {
            throw SleepPreventionSystemError.commandFailed
        }
        return enabled
    }

    @MainActor
    static func setEnabled(_ enabled: Bool) throws {
        let value = enabled ? 1 : 0
        guard let script = NSAppleScript(
            source: "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        ) else {
            throw SleepPreventionSystemError.commandFailed
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            throw SleepPreventionSystemError.commandFailed
        }
    }
}

private enum SleepPreventionSystemError: Error {
    case commandFailed
}

private enum SleepGuardSystem {
    static func postReevaluation() {
        _ = sleepGuardReevaluationNotification.withCString { notify_post($0) }
    }
}

private struct AccountMenuView: View {
    @ObservedObject var model: MenuBarViewModel
    @ObservedObject var sleepPrevention: SleepPreventionViewModel
    let now: Date
    let steamProgress: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRegistering = false
    @State private var registrationLabel = ""
    @State private var sleepGuardThresholdDraft =
        Double(SleepGuardThreshold.defaultValue.rawValue)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex 계정")
                    .font(.headline)
                Spacer()
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("계정 작업 진행 중")
                }
                Button {
                    Task { await model.refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking || !model.canRefreshUsage)
                .help("모든 계정 한도 새로고침")
                .accessibilityLabel("모든 계정 한도 새로고침")
            }
            if model.profiles.isEmpty {
                Text(model.isWorking ? "불러오는 중…" : "등록된 계정이 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.profiles, id: \.id) { profile in
                    ZStack(alignment: .topTrailing) {
                        Button {
                            Task {
                                await model.select(profile)
                                if let relogin = model.pendingReloginProfile {
                                    guard confirmProfileRelogin(relogin) else {
                                        model.cancelRelogin()
                                        return
                                    }
                                    await model.confirmRelogin(relogin)
                                    return
                                }
                                guard let confirmation = model.pendingProfile else { return }
                                guard confirmAccountSwitch(confirmation) else {
                                    model.cancelSwitch()
                                    return
                                }
                                await model.confirmSwitch(confirmation)
                            }
                        } label: {
                            ProfileCard(
                                profile: profile,
                                usage: model.usageByProfileID[profile.id],
                                usageFailed: model.usageFailedProfileIDs.contains(profile.id),
                                now: now
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

                        HStack(spacing: 2) {
                            Button {
                                Task { await model.useToken(for: profile) }
                            } label: {
                                if model.tokenUsingProfileID == profile.id {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: "bolt.fill")
                                        .frame(width: 28, height: 28)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .disabled(!model.canUseToken(for: profile))
                            .help("\(profile.label) 계정 토큰 사용")
                            .accessibilityLabel("\(profile.label) 계정 토큰 사용")

                            if !profile.active {
                                Button(role: .destructive) {
                                    model.requestRemoval(profile)
                                    guard let confirmation = model.pendingRemovalProfile else { return }
                                    guard confirmProfileRemoval(confirmation) else {
                                        model.cancelRemoval()
                                        return
                                    }
                                    Task { await model.confirmRemoval(confirmation) }
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .help("\(profile.label) 계정 삭제")
                                .accessibilityLabel("\(profile.label) 계정 삭제")
                            }
                        }
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                profile.active
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.secondary.opacity(0.08)
                            )
                    )
                    .disabled(model.isWorking || model.recoveryRequired)
                }
            }

            if model.canUseAutomaticTokenUse {
                HStack {
                    Label("자동 토큰 사용", systemImage: "bolt.fill")
                    Spacer()
                    Toggle("자동 토큰 사용", isOn: automaticTokenUseBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(model.isWorking)
                }
                .help("사용량 조회에서 리셋을 감지하면 남은 한도가 100%인 계정을 순차적으로 사용합니다.")
            }

            if let progressMessage = model.switchProgressMessage {
                Text(progressMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("전환 상태: \(progressMessage)")
            }

            if model.isProfileLoginInProgress {
                Text("브라우저 로그인을 기다리는 중… 현재 활성 계정은 유지됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("브라우저 로그인 취소") {
                    Task { await model.cancelProfileLogin() }
                }
            }

            if let recoveryProfile = model.recoveryProfile {
                Button("\(recoveryProfile.label) 계정 복구…") {
                    model.requestRecovery()
                    guard let confirmation = model.pendingRecoveryConfirmation else { return }
                    guard confirmRecovery(confirmation) else {
                        model.cancelRecovery()
                        return
                    }
                    Task { await model.confirmRecovery(confirmation) }
                }
                .disabled(model.isWorking)
            }

            if model.canRetryRecovery {
                Button("Codex 종료하고 복구 재시도") {
                    Task { await model.retryRecovery() }
                }
                .disabled(model.isWorking)
            }

            if isRegistering {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("계정 이름", text: $registrationLabel)
                    Text(registrationHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("취소") {
                            registrationLabel = ""
                            isRegistering = false
                        }
                        .disabled(model.isWorking)
                        Spacer()
                        Button(model.profiles.isEmpty ? "현재 로그인 등록" : "새 계정 등록") {
                            let label = registrationLabel
                            guard confirmRegistration(additional: !model.profiles.isEmpty) else { return }
                            Task {
                                let registered = await model.register(label: label)
                                if registered || model.recoveryRequired {
                                    registrationLabel = ""
                                    isRegistering = false
                                }
                                if let errorMessage = model.errorMessage {
                                    showRegistrationError(errorMessage)
                                }
                            }
                        }
                        .disabled(
                            model.isWorking
                                || model.recoveryRequired
                                || !registrationLabelIsValid
                        )
                    }
                }
            } else if !model.recoveryRequired,
                      model.profiles.count < ProfileRegistry.maximumProfileCount {
                Button("계정 등록") {
                    isRegistering = true
                }
                .disabled(model.isWorking)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("오류: \(errorMessage)")
            } else if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("상태: \(statusMessage)")
            }

            Divider()
            HStack {
                HStack(spacing: 8) {
                    SleepPreventionStatusIcon(
                        isEnabled: sleepPrevention.isEnabled == true,
                        reduceMotion: reduceMotion,
                        steamProgress: steamProgress
                    )
                        .accessibilityHidden(true)
                    Text("잠자기 방지")
                }
                Spacer()
                if sleepPrevention.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Toggle("잠자기 방지", isOn: sleepPreventionBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(
                        sleepPrevention.isWorking
                            || sleepPrevention.isEnabled == nil
                    )
                    .help("덮개를 닫아도 계속 동작해 발열과 배터리 소모가 증가할 수 있습니다. 앱 종료 후에도 유지됩니다.")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("배터리 자동 해제")
                    Spacer()
                    Text(sleepGuardThresholdDraftLabel)
                        .monospacedDigit()
                }
                ZStack {
                    GeometryReader { geometry in
                        let thumbDiameter: CGFloat = 16
                        let trackWidth = max(0, geometry.size.width - thumbDiameter)
                        let progress = CGFloat(
                            min(max(sleepGuardThresholdDraft / 99, 0), 1)
                        )
                        ZStack {
                            ProgressView(value: sleepGuardThresholdDraft, total: 99)
                                .controlSize(.small)
                                .padding(.horizontal, thumbDiameter / 2)
                            Circle()
                                .fill(Color.accentColor)
                                .overlay {
                                    Circle().stroke(Color.white.opacity(0.9), lineWidth: 1)
                                }
                                .shadow(color: Color.black.opacity(0.18), radius: 1, y: 1)
                                .frame(width: thumbDiameter, height: thumbDiameter)
                                .position(
                                    x: thumbDiameter / 2 + trackWidth * progress,
                                    y: geometry.size.height / 2
                                )
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    sleepGuardThresholdDraft = thresholdDraft(
                                        at: drag.location.x,
                                        width: geometry.size.width
                                    )
                                }
                                .onEnded { drag in
                                    sleepGuardThresholdDraft = thresholdDraft(
                                        at: drag.location.x,
                                        width: geometry.size.width
                                    )
                                    saveSleepGuardThresholdDraft()
                                }
                        )
                        .allowsHitTesting(!sleepPrevention.isWorking)
                    }
                    Slider(
                        value: $sleepGuardThresholdDraft,
                        in: 0...99,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing {
                                saveSleepGuardThresholdDraft()
                            }
                        }
                    )
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .disabled(sleepPrevention.isWorking)
                    .accessibilityLabel("배터리 자동 해제 기준")
                    .accessibilityValue(sleepGuardThresholdDraftLabel)
                }
                .frame(height: 22)
            }
            .help("0은 끔입니다. 충전 중이 아닐 때 선택한 배터리 잔량 이하에서 잠자기 방지를 자동으로 끕니다.")
            if let errorMessage = sleepPrevention.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("오류: \(errorMessage)")
            }

            Divider()
            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
            .disabled(model.isProfileLoginInProgress)
        }
        .padding(14)
        .frame(width: 320)
        .task {
            sleepGuardThresholdDraft = Double(sleepPrevention.autoDisableThreshold.rawValue)
            await sleepPrevention.load()
        }
        .onChange(of: sleepPrevention.autoDisableThreshold) { threshold in
            sleepGuardThresholdDraft = Double(threshold.rawValue)
        }
    }

    private var sleepPreventionBinding: Binding<Bool> {
        Binding(
            get: { sleepPrevention.isEnabled == true },
            set: { enabled in
                guard sleepPrevention.isEnabled != enabled else { return }
                Task { await sleepPrevention.setEnabled(enabled) }
            }
        )
    }

    private var automaticTokenUseBinding: Binding<Bool> {
        Binding(
            get: { model.isAutomaticTokenUseEnabled },
            set: { model.setAutomaticTokenUseEnabled($0) }
        )
    }

    private var sleepGuardThresholdDraftLabel: String {
        let value = Int(sleepGuardThresholdDraft.rounded())
        return value == 0 ? "끔" : "\(value)%"
    }

    private func thresholdDraft(at locationX: CGFloat, width: CGFloat) -> Double {
        let thumbDiameter: CGFloat = 16
        let trackWidth = max(width - thumbDiameter, 1)
        let progress = min(max((locationX - thumbDiameter / 2) / trackWidth, 0), 1)
        return Double(progress * 99).rounded()
    }

    private func saveSleepGuardThresholdDraft() {
        guard let threshold = SleepGuardThreshold(
            rawValue: Int(sleepGuardThresholdDraft.rounded())
        ) else {
            sleepGuardThresholdDraft = Double(sleepPrevention.autoDisableThreshold.rawValue)
            return
        }
        Task {
            await sleepPrevention.setAutoDisableThreshold(threshold)
            sleepGuardThresholdDraft = Double(sleepPrevention.autoDisableThreshold.rawValue)
        }
    }

    private var registrationLabelIsValid: Bool {
        !registrationLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && registrationLabel.unicodeScalars.count <= 64
    }

    private var registrationHelp: String {
        if model.profiles.isEmpty {
            return "등록하면 공식 Codex 앱을 정상 종료하고 현재 로그인을 저장한 뒤 다시 엽니다. 독립 Codex CLI와 IDE는 먼저 직접 종료하세요."
        }
        return "브라우저에서 새 계정으로 로그인합니다. 현재 활성 계정은 유지되며 새 계정으로 자동 전환하지 않습니다."
    }
}

private struct ProfileCard: View {
    let profile: ProfileListItem
    let usage: AppServerRateLimitsRead?
    let usageFailed: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: profile.active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(profile.active ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.label)
                        .fontWeight(profile.active ? .semibold : .regular)
                    Text(profile.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let planType = usage?.planType {
                    Text(planType.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                if profile.needsRelogin {
                    Text("재로그인 필요")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if profile.active {
                    Text("활성")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, profile.active ? 28 : 58)

            if let usage {
                if usage.windows.isEmpty {
                    Text("한도 정보 없음")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(usage.windows.sorted(by: windowOrder).enumerated()), id: \.offset) {
                        _, window in
                        UsageWindowRow(window: window, now: now)
                    }
                }
            } else if usageFailed {
                Text("한도 조회 실패")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.label), \(profile.email)")
        .accessibilityValue(accessibilityValue)
    }

    private func windowOrder(_ lhs: AppServerRateLimitWindow, _ rhs: AppServerRateLimitWindow) -> Bool {
        lhs.windowDurationMinutes < rhs.windowDurationMinutes
    }

    private var accessibilityValue: String {
        var values = [profile.needsRelogin ? "재로그인 필요" : (profile.active ? "활성 계정" : "비활성 계정")]
        if let planType = usage?.planType {
            values.append(planType.uppercased())
        }
        if let usage {
            values.append(contentsOf: usage.windows.map {
                "\(MenuBarViewModel.periodLabel(minutes: $0.windowDurationMinutes)) \(MenuBarViewModel.remainingPercent($0))% 남음"
            })
        } else if usageFailed {
            values.append("한도 조회 실패")
        }
        return values.joined(separator: ", ")
    }
}

private struct UsageWindowRow: View {
    let window: AppServerRateLimitWindow
    let now: Date

    private var remaining: Int {
        MenuBarViewModel.remainingPercent(window)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(MenuBarViewModel.periodLabel(minutes: window.windowDurationMinutes))
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(remaining)% 남음")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(remaining), total: 100)
                .controlSize(.small)
                .accessibilityLabel("남은 사용 한도")
                .accessibilityValue("\(remaining)%")
            if let resetsAt = window.resetsAt {
                HStack(spacing: 3) {
                    Text(resetsAt, format: .dateTime.month().day().hour().minute())
                    Text("초기화")
                    if let countdown = MenuBarViewModel.resetCountdownLabel(resetAt: resetsAt, now: now) {
                        Text("· " + countdown + " 후")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private func accountSwitcherAlert() -> NSAlert {
    let alert = NSAlert()
    alert.icon = NSApp.applicationIconImage
    return alert
}

@MainActor
private func confirmAppOwnedTermination(count: Int) -> Bool {
    let alert = accountSwitcherAlert()
    alert.alertStyle = .warning
    alert.messageText = "잔존 앱 프로세스를 종료할까요?"
    alert.informativeText = "정상 종료 뒤에도 ChatGPT 앱 소유 프로세스 \(count)개가 남았습니다. 종료 전 확인한 동일 프로세스에만 SIGTERM을 한 번 보냅니다. 독립 Codex 프로세스는 종료하지 않습니다."
    let cancel = alert.addButton(withTitle: "취소")
    cancel.keyEquivalent = "\u{1b}"
    let terminate = alert.addButton(withTitle: "SIGTERM 전송")
    terminate.hasDestructiveAction = true
    return alert.runModal() == .alertSecondButtonReturn
}

@MainActor
private func showAppOwnedTerminationResult(before: [ProcessRecord], remaining: [ProcessRecord]) {
    let alert = accountSwitcherAlert()
    alert.alertStyle = remaining.isEmpty ? .informational : .warning
    alert.messageText = remaining.isEmpty ? "잔존 프로세스를 종료했습니다." : "종료하지 못한 프로세스가 남았습니다."
    alert.informativeText = """
    종료 전 (\(before.count)개)
    \(processList(before))

    종료 후 (\(remaining.count)개)
    \(processList(remaining))

    승인된 Crashpad 프로세스는 종료 대상에서 제외됩니다.
    """
    alert.addButton(withTitle: "확인")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
}

private func processList(_ processes: [ProcessRecord]) -> String {
    guard !processes.isEmpty else { return "없음" }
    return processes.map { process in
        let name = process.nameHint
            ?? process.executablePath?.split(separator: "/").last.map(String.init)
            ?? "알 수 없는 프로세스"
        return "• \(name) (PID \(process.identity.pid))"
    }.joined(separator: "\n")
}

@MainActor
private func confirmRegistration(additional: Bool) -> Bool {
    let alert = accountSwitcherAlert()
    alert.alertStyle = .warning
    if additional {
        alert.messageText = "새 계정을 등록할까요?"
        alert.informativeText = "현재 활성 계정은 유지됩니다. 브라우저에서 등록할 새 계정으로 로그인하세요. 등록 후 자동 전환하지 않습니다."
        alert.addButton(withTitle: "브라우저 로그인 시작")
    } else {
        alert.messageText = "현재 로그인을 등록할까요?"
        alert.informativeText = "버튼을 누르면 공식 Codex 앱을 자동으로 정상 종료하고 현재 로그인을 저장한 뒤 다시 엽니다. 독립 Codex CLI와 IDE 작업은 먼저 직접 종료하세요."
        alert.addButton(withTitle: "Codex 자동 종료하고 등록")
    }
    let cancel = alert.addButton(withTitle: "취소")
    cancel.keyEquivalent = "\u{1b}"
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
}

@MainActor
private func confirmAccountSwitch(_ profile: ProfileListItem) -> Bool {
    let alert = accountSwitcherAlert()
    alert.alertStyle = .warning
    alert.messageText = "계정을 전환할까요?"
    alert.informativeText = "\(profile.label) 계정으로 전환합니다."
    let cancel = alert.addButton(withTitle: "취소")
    cancel.keyEquivalent = "\u{1b}"
    alert.addButton(withTitle: "전환")
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertSecondButtonReturn
}

@MainActor
private func confirmProfileRelogin(_ profile: ProfileListItem) -> Bool {
    let alert = accountSwitcherAlert()
    alert.alertStyle = .warning
    alert.messageText = "\(profile.label) 계정 인증을 갱신할까요?"
    alert.informativeText = "현재 활성 계정은 유지됩니다. 브라우저에서 \(profile.email) 계정으로 로그인하세요. 인증만 갱신하며 자동 전환하지 않습니다."
    let cancel = alert.addButton(withTitle: "취소")
    cancel.keyEquivalent = "\u{1b}"
    alert.addButton(withTitle: "브라우저 로그인 시작")
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertSecondButtonReturn
}

@MainActor
private func confirmProfileRemoval(_ profile: ProfileListItem) -> Bool {
    let alert = accountSwitcherAlert()
    alert.alertStyle = .warning
    alert.messageText = "\(profile.label) 계정을 삭제할까요?"
    alert.informativeText = "이 앱에 저장된 계정 정보와 로컬 JSON 자격증명만 삭제합니다. OpenAI 계정은 삭제되지 않고 현재 Codex 로그인도 바뀌지 않습니다. 나중에 같은 계정으로 로그인해 다시 등록할 수 있습니다."
    let cancel = alert.addButton(withTitle: "취소")
    cancel.keyEquivalent = "\u{1b}"
    let remove = alert.addButton(withTitle: "삭제")
    remove.hasDestructiveAction = true
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertSecondButtonReturn
}

@MainActor
private func confirmRecovery(_ confirmation: MenuBarViewModel.RecoveryConfirmation) -> Bool {
    let alert = accountSwitcherAlert()
    alert.alertStyle = .warning
    alert.messageText = "\(confirmation.profile.label) 계정을 복구할까요?"
    alert.informativeText = "공식 앱을 정상 종료하고 저장된 이전 인증으로 복구합니다. 독립 Codex CLI와 IDE 작업은 먼저 직접 종료하세요."
    let cancel = alert.addButton(withTitle: "취소")
    cancel.keyEquivalent = "\u{1b}"
    let restore = alert.addButton(withTitle: "복구")
    restore.hasDestructiveAction = true
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertSecondButtonReturn
}

@MainActor
private func showRegistrationError(_ message: String) {
    let alert = accountSwitcherAlert()
    alert.alertStyle = .warning
    alert.messageText = "계정 등록 문제"
    alert.informativeText = message
    alert.addButton(withTitle: "확인")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
}
