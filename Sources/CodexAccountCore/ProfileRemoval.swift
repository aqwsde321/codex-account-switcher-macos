import Foundation

package struct ProfileRemovalRecord: Equatable, Sendable {
    package let schemaVersion: Int
    package let transactionID: UUID
    package let profileID: ProfileID
    package let expectedActiveProfileID: ProfileID

    package init(
        transactionID: UUID,
        profileID: ProfileID,
        expectedActiveProfileID: ProfileID
    ) {
        schemaVersion = 1
        self.transactionID = transactionID
        self.profileID = profileID
        self.expectedActiveProfileID = expectedActiveProfileID
    }
}

package enum ProfileRemovalCodecError: Error, Equatable, Sendable {
    case invalidDocument
    case unsupportedSchemaVersion
}

package enum ProfileRemovalCodec {
    package static func encode(_ record: ProfileRemovalRecord) throws -> Data {
        try validate(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(ProfileRemovalDocument(record))
        } catch {
            throw ProfileRemovalCodecError.invalidDocument
        }
    }

    package static func decode(_ data: Data) throws -> ProfileRemovalRecord {
        do {
            try StrictJSONDocumentValidator.validate(data, maximumBytes: 1_024)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == [
                      "schemaVersion", "transactionId", "profileId", "expectedActiveProfileId",
                  ] else {
                throw ProfileRemovalCodecError.invalidDocument
            }
        } catch {
            throw ProfileRemovalCodecError.invalidDocument
        }

        let document: ProfileRemovalDocument
        do {
            document = try JSONDecoder().decode(ProfileRemovalDocument.self, from: data)
        } catch {
            throw ProfileRemovalCodecError.invalidDocument
        }
        guard document.schemaVersion == 1 else {
            throw ProfileRemovalCodecError.unsupportedSchemaVersion
        }
        let record = ProfileRemovalRecord(
            transactionID: document.transactionId,
            profileID: document.profileId,
            expectedActiveProfileID: document.expectedActiveProfileId
        )
        try validate(record)
        return record
    }

    private static func validate(_ record: ProfileRemovalRecord) throws {
        guard record.profileID != record.expectedActiveProfileID else {
            throw ProfileRemovalCodecError.invalidDocument
        }
    }
}

private struct ProfileRemovalDocument: Codable {
    let schemaVersion: Int
    let transactionId: UUID
    let profileId: ProfileID
    let expectedActiveProfileId: ProfileID

    init(_ record: ProfileRemovalRecord) {
        schemaVersion = record.schemaVersion
        transactionId = record.transactionID
        profileId = record.profileID
        expectedActiveProfileId = record.expectedActiveProfileID
    }
}
