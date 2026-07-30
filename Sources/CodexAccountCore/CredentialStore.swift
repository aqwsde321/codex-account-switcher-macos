import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func saveCredential(_ credential: CredentialBlob, for profileID: ProfileID) throws
    func loadCredential(for profileID: ProfileID) throws -> CredentialBlob
    func removeCredential(for profileID: ProfileID) throws
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case invalidConfiguration
    case notFound
    case invalidCredential
    case accessDenied
    case unavailable
    case operationFailed
}

public struct FileCredentialStore: CredentialStoring {
    private let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func saveCredential(_ credential: CredentialBlob, for profileID: ProfileID) throws {
        _ = try SpikeStore.openExisting(at: rootURL).saveCredential(credential, for: profileID)
    }

    public func loadCredential(for profileID: ProfileID) throws -> CredentialBlob {
        try SpikeStore.openExisting(at: rootURL).loadCredential(for: profileID)
    }

    public func removeCredential(for profileID: ProfileID) throws {
        _ = try SpikeStore.openExisting(at: rootURL).removeCredential(for: profileID)
    }
}

public struct KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let client: any GenericPasswordClient

    public init(service: String) throws {
        try self.init(service: service, client: SystemGenericPasswordClient())
    }

    package init(service: String, client: any GenericPasswordClient) throws {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              service.utf8.count <= 256,
              service.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CredentialStoreError.invalidConfiguration
        }
        self.service = service
        self.client = client
    }

    public func saveCredential(_ credential: CredentialBlob, for profileID: ProfileID) throws {
        let key = key(for: profileID)
        let data = CredentialBlob.persistenceData(for: credential)

        switch client.update(data, for: key) {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        case let status:
            throw Self.error(for: status)
        }

        switch client.add(data, for: key) {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let status = client.update(data, for: key)
            guard status == errSecSuccess else {
                throw Self.error(for: status)
            }
        case let status:
            throw Self.error(for: status)
        }
    }

    public func loadCredential(for profileID: ProfileID) throws -> CredentialBlob {
        let result = client.read(key(for: profileID))
        guard result.status == errSecSuccess else {
            throw Self.error(for: result.status)
        }
        guard let data = result.data else {
            throw CredentialStoreError.operationFailed
        }
        do {
            return try CredentialBlob(validating: data)
        } catch {
            throw CredentialStoreError.invalidCredential
        }
    }

    public func removeCredential(for profileID: ProfileID) throws {
        switch client.delete(key(for: profileID)) {
        case errSecSuccess, errSecItemNotFound:
            return
        case let status:
            throw Self.error(for: status)
        }
    }

    package static func error(for status: OSStatus) -> CredentialStoreError {
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecAuthFailed, errSecUserCanceled, errSecMissingEntitlement:
            return .accessDenied
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .unavailable
        default:
            return .operationFailed
        }
    }

    private func key(for profileID: ProfileID) -> GenericPasswordKey {
        GenericPasswordKey(service: service, account: profileID.description)
    }
}

package struct GenericPasswordKey: Equatable, Sendable {
    package let service: String
    package let account: String

    package init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

package protocol GenericPasswordClient: Sendable {
    func read(_ key: GenericPasswordKey) -> (status: OSStatus, data: Data?)
    func update(_ data: Data, for key: GenericPasswordKey) -> OSStatus
    func add(_ data: Data, for key: GenericPasswordKey) -> OSStatus
    func delete(_ key: GenericPasswordKey) -> OSStatus
}

private struct SystemGenericPasswordClient: GenericPasswordClient {
    func read(_ key: GenericPasswordKey) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query(for: key).merging([
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true,
            ]) { _, new in new } as CFDictionary,
            &result
        )
        return (status, result as? Data)
    }

    func update(_ data: Data, for key: GenericPasswordKey) -> OSStatus {
        SecItemUpdate(
            query(for: key) as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )
    }

    func add(_ data: Data, for key: GenericPasswordKey) -> OSStatus {
        SecItemAdd(
            query(for: key).merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]) { _, new in new } as CFDictionary,
            nil
        )
    }

    func delete(_ key: GenericPasswordKey) -> OSStatus {
        SecItemDelete(query(for: key) as CFDictionary)
    }

    private func query(for key: GenericPasswordKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
