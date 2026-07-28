import Foundation
import CodexAccountCore

func targetCredentialValidatorTests() -> [TestCase] {
    [
        TestCase("TargetCredentialValidator stops before refresh on identity mismatch") {
            let driver = RecordingTargetValidationDriver(
                accounts: [
                    .chatGPT(
                        email: "other@example.invalid",
                        planType: nil,
                        requiresOpenAIAuth: true
                    ),
                ]
            )
            let validator = TargetCredentialValidator(driver: driver)
            let profile = targetValidationProfile(email: "target@example.invalid")

            do {
                try await validator.validate(profile: profile)
                throw TestFailure(description: "mismatched target was accepted")
            } catch let failure as TargetValidationFailure {
                try expect(failure == .identity, "mismatch returned the wrong classification")
            }

            let events = await driver.events
            try expect(
                events == ["prepare", "probe:false", "cleanup"],
                "refresh or credential save occurred after mismatch"
            )
        },
        TestCase("TargetCredentialValidator preserves an unconfirmed child workspace") {
            let driver = RecordingTargetValidationDriver(
                accounts: [],
                probeFailure: AppServerProbeFailure(
                    code: .childExitUnconfirmed,
                    stage: .terminating,
                    childDisposition: .unconfirmed,
                    childPID: 123
                )
            )
            let validator = TargetCredentialValidator(driver: driver)

            do {
                try await validator.validate(profile: targetValidationProfile(email: "target@example.invalid"))
                throw TestFailure(description: "unconfirmed child was accepted")
            } catch let failure as TargetValidationFailure {
                try expect(failure == .childStillAlive, "unconfirmed child returned the wrong failure")
            }

            let events = await driver.events
            try expect(events == ["prepare", "probe:false"], "live child workspace was removed or reused")
        },
    ]
}

private actor RecordingTargetValidationDriver: TargetCredentialValidationDriving {
    private(set) var events = [String]()
    private var accounts: [AppServerAccountRead]
    private let probeFailure: AppServerProbeFailure?

    init(accounts: [AppServerAccountRead], probeFailure: AppServerProbeFailure? = nil) {
        self.accounts = accounts
        self.probeFailure = probeFailure
    }

    func prepareWorkspace(for profileID: ProfileID) async throws {
        events.append("prepare")
    }

    func probe(refreshToken: Bool) async throws -> AppServerAccountRead {
        events.append("probe:\(refreshToken)")
        if let probeFailure {
            throw probeFailure
        }
        return accounts.removeFirst()
    }

    func readRefreshedCredential() async throws -> CredentialBlob {
        events.append("read")
        return try CredentialBlob(
            validating: Data(
                #"{"auth_mode":"chatgpt","tokens":{"id_token":"id","access_token":"access","refresh_token":"refresh"}}"#.utf8
            )
        )
    }

    func saveRefreshedCredential(_ credential: CredentialBlob, for profileID: ProfileID) async throws {
        events.append("save")
    }

    func cleanupWorkspace() async throws {
        events.append("cleanup")
    }
}

private func targetValidationProfile(email: String) -> ProfileMetadata {
    let now = Date(timeIntervalSince1970: 0)
    return ProfileMetadata(
        id: ProfileID(UUID()),
        label: "target",
        email: email,
        planType: nil,
        needsRelogin: false,
        createdAt: now,
        updatedAt: now
    )
}
