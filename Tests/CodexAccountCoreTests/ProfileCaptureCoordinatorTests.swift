import Foundation
import CodexAccountCore

func profileCaptureCoordinatorTests() -> [TestCase] {
    [
        TestCase("ProfileCaptureCoordinator refreshes and commits the first active profile") {
            let profileID = ProfileID(UUID())
            let driver = RecordingProfileCaptureDriver(
                profileID: profileID,
                accounts: [
                    .chatGPT(
                        email: "person@example.invalid",
                        planType: "plus",
                        requiresOpenAIAuth: true
                    ),
                    .chatGPT(
                        email: "person@example.invalid",
                        planType: "plus",
                        requiresOpenAIAuth: true
                    ),
                ]
            )
            let coordinator = ProfileCaptureCoordinator(driver: driver)

            let profile = try await coordinator.capture(label: "A")
            let events = await driver.events
            let committed = await driver.committedProfile

            try expect(profile.id == profileID, "prepared profile ID changed")
            try expect(profile.label == "A", "profile label changed")
            try expect(profile.email == "person@example.invalid", "account identity changed")
            try expect(profile.planType == "plus", "plan type changed")
            try expect(profile.createdAt == profile.updatedAt, "capture timestamps differ")
            try expect(committed == profile, "committed profile differs from result")
            try expect(
                events == [
                    "prepare", "probe:false", "probe:true", "read", "verify", "gate", "commit", "finish",
                ],
                "capture side effects ran out of order"
            )
        },
        TestCase("ProfileCaptureCoordinator rejects an unsafe account email before reading auth") {
            let driver = RecordingProfileCaptureDriver(
                profileID: ProfileID(UUID()),
                accounts: [
                    .chatGPT(
                        email: "unsafe\n@example.invalid",
                        planType: nil,
                        requiresOpenAIAuth: true
                    ),
                ]
            )
            let coordinator = ProfileCaptureCoordinator(driver: driver)

            try await expectAsyncError(
                ProfileCaptureFailure.invalidEmail,
                "unsafe account email was captured"
            ) {
                _ = try await coordinator.capture(label: "A")
            }

            let events = await driver.events
            try expect(events == ["prepare", "probe:false", "abort"], "auth was read after unsafe identity")
        },
        TestCase("ProfileCaptureCoordinator rejects a refreshed identity mismatch") {
            let driver = RecordingProfileCaptureDriver(
                profileID: ProfileID(UUID()),
                accounts: [
                    .chatGPT(
                        email: "a@example.invalid",
                        planType: nil,
                        requiresOpenAIAuth: true
                    ),
                    .chatGPT(
                        email: "b@example.invalid",
                        planType: nil,
                        requiresOpenAIAuth: true
                    ),
                ]
            )
            let coordinator = ProfileCaptureCoordinator(driver: driver)

            try await expectAsyncError(
                ProfileCaptureFailure.identityMismatch,
                "refreshed account mismatch was captured"
            ) {
                _ = try await coordinator.capture(label: "A")
            }

            let events = await driver.events
            try expect(
                events == ["prepare", "probe:false", "probe:true", "abort"],
                "credential was read after refreshed identity mismatch"
            )
        },
    ]
}

private actor RecordingProfileCaptureDriver: ProfileCaptureDriving {
    private let profileID: ProfileID
    private var accounts: [AppServerAccountRead]
    private(set) var events = [String]()
    private(set) var committedProfile: ProfileMetadata?

    init(profileID: ProfileID, accounts: [AppServerAccountRead]) {
        self.profileID = profileID
        self.accounts = accounts
    }

    func prepareCapture() async throws -> ProfileID {
        events.append("prepare")
        return profileID
    }

    func probeAccount(refreshToken: Bool) async throws -> AppServerAccountRead {
        events.append("probe:\(refreshToken)")
        return accounts.removeFirst()
    }

    func readActiveCredential() async throws -> CredentialBlob {
        events.append("read")
        return try CredentialBlob(
            validating: Data(
                #"{"auth_mode":"chatgpt","tokens":{"id_token":"id","access_token":"access","refresh_token":"refresh"}}"#.utf8
            )
        )
    }

    func verifyCapturedCredential(_ credential: CredentialBlob, expectedEmail: String) async throws {
        events.append("verify")
    }

    func revalidateMutationGate() async throws {
        events.append("gate")
    }

    func commit(profile: ProfileMetadata, credential: CredentialBlob) async throws {
        events.append("commit")
        committedProfile = profile
    }

    func finishCapture() async {
        events.append("finish")
    }

    func abortCapture() async throws {
        events.append("abort")
    }
}
