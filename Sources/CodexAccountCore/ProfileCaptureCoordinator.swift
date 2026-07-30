import Foundation

public protocol ProfileCaptureDriving: Sendable {
    func prepareCapture() async throws -> ProfileID
    func probeAccount(refreshToken: Bool) async throws -> AppServerAccountRead
    func readActiveCredential() async throws -> CredentialBlob
    func verifyCapturedCredential(_ credential: CredentialBlob, expectedEmail: String) async throws
    func revalidateMutationGate() async throws
    func commit(profile: ProfileMetadata, credential: CredentialBlob) async throws
    func finishCapture() async
    func abortCapture() async throws
}

public enum ProfileCaptureFailure: Error, Equatable, Sendable {
    case invalidLabel
    case signedOut
    case missingEmail
    case invalidEmail
    case accountAlreadyRegistered
    case identityMismatch
    case rollbackFailed
}

public struct ProfileCaptureCoordinator: Sendable {
    private let driver: any ProfileCaptureDriving

    public init(driver: any ProfileCaptureDriving) {
        self.driver = driver
    }

    public func capture(label: String) async throws -> ProfileMetadata {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.unicodeScalars.count <= 64,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProfileCaptureFailure.invalidLabel
        }

        let profileID = try await driver.prepareCapture()
        do {
            let initial = try identity(from: await driver.probeAccount(refreshToken: false))
            let refreshed = try identity(from: await driver.probeAccount(refreshToken: true))
            guard refreshed.email == initial.email else {
                throw ProfileCaptureFailure.identityMismatch
            }

            let credential = try await driver.readActiveCredential()
            try await driver.verifyCapturedCredential(credential, expectedEmail: initial.email)
            try await driver.revalidateMutationGate()
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let profile = ProfileMetadata(
                id: profileID,
                label: label,
                email: initial.email,
                planType: refreshed.planType,
                needsRelogin: false,
                createdAt: now,
                updatedAt: now
            )
            try await driver.commit(profile: profile, credential: credential)
            await driver.finishCapture()
            return profile
        } catch {
            do {
                try await driver.abortCapture()
            } catch {
                throw ProfileCaptureFailure.rollbackFailed
            }
            throw error
        }
    }
}

private extension ProfileCaptureCoordinator {
    func identity(from account: AppServerAccountRead) throws -> (email: String, planType: String?) {
        switch account {
        case .signedOut:
            throw ProfileCaptureFailure.signedOut
        case let .chatGPT(email, planType, _):
            guard let email, !email.isEmpty else {
                throw ProfileCaptureFailure.missingEmail
            }
            guard email.unicodeScalars.count <= 320,
                  !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ProfileCaptureFailure.invalidEmail
            }
            return (email, planType)
        }
    }
}
