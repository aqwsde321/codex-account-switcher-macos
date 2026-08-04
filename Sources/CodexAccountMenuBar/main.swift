import AppKit
import CodexAccountCore
import CodexAccountMenuBarModel
import SwiftUI

@main
struct CodexAccountMenuBarApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate
    @StateObject private var model: MenuBarViewModel

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let storeURL = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        let authURL = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        let provider = LocalCLIDataProvider(
            storeURL: storeURL,
            activeAuthURL: authURL,
            credentialStore: FileCredentialStore(rootURL: storeURL),
            confirmAppOwnedTermination: { count in
                await MainActor.run {
                    confirmAppOwnedTermination(count: count)
                }
            }
        )
        _model = StateObject(
            wrappedValue: MenuBarViewModel(
                loadProfiles: {
                    try await provider.profiles()
                },
                loadProfileUsage: {
                    try await provider.profileUsage()
                },
                loadRecoveryStatus: {
                    try await provider.recoveryStatus()
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
    }

    var body: some Scene {
        MenuBarExtra {
            AccountMenuView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2.circle")
                if let remaining = model.activeRemainingPercent {
                    Text("\(remaining)%")
                        .monospacedDigit()
                }
            }
            .task { await model.load() }
        }
        .menuBarExtraStyle(.window)
    }
}

private final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct AccountMenuView: View {
    @ObservedObject var model: MenuBarViewModel
    @State private var isRegistering = false
    @State private var isSyncConfirmationPresented = false
    @State private var registrationLabel = ""

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
                    HStack(spacing: 8) {
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
                                usageFailed: model.usageFailedProfileIDs.contains(profile.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

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
                    .disabled(model.isWorking || model.recoveryRequired)
                }
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

            if !isRegistering,
               !model.recoveryRequired,
               model.profiles.contains(where: \.active) {
                Button("현재 인증 동기화…") {
                    isSyncConfirmationPresented = true
                }
                .disabled(model.isWorking)
                .confirmationDialog(
                    "현재 인증을 저장할까요?",
                    isPresented: $isSyncConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("동기화") {
                        Task { await model.syncActive() }
                    }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("공식 앱과 독립 Codex 프로세스를 먼저 종료하세요. 현재 로그인 이메일이 활성 프로필과 같을 때만 저장합니다.")
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
            } else if !isSyncConfirmationPresented,
                      !model.recoveryRequired,
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
            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
            .disabled(model.isProfileLoginInProgress)
        }
        .padding(14)
        .frame(width: 320)
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

            if let usage {
                if usage.windows.isEmpty {
                    Text("한도 정보 없음")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(usage.windows.sorted(by: windowOrder).enumerated()), id: \.offset) {
                        _, window in
                        UsageWindowRow(window: window)
                    }
                }
            } else if usageFailed {
                Text("한도 조회 실패")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(profile.active ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
        )
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
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private func confirmAppOwnedTermination(count: Int) -> Bool {
    let alert = NSAlert()
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
private func confirmRegistration(additional: Bool) -> Bool {
    let alert = NSAlert()
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
    let alert = NSAlert()
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
    let alert = NSAlert()
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
    let alert = NSAlert()
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
    let alert = NSAlert()
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
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "계정 등록 문제"
    alert.informativeText = message
    alert.addButton(withTitle: "확인")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
}
