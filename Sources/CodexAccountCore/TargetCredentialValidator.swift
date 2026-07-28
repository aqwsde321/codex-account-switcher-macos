public protocol TargetCredentialValidationDriving: Sendable {
    func prepareWorkspace(for profileID: ProfileID) async throws
    func probe(refreshToken: Bool) async throws -> AppServerAccountRead
    func readRefreshedCredential() async throws -> CredentialBlob
    func saveRefreshedCredential(_ credential: CredentialBlob, for profileID: ProfileID) async throws
    func cleanupWorkspace() async throws
}

public enum TargetValidationFailure: Error, Equatable, Sendable {
    case workspace
    case identity
    case probe
    case credentialRead
    case storage
    case cleanup
    case childStillAlive
}

public struct TargetCredentialValidator: Sendable {
    private let driver: any TargetCredentialValidationDriving

    public init(driver: any TargetCredentialValidationDriving) {
        self.driver = driver
    }

    public func validate(profile: ProfileMetadata) async throws {
        do {
            try await driver.prepareWorkspace(for: profile.id)
        } catch {
            throw TargetValidationFailure.workspace
        }

        let initial: AppServerAccountRead
        do {
            initial = try await driver.probe(refreshToken: false)
        } catch {
            try await fail(mappedProbeFailure(error), cleaningUp: shouldCleanUp(after: error))
        }
        do {
            try AccountIdentityValidator.validate(expectedEmail: profile.email, account: initial)
        } catch {
            try await fail(.identity, cleaningUp: true)
        }

        let refreshed: AppServerAccountRead
        do {
            refreshed = try await driver.probe(refreshToken: true)
        } catch {
            try await fail(mappedProbeFailure(error), cleaningUp: shouldCleanUp(after: error))
        }
        do {
            try AccountIdentityValidator.validate(expectedEmail: profile.email, account: refreshed)
        } catch {
            try await fail(.identity, cleaningUp: true)
        }

        let credential: CredentialBlob
        do {
            credential = try await driver.readRefreshedCredential()
        } catch {
            try await fail(.credentialRead, cleaningUp: true)
        }
        do {
            try await driver.saveRefreshedCredential(credential, for: profile.id)
        } catch {
            try await fail(.storage, cleaningUp: true)
        }

        do {
            try await driver.cleanupWorkspace()
        } catch {
            throw TargetValidationFailure.cleanup
        }
    }
}

private extension TargetCredentialValidator {
    func fail(
        _ failure: TargetValidationFailure,
        cleaningUp: Bool
    ) async throws -> Never {
        if cleaningUp {
            do {
                try await driver.cleanupWorkspace()
            } catch {
                throw TargetValidationFailure.cleanup
            }
        }
        throw failure
    }

    func mappedProbeFailure(_ error: Error) -> TargetValidationFailure {
        guard let failure = error as? AppServerProbeFailure else {
            return .probe
        }
        return failure.childDisposition == .unconfirmed ? .childStillAlive : .probe
    }

    func shouldCleanUp(after error: Error) -> Bool {
        guard let failure = error as? AppServerProbeFailure else {
            return true
        }
        return failure.childDisposition != .unconfirmed
    }
}
