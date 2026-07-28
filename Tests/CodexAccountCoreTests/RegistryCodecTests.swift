import Foundation
import CodexAccountCore

func registryCodecTests() -> [TestCase] {
    [
        TestCase("RegistryCodec preserves profile order and opaque IDs") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let firstID = ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
            let secondID = ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
            let registry = try ProfileRegistry(
                activeProfileID: firstID,
                profiles: [
                    codecFixture(id: firstID, label: "personal", email: "person@example.invalid", now: now),
                    codecFixture(id: secondID, label: "work", email: "work@example.invalid", now: now),
                ]
            )

            let data = try RegistryCodec.encode(registry)
            let decoded = try RegistryCodec.decode(data)

            try expect(decoded == registry, "registry round trip changed data")
            try expect(!String(decoding: data, as: UTF8.self).contains("auth"), "registry included auth material")
        },
        TestCase("RegistryCodec rejects unknown and duplicate fields") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let profileID = ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
            let registry = try ProfileRegistry(
                activeProfileID: profileID,
                profiles: [codecFixture(id: profileID, label: "one", email: "one@example.invalid", now: now)]
            )
            let valid = String(decoding: try RegistryCodec.encode(registry), as: UTF8.self)
            let unknown = Data((valid.dropLast() + ",\"unknown\":true}").utf8)
            let duplicate = Data(("{\"schemaVersion\":1," + valid.dropFirst()).utf8)

            try expectError(RegistryCodecError.invalidDocument, "unknown registry field was accepted") {
                _ = try RegistryCodec.decode(unknown)
            }
            try expectError(RegistryCodecError.invalidDocument, "duplicate registry field was accepted") {
                _ = try RegistryCodec.decode(duplicate)
            }
        },
    ]
}

private func codecFixture(
    id: ProfileID,
    label: String,
    email: String,
    now: Date
) -> ProfileMetadata {
    ProfileMetadata(
        id: id,
        label: label,
        email: email,
        planType: "test-plan",
        needsRelogin: false,
        createdAt: now,
        updatedAt: now
    )
}
