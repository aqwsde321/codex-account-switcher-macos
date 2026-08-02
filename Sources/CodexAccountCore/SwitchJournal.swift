import Foundation

public enum SwitchPhase: String, Codable, CaseIterable, Sendable {
    case preparing
    case quitRequested
    case quiescent
    case refreshingCurrent
    case currentSaved
    case validatingTarget
    case targetValidated
    case authReplaced
    case targetLaunched
    case verifyingTarget
    case targetVerified
    case rollbackStarted
    case rollbackFailed
}

public enum SwitchTransitionError: Error, Equatable, Sendable {
    case invalidTransition
}

public enum SwitchStateMachine {
    public static let canonicalPhases: [SwitchPhase] = [
        .preparing,
        .quitRequested,
        .quiescent,
        .refreshingCurrent,
        .currentSaved,
        .validatingTarget,
        .targetValidated,
        .authReplaced,
        .targetLaunched,
        .verifyingTarget,
        .targetVerified,
    ]

    public static func validateTransition(from: SwitchPhase, to: SwitchPhase) throws {
        if (from == .rollbackStarted && to == .rollbackFailed)
            || (from == .rollbackFailed && to == .rollbackStarted) {
            return
        }

        let rollbackEligible: Set<SwitchPhase> = [
            .quiescent,
            .refreshingCurrent,
            .currentSaved,
            .validatingTarget,
            .targetValidated,
            .authReplaced,
            .targetLaunched,
            .verifyingTarget,
            .targetVerified,
        ]
        if to == .rollbackStarted, rollbackEligible.contains(from) {
            return
        }

        guard let index = canonicalPhases.firstIndex(of: from),
              index + 1 < canonicalPhases.count,
              canonicalPhases[index + 1] == to else {
            throw SwitchTransitionError.invalidTransition
        }
    }
}

public struct SwitchJournalRecord: Equatable, Sendable {
    public let schemaVersion: Int
    public let transactionID: UUID
    public let phase: SwitchPhase
    public let previousProfileID: ProfileID
    public let targetProfileID: ProfileID
    public let startedAt: Date
    public let updatedAt: Date

    public init(
        transactionID: UUID,
        phase: SwitchPhase,
        previousProfileID: ProfileID,
        targetProfileID: ProfileID,
        startedAt: Date,
        updatedAt: Date
    ) {
        schemaVersion = 1
        self.transactionID = transactionID
        self.phase = phase
        self.previousProfileID = previousProfileID
        self.targetProfileID = targetProfileID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public enum JournalCodecError: Error, Equatable, Sendable {
    case invalidDocument
    case unsupportedSchemaVersion
}

public enum JournalCodec {
    public static func encode(_ record: SwitchJournalRecord) throws -> Data {
        try validate(record)
        let document = JournalDocument(record)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(document)
        } catch {
            throw JournalCodecError.invalidDocument
        }
    }

    public static func decode(_ data: Data) throws -> SwitchJournalRecord {
        do {
            try StrictJSONDocumentValidator.validate(data, maximumBytes: 65_536)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == [
                      "schemaVersion", "transactionId", "phase", "previousProfileId",
                      "targetProfileId", "startedAt", "updatedAt",
                  ] else {
                throw JournalCodecError.invalidDocument
            }
        } catch {
            throw JournalCodecError.invalidDocument
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document: JournalDocument
        do {
            document = try decoder.decode(JournalDocument.self, from: data)
        } catch {
            throw JournalCodecError.invalidDocument
        }
        guard document.schemaVersion == 1 else {
            throw JournalCodecError.unsupportedSchemaVersion
        }

        let record = SwitchJournalRecord(
            transactionID: document.transactionId,
            phase: document.phase,
            previousProfileID: document.previousProfileId,
            targetProfileID: document.targetProfileId,
            startedAt: document.startedAt,
            updatedAt: document.updatedAt
        )
        try validate(record)
        return record
    }

    private static func validate(_ record: SwitchJournalRecord) throws {
        guard record.previousProfileID != record.targetProfileID,
              record.updatedAt >= record.startedAt else {
            throw JournalCodecError.invalidDocument
        }
    }
}

private struct JournalDocument: Codable {
    let schemaVersion: Int
    let transactionId: UUID
    let phase: SwitchPhase
    let previousProfileId: ProfileID
    let targetProfileId: ProfileID
    let startedAt: Date
    let updatedAt: Date

    init(_ record: SwitchJournalRecord) {
        schemaVersion = record.schemaVersion
        transactionId = record.transactionID
        phase = record.phase
        previousProfileId = record.previousProfileID
        targetProfileId = record.targetProfileID
        startedAt = record.startedAt
        updatedAt = record.updatedAt
    }
}
