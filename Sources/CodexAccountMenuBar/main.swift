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
                switchProfile: {
                    guard let provider else {
                        throw MenuBarStartupFailure.credentialStoreConfiguration
                    }
                    return try await provider.switchProfile(target: $0)
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
                    .disabled(model.isWorking || (profile.needsRelogin && !profile.active))
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("오류: \(errorMessage)")
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
