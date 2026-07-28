import Foundation
import CodexAccountCore

func cliApplicationTests() -> [TestCase] {
    [
        TestCase("CLIApplication lists profiles without exposing email text") {
            let profileID = ProfileID(UUID())
            let provider = StubCLIDataProvider(
                profiles: [
                    ProfileListItem(
                        id: profileID,
                        label: "personal",
                        email: "sensitive@private.example",
                        active: true,
                        needsRelogin: false
                    ),
                ]
            )
            let application = CLIApplication(provider: provider)

            let result = await application.run(arguments: ["profiles", "list"])

            try expect(result.exitCode == 0, "profiles list failed")
            try expect(result.standardOutput.contains("personal"), "profile label missing")
            try expect(result.standardOutput.contains("<email-redacted>"), "masked email missing")
            try expect(!result.standardOutput.contains("sensitive"), "email local part leaked")
            try expect(!result.standardOutput.contains("private.example"), "email domain leaked")
        },
        TestCase("CLIApplication never renders an arbitrary thrown error") {
            let provider = StubCLIDataProvider(profiles: [], failureCanary: "secret-error-canary")
            let application = CLIApplication(provider: provider)

            let result = await application.run(arguments: ["inspect"])

            try expect(result.exitCode != 0, "failing inspect returned success")
            try expect(!result.standardError.contains("secret-error-canary"), "raw error leaked")
            try expect(result.standardError == "error=operation_failed\n", "error output is not allow-listed")
        },
    ]
}

private actor StubCLIDataProvider: ReadOnlyCLIDataProviding {
    let profilesValue: [ProfileListItem]
    let failureCanary: String?

    init(profiles: [ProfileListItem], failureCanary: String? = nil) {
        profilesValue = profiles
        self.failureCanary = failureCanary
    }

    func inspect() async throws -> InspectionReport {
        if let failureCanary {
            throw StubCLIError.text(failureCanary)
        }
        return InspectionReport(
            applicationStatus: .ready,
            version: "test",
            build: "test",
            authStatus: .privateRegularFile,
            appOwnedProcessCount: 0,
            independentCodexProcessCount: 0,
            unclassifiedRelevantProcessCount: 0
        )
    }

    func profiles() async throws -> [ProfileListItem] {
        profilesValue
    }

    func recoveryStatus() async throws -> RecoveryCLIStatus {
        .none
    }
}

private enum StubCLIError: Error {
    case text(String)
}
