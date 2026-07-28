import Foundation

public enum RegistryCodecError: Error, Equatable, Sendable {
    case invalidDocument
    case unsupportedSchemaVersion
    case invalidRegistry(ProfileRegistryError)
}

public enum RegistryCodec {
    public static func encode(_ registry: ProfileRegistry) throws -> Data {
        let document = RegistryDocument(
            schemaVersion: registry.schemaVersion,
            activeProfileId: registry.activeProfileID,
            profiles: registry.profiles
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        do {
            return try encoder.encode(document)
        } catch {
            throw RegistryCodecError.invalidDocument
        }
    }

    public static func decode(_ data: Data) throws -> ProfileRegistry {
        do {
            try StrictJSONDocumentValidator.validate(data)
            try validateSchemaKeys(data)
        } catch {
            throw RegistryCodecError.invalidDocument
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document: RegistryDocument
        do {
            document = try decoder.decode(RegistryDocument.self, from: data)
        } catch {
            throw RegistryCodecError.invalidDocument
        }

        guard document.schemaVersion == 1 else {
            throw RegistryCodecError.unsupportedSchemaVersion
        }

        do {
            return try ProfileRegistry(
                activeProfileID: document.activeProfileId,
                profiles: document.profiles
            )
        } catch let error as ProfileRegistryError {
            throw RegistryCodecError.invalidRegistry(error)
        } catch {
            throw RegistryCodecError.invalidDocument
        }
    }

    private static func validateSchemaKeys(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RegistryCodecError.invalidDocument
        }
        let rootKeys = Set(root.keys)
        let requiredRootKeys: Set<String> = ["schemaVersion", "profiles"]
        let allowedRootKeys = requiredRootKeys.union(["activeProfileId"])
        guard requiredRootKeys.isSubset(of: rootKeys), rootKeys.isSubset(of: allowedRootKeys),
              let profiles = root["profiles"] as? [Any] else {
            throw RegistryCodecError.invalidDocument
        }

        let requiredProfileKeys: Set<String> = [
            "id", "label", "email", "needsRelogin", "createdAt", "updatedAt",
        ]
        let allowedProfileKeys = requiredProfileKeys.union(["planType"])
        for value in profiles {
            guard let profile = value as? [String: Any] else {
                throw RegistryCodecError.invalidDocument
            }
            let keys = Set(profile.keys)
            guard requiredProfileKeys.isSubset(of: keys), keys.isSubset(of: allowedProfileKeys) else {
                throw RegistryCodecError.invalidDocument
            }
        }
    }
}

private struct RegistryDocument: Codable {
    let schemaVersion: Int
    let activeProfileId: ProfileID?
    let profiles: [ProfileMetadata]
}
