import Foundation

public enum CredentialBlobError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidRoot
    case unsupportedAuthMode
    case missingTokens
    case missingTokenField(String)
}

public struct CredentialBlob: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    private let storage: Data

    public let byteCount: Int

    public var description: String { "<redacted credential>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(reflecting: description) }

    public init(validating data: Data) throws {
        let value: Any
        do {
            try StrictJSONDocumentValidator.validate(data)
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CredentialBlobError.invalidJSON
        }

        guard let root = value as? [String: Any] else {
            throw CredentialBlobError.invalidRoot
        }
        guard root["auth_mode"] as? String == "chatgpt" else {
            throw CredentialBlobError.unsupportedAuthMode
        }
        guard let tokens = root["tokens"] as? [String: Any] else {
            throw CredentialBlobError.missingTokens
        }

        for field in ["id_token", "access_token", "refresh_token"] {
            guard let token = tokens[field] as? String, !token.isEmpty else {
                throw CredentialBlobError.missingTokenField(field)
            }
        }

        storage = data
        byteCount = data.count
    }

    static func persistenceData(for credential: CredentialBlob) -> Data {
        credential.storage
    }
}
