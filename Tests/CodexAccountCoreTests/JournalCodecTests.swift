import Foundation
import CodexAccountCore

func journalCodecTests() -> [TestCase] {
    [
        TestCase("JournalCodec emits exactly seven fields") {
            let record = journalFixture()

            let data = try JournalCodec.encode(record)
            let decoded = try JournalCodec.decode(data)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let keys = Set(object?.keys ?? Dictionary<String, Any>().keys)

            try expect(decoded == record, "journal round trip changed data")
            try expect(
                keys == [
                    "schemaVersion", "transactionId", "phase", "previousProfileId",
                    "targetProfileId", "startedAt", "updatedAt",
                ],
                "journal fields differ from the seven-field contract"
            )
        },
        TestCase("JournalCodec rejects unknown and duplicate fields") {
            let valid = String(decoding: try JournalCodec.encode(journalFixture()), as: UTF8.self)
            let unknown = Data((valid.dropLast() + ",\"email\":\"hidden@example.invalid\"}").utf8)
            let duplicate = Data(("{\"schemaVersion\":1," + valid.dropFirst()).utf8)

            try expectError(JournalCodecError.invalidDocument, "unknown journal field was accepted") {
                _ = try JournalCodec.decode(unknown)
            }
            try expectError(JournalCodecError.invalidDocument, "duplicate journal field was accepted") {
                _ = try JournalCodec.decode(duplicate)
            }
        },
        TestCase("JournalCodec rejects BOM and trailing bytes") {
            let valid = try JournalCodec.encode(journalFixture())
            var bom = Data([0xEF, 0xBB, 0xBF])
            bom.append(valid)
            var trailing = valid
            trailing.append(contentsOf: [0x78])

            try expectError(JournalCodecError.invalidDocument, "journal BOM was accepted") {
                _ = try JournalCodec.decode(bom)
            }
            try expectError(JournalCodecError.invalidDocument, "trailing journal bytes were accepted") {
                _ = try JournalCodec.decode(trailing)
            }
        },
        TestCase("JournalCodec rejects contradictory identities and timestamps") {
            let profile = ProfileID(UUID())
            let reversedTime = SwitchJournalRecord(
                transactionID: UUID(),
                phase: .preparing,
                previousProfileID: ProfileID(UUID()),
                targetProfileID: ProfileID(UUID()),
                startedAt: Date(timeIntervalSince1970: 2),
                updatedAt: Date(timeIntervalSince1970: 1)
            )
            let sameProfile = SwitchJournalRecord(
                transactionID: UUID(),
                phase: .preparing,
                previousProfileID: profile,
                targetProfileID: profile,
                startedAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)
            )

            try expectError(JournalCodecError.invalidDocument, "reversed journal time was accepted") {
                _ = try JournalCodec.encode(reversedTime)
            }
            try expectError(JournalCodecError.invalidDocument, "same-profile journal was accepted") {
                _ = try JournalCodec.encode(sameProfile)
            }
        },
    ]
}

private func journalFixture() -> SwitchJournalRecord {
    SwitchJournalRecord(
        transactionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        phase: .preparing,
        previousProfileID: ProfileID(UUID(uuidString: "20000000-0000-0000-0000-000000000001")!),
        targetProfileID: ProfileID(UUID(uuidString: "30000000-0000-0000-0000-000000000001")!),
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
}
