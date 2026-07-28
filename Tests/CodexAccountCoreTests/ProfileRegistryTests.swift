import Foundation
import CodexAccountCore

func profileRegistryTests() -> [TestCase] {
    [
        TestCase("ProfileRegistry rejects a third MVP profile") {
            let now = Date(timeIntervalSince1970: 0)
            let profiles = (0..<3).map { index in
                ProfileMetadata(
                    id: ProfileID(UUID()),
                    label: "profile-\(index)",
                    email: "user-\(index)@example.invalid",
                    planType: nil,
                    needsRelogin: false,
                    createdAt: now,
                    updatedAt: now
                )
            }

            do {
                _ = try ProfileRegistry(activeProfileID: nil, profiles: profiles)
                throw TestFailure(description: "third profile was accepted")
            } catch ProfileRegistryError.tooManyProfiles {
                return
            }
        },
        TestCase("ProfileRegistry enforces unique IDs, labels, and exact emails") {
            let first = fixtureProfile(label: "personal", email: "User@example.invalid")

            try expectError(ProfileRegistryError.duplicateProfileID, "duplicate ID was accepted") {
                _ = try ProfileRegistry(activeProfileID: nil, profiles: [first, fixtureProfile(id: first.id)])
            }
            try expectError(ProfileRegistryError.duplicateLabel, "duplicate label was accepted") {
                _ = try ProfileRegistry(activeProfileID: nil, profiles: [first, fixtureProfile(label: first.label)])
            }
            try expectError(ProfileRegistryError.duplicateEmail, "duplicate email was accepted") {
                _ = try ProfileRegistry(activeProfileID: nil, profiles: [first, fixtureProfile(email: first.email)])
            }

            let caseDistinct = fixtureProfile(label: "work", email: "user@example.invalid")
            _ = try ProfileRegistry(activeProfileID: first.id, profiles: [first, caseDistinct])
        },
        TestCase("ProfileRegistry requires active ID to exist") {
            try expectError(ProfileRegistryError.activeProfileMissing, "unknown active ID was accepted") {
                _ = try ProfileRegistry(activeProfileID: ProfileID(UUID()), profiles: [fixtureProfile()])
            }
        },
        TestCase("ProfileRegistry rejects empty labels and emails without normalization") {
            try expectError(ProfileRegistryError.emptyLabel, "empty label was accepted") {
                _ = try ProfileRegistry(activeProfileID: nil, profiles: [fixtureProfile(label: "")])
            }
            try expectError(ProfileRegistryError.emptyEmail, "empty email was accepted") {
                _ = try ProfileRegistry(activeProfileID: nil, profiles: [fixtureProfile(email: "")])
            }
        },
    ]
}

private func fixtureProfile(
    id: ProfileID = ProfileID(UUID()),
    label: String = UUID().uuidString,
    email: String = "\(UUID().uuidString)@example.invalid"
) -> ProfileMetadata {
    let now = Date(timeIntervalSince1970: 0)
    return ProfileMetadata(
        id: id,
        label: label,
        email: email,
        planType: nil,
        needsRelogin: false,
        createdAt: now,
        updatedAt: now
    )
}
