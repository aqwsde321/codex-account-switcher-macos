import Foundation

/// The authorization URL is held only while the isolated login is waiting.
/// Descriptions intentionally omit it so diagnostics cannot include OAuth state.
public enum ProfileLoginProgress: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    case preparing
    case validatingCurrentAccount
    case startingLogin
    case awaitingBrowser(URL)
    case validatingNewAccount
    case savingAccount

    public var description: String {
        switch self {
        case .preparing: "preparing"
        case .validatingCurrentAccount: "validating_current_account"
        case .startingLogin: "starting_login"
        case .awaitingBrowser: "awaiting_browser"
        case .validatingNewAccount: "validating_new_account"
        case .savingAccount: "saving_account"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(reflecting: description) }
}

package func profileLoginFailureDiagnostic(_ error: Error) -> String {
    switch error {
    case let failure as CodexLoginFailure:
        return "login_\(failure.code) exit=\(failure.exitCode.map(String.init) ?? "none")"
    case let failure as AppServerProbeFailure:
        return "account_probe_\(failure.code) stage=\(failure.stage)"
    case let failure as LocalCLIDataProviderFailure:
        return "provider_\(failure)"
    case let failure as ProfileCaptureFailure:
        return "capture_\(failure)"
    case let failure as CodexAppLocatorFailure:
        return "application_\(failure)"
    case let failure as DurableFileFailure:
        return "storage_\(failure.stage) errno=\(failure.errno)"
    case is CancellationError:
        return "cancelled"
    default:
        return "unknown"
    }
}
