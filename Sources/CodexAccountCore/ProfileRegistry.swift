import Foundation

public struct ProfileID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ProfileMetadata: Codable, Equatable, Sendable {
    public let id: ProfileID
    public let label: String
    public let email: String
    public let planType: String?
    public let needsRelogin: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: ProfileID,
        label: String,
        email: String,
        planType: String?,
        needsRelogin: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.planType = planType
        self.needsRelogin = needsRelogin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ProfileRegistryError: Error, Equatable, Sendable {
    case tooManyProfiles
    case duplicateProfileID
    case duplicateLabel
    case duplicateEmail
    case activeProfileMissing
    case emptyLabel
    case emptyEmail
}

public struct ProfileRegistry: Equatable, Sendable {
    public static let maximumProfileCount = 3

    public let schemaVersion: Int
    public let activeProfileID: ProfileID?
    public let profiles: [ProfileMetadata]

    public init(activeProfileID: ProfileID?, profiles: [ProfileMetadata]) throws {
        guard profiles.count <= Self.maximumProfileCount else {
            throw ProfileRegistryError.tooManyProfiles
        }
        guard !profiles.contains(where: { $0.label.isEmpty }) else {
            throw ProfileRegistryError.emptyLabel
        }
        guard !profiles.contains(where: { $0.email.isEmpty }) else {
            throw ProfileRegistryError.emptyEmail
        }
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw ProfileRegistryError.duplicateProfileID
        }
        guard Set(profiles.map(\.label)).count == profiles.count else {
            throw ProfileRegistryError.duplicateLabel
        }
        guard Set(profiles.map(\.email)).count == profiles.count else {
            throw ProfileRegistryError.duplicateEmail
        }
        if let activeProfileID, !profiles.contains(where: { $0.id == activeProfileID }) {
            throw ProfileRegistryError.activeProfileMissing
        }

        schemaVersion = 1
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }
}
