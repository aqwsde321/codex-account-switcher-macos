import Combine
import CodexSleepGuardCore
import Foundation

@MainActor
public final class SleepPreventionViewModel: ObservableObject {
    public typealias ReadEnabled = @Sendable () async throws -> Bool
    public typealias SetEnabled = @Sendable (Bool) async throws -> Void
    public typealias SaveAutoDisableThreshold =
        @Sendable (SleepGuardThreshold) async throws -> Void

    @Published public private(set) var isEnabled: Bool?
    @Published public private(set) var autoDisableThreshold: SleepGuardThreshold
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?

    private let readEnabled: ReadEnabled
    private let setEnabledOperation: SetEnabled
    private let saveAutoDisableThreshold: SaveAutoDisableThreshold

    public init(
        readEnabled: @escaping ReadEnabled,
        setEnabled: @escaping SetEnabled,
        initialAutoDisableThreshold: SleepGuardThreshold = .defaultValue,
        saveAutoDisableThreshold: @escaping SaveAutoDisableThreshold = { _ in }
    ) {
        self.readEnabled = readEnabled
        setEnabledOperation = setEnabled
        autoDisableThreshold = initialAutoDisableThreshold
        self.saveAutoDisableThreshold = saveAutoDisableThreshold
    }

    public func load() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            isEnabled = try await readEnabled()
            errorMessage = nil
        } catch {
            isEnabled = true
            errorMessage = "잠자기 방지 상태를 확인하지 못해 켜짐으로 표시합니다."
        }
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !isWorking, isEnabled != nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await setEnabledOperation(enabled)
            let actual = try await readEnabled()
            guard actual == enabled else { throw VerificationError() }
            isEnabled = actual
            errorMessage = nil
        } catch {
            do {
                isEnabled = try await readEnabled()
                errorMessage = "잠자기 방지 설정을 변경하지 못했습니다."
            } catch {
                isEnabled = true
                errorMessage = "잠자기 방지 상태를 확인하지 못해 켜짐으로 표시합니다."
            }
        }
    }

    public func setAutoDisableThreshold(_ threshold: SleepGuardThreshold) async {
        guard !isWorking, autoDisableThreshold != threshold else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await saveAutoDisableThreshold(threshold)
            autoDisableThreshold = threshold
            errorMessage = nil
        } catch {
            errorMessage = "배터리 자동 해제 설정을 저장하지 못했습니다."
        }
    }

    public nonisolated static func parsePMSetOutput(_ output: String) -> Bool? {
        SleepGuardPolicy.parsePMSetOutput(output)
    }
}

private struct VerificationError: Error {}
