import AppKit
import CodexAccountCore
import CodexAccountMenuBarModel
import SwiftUI

@main
struct CodexAccountMenuBarApp: App {
    @StateObject private var model: MenuBarViewModel

    init() {
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
                service: "CodexAccountSwitcher.credentials.v1"
            )
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
                switchProfile: {
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.switchProfile(target: $0)
                },
                restoreRecoveryProfile: { target, transactionID in
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.restoreRecoveryProfile(
                        target: target,
                        expectedTransactionID: transactionID
                    )
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
                            || (profile.needsRelogin && !profile.active)
                    )
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
                            Task {
                                if await model.register(label: registrationLabel)
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

    private var registrationLabelIsValid: Bool {
        !registrationLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && registrationLabel.unicodeScalars.count <= 64
    }

    private var registrationHelp: String {
        if model.profiles.isEmpty {
            return "공식 앱과 독립 Codex 프로세스를 종료한 뒤 현재 로그인을 저장합니다."
        }
        return "현재 로그인을 저장한 뒤 기존 활성 계정으로 자동 복귀하고 앱을 다시 엽니다. 먼저 공식 앱과 독립 Codex 프로세스를 종료하세요."
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
        .accessibilityValue(profile.active ? "활성 계정" : "비활성 계정")
    }
}

private enum MenuBarStartupFailure: Error, Sendable {
    case credentialStoreConfiguration
}
