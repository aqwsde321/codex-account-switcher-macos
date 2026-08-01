import AppKit
import CodexAccountCore
import CodexAccountMenuBarModel
import Darwin
import SwiftUI

private let productCredentialService = "CodexAccountSwitcher.credentials.v1"

@main
struct CodexAccountMenuBarApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate
    @StateObject private var model: MenuBarViewModel

    init() {
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == "--keychain-smoke-test" {
            Darwin.exit(runKeychainSmokeTest())
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let storeURL = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
        let authURL = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        let provider = try? LocalCLIDataProvider(
            storeURL: storeURL,
            activeAuthURL: authURL,
            credentialStore: KeychainCredentialStore(
                service: productCredentialService
            ),
            confirmAppOwnedTermination: { count in
                await MainActor.run {
                    confirmAppOwnedTermination(count: count)
                }
            }
        )
        _model = StateObject(
            wrappedValue: MenuBarViewModel(
                loadProfiles: {
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.profiles()
                },
                loadRecoveryStatus: {
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.recoveryStatus()
                },
                captureProfile: {
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.captureProfile(label: $0)
                },
                syncActiveProfile: {
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.syncActiveProfile()
                },
                switchProfile: { target, onPhaseChange in
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.switchProfile(
                        target: target,
                        onPhaseChange: onPhaseChange
                    )
                },
                reloginProfile: { target in
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.reloginProfile(target: target)
                },
                restoreRecoveryProfile: { target, transactionID in
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.restoreRecoveryProfile(
                        target: target,
                        expectedTransactionID: transactionID
                    )
                },
                attemptAutomaticRecovery: {
                    guard let provider else { return }
                    _ = try? await provider.recoverPendingTransaction()
                }
            )
        )
    }

    var body: some Scene {
        MenuBarExtra("Codex Accounts", systemImage: "person.2.circle") {
            AccountMenuView(model: model)
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
            }
            if model.profiles.isEmpty {
                Text(model.isWorking ? "불러오는 중…" : "등록된 계정이 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.profiles, id: \.id) { profile in
                    Button {
                        Task { await model.select(profile) }
                    } label: {
                        ProfileCard(profile: profile)
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        model.isWorking
                            || model.recoveryRequired
                    )
                }
            }

            if let progressMessage = model.switchProgressMessage {
                Text(progressMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("전환 상태: \(progressMessage)")
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
                }
                .disabled(model.isWorking)
                .confirmationDialog(
                    "\(recoveryProfile.label) 계정을 복구할까요?",
                    isPresented: recoveryConfirmationPresented,
                    titleVisibility: .visible,
                    presenting: model.pendingRecoveryConfirmation
                ) { confirmation in
                    Button("복구", role: .destructive) {
                        Task { await model.confirmRecovery(confirmation) }
                    }
                    Button("취소", role: .cancel) {
                        model.cancelRecovery()
                    }
                } message: { _ in
                    Text("공식 앱을 정상 종료하고 저장된 이전 인증으로 복구합니다. 독립 Codex CLI와 IDE 작업은 먼저 직접 종료하세요.")
                }
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
                        Button("현재 로그인 등록") {
                            let label = registrationLabel
                            guard confirmRegistration() else { return }
                            Task {
                                if await model.register(label: label)
                                    || model.recoveryRequired {
                                    registrationLabel = ""
                                    isRegistering = false
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
        }
        .padding(14)
        .frame(width: 320)
        .task { await model.load() }
        .confirmationDialog(
            "계정을 전환할까요?",
            isPresented: confirmationPresented,
            titleVisibility: .visible,
            presenting: model.pendingProfile
        ) { profile in
            Button("전환") {
                Task { await model.confirmSwitch(profile) }
            }
            Button("취소", role: .cancel) {
                model.cancelSwitch()
            }
        } message: { profile in
            Text("\(profile.label) 계정으로 전환합니다.")
        }
        .confirmationDialog(
            "\(model.pendingReloginProfile?.label ?? "선택한") 계정의 재로그인을 반영할까요?",
            isPresented: reloginConfirmationPresented,
            titleVisibility: .visible,
            presenting: model.pendingReloginProfile
        ) { profile in
            Button("재로그인 반영") {
                Task { await model.confirmRelogin(profile) }
            }
            Button("취소", role: .cancel) {
                model.cancelRelogin()
            }
        } message: { profile in
            Text("먼저 공식 Codex 앱에서 \(profile.label) 계정으로 로그인하세요. 앱과 독립 Codex 프로세스를 모두 종료한 뒤 진행하세요. 완료 후 앱은 직접 열어야 합니다.")
        }
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { model.pendingProfile != nil },
            set: { presented in
                if !presented {
                    model.cancelSwitch()
                }
            }
        )
    }

    private var recoveryConfirmationPresented: Binding<Bool> {
        Binding(
            get: { model.pendingRecoveryConfirmation != nil },
            set: { presented in
                if !presented {
                    model.cancelRecovery()
                }
            }
        )
    }

    private var reloginConfirmationPresented: Binding<Bool> {
        Binding(
            get: { model.pendingReloginProfile != nil },
            set: { presented in
                if !presented {
                    model.cancelRelogin()
                }
            }
        )
    }

    private var registrationLabelIsValid: Bool {
        !registrationLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && registrationLabel.unicodeScalars.count <= 64
    }

    private var registrationHelp: String {
        if model.profiles.isEmpty {
            return "등록하면 공식 Codex 앱을 정상 종료하고 현재 로그인을 저장한 뒤 다시 엽니다. 독립 Codex CLI와 IDE는 먼저 직접 종료하세요."
        }
        return "등록하면 공식 Codex 앱을 정상 종료하고 현재 로그인을 저장한 뒤 기존 활성 계정으로 복귀해 다시 엽니다. 독립 Codex CLI와 IDE는 먼저 직접 종료하세요."
    }
}

private struct ProfileCard: View {
    let profile: ProfileListItem

    var body: some View {
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(profile.active ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.label), \(profile.email)")
        .accessibilityValue(
            profile.needsRelogin
                ? "재로그인 필요"
                : (profile.active ? "활성 계정" : "비활성 계정")
        )
    }
}

private enum MenuBarStartupFailure: Error, Sendable {
    case credentialStoreConfiguration
}

private enum KeychainSmokeFailure: Error {
    case credentialMismatch
    case deletedCredentialReadable
}

private func runKeychainSmokeTest() -> Int32 {
    let profileID = ProfileID(UUID())
    let service = "\(productCredentialService).smoke.\(UUID().uuidString)"
    var stage = "configuration"
    var created = false

    do {
        let store = try KeychainCredentialStore(service: service)
        let first = try CredentialBlob(
            validating: Data(
                #"{"auth_mode":"chatgpt","tokens":{"id_token":"synthetic-id-1","access_token":"synthetic-access-1","refresh_token":"synthetic-refresh-1"}}"#.utf8
            )
        )
        let second = try CredentialBlob(
            validating: Data(
                #"{"auth_mode":"chatgpt","tokens":{"id_token":"synthetic-id-2","access_token":"synthetic-access-2","refresh_token":"synthetic-refresh-2"}}"#.utf8
            )
        )

        stage = "create"
        try store.saveCredential(first, for: profileID)
        created = true

        stage = "read"
        guard try store.loadCredential(for: profileID) == first else {
            throw KeychainSmokeFailure.credentialMismatch
        }

        stage = "update"
        try store.saveCredential(second, for: profileID)
        guard try store.loadCredential(for: profileID) == second else {
            throw KeychainSmokeFailure.credentialMismatch
        }

        stage = "delete"
        try store.removeCredential(for: profileID)
        try store.removeCredential(for: profileID)

        stage = "verify-delete"
        do {
            _ = try store.loadCredential(for: profileID)
            throw KeychainSmokeFailure.deletedCredentialReadable
        } catch CredentialStoreError.notFound {
            created = false
            print("keychain_smoke=passed")
            return 0
        }
    } catch {
        let cleanup: String
        if created,
           let store = try? KeychainCredentialStore(service: service) {
            do {
                try store.removeCredential(for: profileID)
                cleanup = "passed"
            } catch {
                cleanup = "failed"
            }
        } else {
            cleanup = "not_needed"
        }
        print("keychain_smoke=failed stage=\(stage) cleanup=\(cleanup)")
        return cleanup == "failed" ? 2 : 1
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
private func confirmRegistration() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "현재 로그인을 등록할까요?"
    alert.informativeText = "버튼을 누르면 공식 Codex 앱을 자동으로 정상 종료하고 현재 로그인을 저장한 뒤 다시 엽니다. 독립 Codex CLI와 IDE 작업은 먼저 직접 종료하세요."
    alert.addButton(withTitle: "Codex 자동 종료하고 등록")
    let cancel = alert.addButton(withTitle: "취소")
    cancel.keyEquivalent = "\u{1b}"
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
}
