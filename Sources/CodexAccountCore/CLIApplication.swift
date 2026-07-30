import Foundation

public enum ApplicationInspectionStatus: String, Equatable, Sendable {
    case ready
    case notFound = "not_found"
    case incompatible
}

public enum AuthInspectionStatus: String, Equatable, Sendable {
    case privateRegularFile = "private_regular_file"
    case absent
    case unsafe
}

public struct InspectionReport: Equatable, Sendable {
    public let applicationStatus: ApplicationInspectionStatus
    public let version: String?
    public let build: String?
    public let authStatus: AuthInspectionStatus
    public let appOwnedProcessCount: Int
    public let independentCodexProcessCount: Int
    public let unclassifiedRelevantProcessCount: Int

    public init(
        applicationStatus: ApplicationInspectionStatus,
        version: String?,
        build: String?,
        authStatus: AuthInspectionStatus,
        appOwnedProcessCount: Int,
        independentCodexProcessCount: Int,
        unclassifiedRelevantProcessCount: Int
    ) {
        self.applicationStatus = applicationStatus
        self.version = version
        self.build = build
        self.authStatus = authStatus
        self.appOwnedProcessCount = appOwnedProcessCount
        self.independentCodexProcessCount = independentCodexProcessCount
        self.unclassifiedRelevantProcessCount = unclassifiedRelevantProcessCount
    }
}

public struct ProfileListItem: Equatable, Sendable {
    public let id: ProfileID
    public let label: String
    public let email: String
    public let active: Bool
    public let needsRelogin: Bool

    public init(
        id: ProfileID,
        label: String,
        email: String,
        active: Bool,
        needsRelogin: Bool
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.active = active
        self.needsRelogin = needsRelogin
    }
}

public enum RecoveryCLIStatus: Equatable, Sendable {
    case none
    case pending(transactionID: String, phase: SwitchPhase)
    case blocked
}

public protocol CLIDataProviding: Sendable {
    func inspect() async throws -> InspectionReport
    func profiles() async throws -> [ProfileListItem]
    func captureProfile(label: String) async throws -> ProfileListItem
    func syncActiveProfile() async throws -> ProfileListItem
    func switchProfile(target: String) async throws -> ProfileListItem
    func recoveryStatus() async throws -> RecoveryCLIStatus
}

public struct CLIResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct CLIApplication: Sendable {
    private let provider: any CLIDataProviding

    public init(provider: any CLIDataProviding) {
        self.provider = provider
    }

    public func run(arguments: [String], mutationConfirmed: Bool = false) async -> CLIResult {
        do {
            if arguments.count == 3,
               arguments[0...1] == ["switch", "--target"] {
                guard mutationConfirmed else {
                    return CLIResult(
                        exitCode: 77,
                        standardOutput: "",
                        standardError: "error=confirmation_required\n"
                    )
                }
                return CLIResult(
                    exitCode: 0,
                    standardOutput: render([try await provider.switchProfile(target: arguments[2])]),
                    standardError: ""
                )
            }
            if arguments == ["profile", "sync-active"] {
                guard mutationConfirmed else {
                    return CLIResult(
                        exitCode: 77,
                        standardOutput: "",
                        standardError: "error=confirmation_required\n"
                    )
                }
                return CLIResult(
                    exitCode: 0,
                    standardOutput: render([try await provider.syncActiveProfile()]),
                    standardError: ""
                )
            }
            if arguments.count == 4,
               arguments[0...2] == ["profile", "capture", "--label"] {
                guard mutationConfirmed else {
                    return CLIResult(
                        exitCode: 77,
                        standardOutput: "",
                        standardError: "error=confirmation_required\n"
                    )
                }
                return CLIResult(
                    exitCode: 0,
                    standardOutput: render([try await provider.captureProfile(label: arguments[3])]),
                    standardError: ""
                )
            }
            switch arguments {
            case [], ["help"], ["--help"]:
                return CLIResult(exitCode: 0, standardOutput: usage, standardError: "")
            case ["inspect"]:
                return CLIResult(
                    exitCode: 0,
                    standardOutput: render(try await provider.inspect()),
                    standardError: ""
                )
            case ["profiles", "list"]:
                return CLIResult(
                    exitCode: 0,
                    standardOutput: render(try await provider.profiles()),
                    standardError: ""
                )
            case ["recovery", "status"]:
                return CLIResult(
                    exitCode: 0,
                    standardOutput: render(try await provider.recoveryStatus()),
                    standardError: ""
                )
            default:
                return CLIResult(exitCode: 64, standardOutput: "", standardError: "error=invalid_command\n")
            }
        } catch {
            return CLIResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "error=\(safeErrorCode(error))\n"
            )
        }
    }
}

private extension CLIApplication {
    var usage: String {
        """
        codex-account-spike <command>
          inspect
          profiles list
          profile capture --label <label>
          profile sync-active
          switch --target <profile-id-or-label>
          recovery status
        """ + "\n"
    }

    func render(_ report: InspectionReport) -> String {
        [
            "read_only=true",
            "application=\(report.applicationStatus.rawValue)",
            "version=\(safeField(report.version ?? "unknown"))",
            "build=\(safeField(report.build ?? "unknown"))",
            "auth=\(report.authStatus.rawValue)",
            "process.app_owned=\(report.appOwnedProcessCount)",
            "process.independent_codex=\(report.independentCodexProcessCount)",
            "process.unclassified_relevant=\(report.unclassifiedRelevantProcessCount)",
        ].joined(separator: "\n") + "\n"
    }

    func render(_ profiles: [ProfileListItem]) -> String {
        guard !profiles.isEmpty else { return "profiles=none\n" }
        return profiles.map { profile in
            [
                "profile",
                "id=\(profile.id)",
                "active=\(profile.active)",
                "label=\(safeField(profile.label))",
                "email=\(SafeEmailMasker.mask(profile.email))",
                "needs_relogin=\(profile.needsRelogin)",
            ].joined(separator: " ")
        }.joined(separator: "\n") + "\n"
    }

    func render(_ status: RecoveryCLIStatus) -> String {
        switch status {
        case .none:
            return "recovery=none\n"
        case let .pending(transactionID, phase):
            return "recovery=pending transaction_id=\(safeField(transactionID)) phase=\(phase.rawValue)\n"
        case .blocked:
            return "recovery=blocked\n"
        }
    }

    func safeField(_ value: String) -> String {
        let scalars = value.unicodeScalars.prefix(64).map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? "?" : Character(String(scalar))
        }
        return String(scalars)
    }

    func safeErrorCode(_ error: Error) -> String {
        switch error {
        case ProfileCaptureFailure.invalidLabel:
            "invalid_label"
        case ProfileCaptureFailure.signedOut:
            "signed_out"
        case ProfileCaptureFailure.missingEmail:
            "missing_email"
        case ProfileCaptureFailure.invalidEmail:
            "invalid_email"
        case ProfileCaptureFailure.accountAlreadyRegistered:
            "account_already_registered"
        case ProfileCaptureFailure.identityMismatch:
            "identity_mismatch"
        case ProfileCaptureFailure.rollbackFailed:
            "rollback_failed"
        case LocalCLIDataProviderFailure.captureAlreadyRunning,
             LocalCLIDataProviderFailure.lockBusy:
            "capture_busy"
        case LocalCLIDataProviderFailure.pendingRecovery:
            "recovery_required"
        case LocalCLIDataProviderFailure.profileAlreadyExists:
            "profile_already_exists"
        case LocalCLIDataProviderFailure.activeProfileUnavailable:
            "active_profile_unavailable"
        case LocalCLIDataProviderFailure.targetProfileUnavailable:
            "target_profile_unavailable"
        case LocalCLIDataProviderFailure.targetNeedsRelogin:
            "target_needs_relogin"
        case LocalCLIDataProviderFailure.switchAlreadyRunning,
             SwitchCoordinatorFailure.transactionInProgress,
             SwitchCoordinatorFailure.lockBusy:
            "switch_busy"
        case SwitchCoordinatorFailure.recoveryRequired:
            "recovery_required"
        case SwitchCoordinatorFailure.rollbackFailed:
            "rollback_failed"
        case LocalCLIDataProviderFailure.incompatibleApplication:
            "incompatible_application"
        case is CodexAppLocatorFailure:
            "incompatible_application"
        case LocalCLIDataProviderFailure.processBlocked,
             LocalCLIDataProviderFailure.processSnapshotUnstable,
             SwitchCoordinatorFailure.processBlocked:
            "process_blocked"
        case LocalCLIDataProviderFailure.activeAuthChanged:
            "active_auth_changed"
        case is AppServerProbeFailure:
            "account_probe_failed"
        default:
            "operation_failed"
        }
    }
}
