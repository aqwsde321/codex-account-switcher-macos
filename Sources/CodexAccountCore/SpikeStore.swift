import Darwin
import Foundation

public enum PrivateDirectoryFailureCode: Equatable, Sendable {
    case invalidPath
    case openParent
    case create
    case openDirectory
    case unsafeDirectory
    case setMode
    case sync
}

public struct PrivateDirectoryFailure: Error, Equatable, Sendable {
    public let code: PrivateDirectoryFailureCode
    public let errno: Int32
}

public struct SpikeStore {
    public let rootURL: URL

    private let credentialsURL: URL
    private let files = DarwinDurableFileOperations()

    private init(rootURL: URL) {
        self.rootURL = rootURL
        credentialsURL = rootURL.appendingPathComponent("credentials", isDirectory: true)
    }

    public static func create(at rootURL: URL) throws -> SpikeStore {
        try PrivateDirectory.ensure(at: rootURL)
        let store = SpikeStore(rootURL: rootURL)
        try PrivateDirectory.ensure(at: store.credentialsURL)
        return store
    }

    public static func openExisting(at rootURL: URL) throws -> SpikeStore {
        try PrivateDirectory.validate(at: rootURL)
        let store = SpikeStore(rootURL: rootURL)
        try PrivateDirectory.validate(at: store.credentialsURL)
        return store
    }

    public func saveCredential(_ credential: CredentialBlob, for profileID: ProfileID) throws -> FileIdentity {
        let destination = credentialURL(for: profileID)
        let expected = try files.snapshot(at: destination)
        return try files.replace(
            contents: SensitiveBytes(CredentialBlob.persistenceData(for: credential)),
            at: destination,
            expecting: expected
        )
    }

    public func loadCredential(for profileID: ProfileID) throws -> CredentialBlob {
        let result = try files.read(at: credentialURL(for: profileID))
        return try CredentialBlob(validating: result.contents.data)
    }

    public func removeCredential(for profileID: ProfileID) throws -> DurableRemoval {
        let destination = credentialURL(for: profileID)
        let expected = try files.snapshot(at: destination)
        return try files.remove(at: destination, expecting: expected)
    }

    public func saveRegistry(_ registry: ProfileRegistry) throws -> FileIdentity {
        let data = try RegistryCodec.encode(registry)
        return try replace(contents: SensitiveBytes(data), at: registryURL)
    }

    public func loadRegistry() throws -> ProfileRegistry {
        let result = try files.read(at: registryURL)
        return try RegistryCodec.decode(result.contents.data)
    }

    public func loadRegistryIfPresent() throws -> ProfileRegistry? {
        guard try files.snapshot(at: registryURL) != .absent else {
            return nil
        }
        return try loadRegistry()
    }

    public func createCaptureProfileID() throws -> ProfileID {
        let profileID = ProfileID(UUID())
        _ = try files.replace(
            contents: SensitiveBytes(Data("\(profileID)\n".utf8)),
            at: captureProfileIDURL,
            expecting: .absent
        )
        return profileID
    }

    public func loadCaptureProfileIDIfPresent() throws -> ProfileID? {
        switch try files.snapshot(at: captureProfileIDURL) {
        case .absent:
            return nil
        case .exact:
            let result = try files.read(at: captureProfileIDURL, maximumBytes: 37)
            guard let text = String(data: result.contents.data, encoding: .utf8),
                  text.count == 37,
                  text.last == "\n",
                  let uuid = UUID(uuidString: String(text.dropLast())),
                  text == "\(uuid.uuidString)\n" else {
                throw SpikeStoreError.invalidCaptureProfileID
            }
            return ProfileID(uuid)
        }
    }

    public func removeCaptureProfileID() throws -> DurableRemoval {
        let expected = try files.snapshot(at: captureProfileIDURL)
        return try files.remove(at: captureProfileIDURL, expecting: expected)
    }

    package func createProfileRemovalIfAbsent(
        _ record: ProfileRemovalRecord
    ) throws -> FileIdentity? {
        do {
            return try files.replace(
                contents: SensitiveBytes(try ProfileRemovalCodec.encode(record)),
                at: profileRemovalURL,
                expecting: .absent
            )
        } catch let failure as DurableFileFailure
            where failure.mutation == .replace
                && failure.stage == .inspect
                && failure.errno == ESTALE
                && failure.certainty == .destinationUnchanged
        {
            return nil
        }
    }

    package func loadProfileRemovalIfPresent() throws -> ProfileRemovalRecord? {
        guard try files.snapshot(at: profileRemovalURL) != .absent else {
            return nil
        }
        let result = try files.read(at: profileRemovalURL, maximumBytes: 1_024)
        return try ProfileRemovalCodec.decode(result.contents.data)
    }

    package func removeProfileRemoval() throws -> DurableRemoval {
        let expected = try files.snapshot(at: profileRemovalURL)
        return try files.remove(at: profileRemovalURL, expecting: expected)
    }

    public func createJournalIfAbsent(_ journal: SwitchJournalRecord) throws -> FileIdentity? {
        let data = try JournalCodec.encode(journal)
        do {
            return try files.replace(
                contents: SensitiveBytes(data),
                at: journalURL,
                expecting: .absent
            )
        } catch let failure as DurableFileFailure
            where failure.mutation == .replace
                && failure.stage == .inspect
                && failure.errno == ESTALE
                && failure.certainty == .destinationUnchanged
        {
            return nil
        }
    }

    public func updateJournal(_ journal: SwitchJournalRecord) throws -> FileIdentity {
        try updateJournal(journal, allowingVerifiedTargetShortcut: false)
    }

    func updateVerifiedTargetJournal(_ journal: SwitchJournalRecord) throws -> FileIdentity {
        try updateJournal(journal, allowingVerifiedTargetShortcut: true)
    }

    private func updateJournal(
        _ journal: SwitchJournalRecord,
        allowingVerifiedTargetShortcut: Bool
    ) throws -> FileIdentity {
        let data = try JournalCodec.encode(journal)
        let normalizedJournal = try JournalCodec.decode(data)
        let expected = try files.snapshot(at: journalURL)
        guard case let .exact(identity) = expected else {
            throw SpikeStoreError.missingJournal
        }
        let current = try files.read(at: journalURL, maximumBytes: 65_536)
        guard current.identity == identity else {
            throw SpikeStoreError.concurrentMutation
        }
        let existingJournal = try JournalCodec.decode(current.contents.data)
        guard existingJournal.transactionID == normalizedJournal.transactionID,
              existingJournal.previousProfileID == normalizedJournal.previousProfileID,
              existingJournal.targetProfileID == normalizedJournal.targetProfileID,
              existingJournal.startedAt == normalizedJournal.startedAt,
              normalizedJournal.updatedAt >= existingJournal.updatedAt else {
            throw SpikeStoreError.invalidJournalUpdate
        }
        if allowingVerifiedTargetShortcut {
            guard existingJournal.phase == .validatingTarget || existingJournal.phase == .targetValidated,
                  normalizedJournal.phase == .targetVerified else {
                throw SpikeStoreError.invalidJournalUpdate
            }
        } else {
            do {
                try SwitchStateMachine.validateTransition(
                    from: existingJournal.phase,
                    to: normalizedJournal.phase
                )
            } catch {
                throw SpikeStoreError.invalidJournalUpdate
            }
        }
        return try files.replace(
            contents: SensitiveBytes(data),
            at: journalURL,
            expecting: expected
        )
    }

    public func loadJournalIfPresent() throws -> SwitchJournalRecord? {
        let expected = try files.snapshot(at: journalURL)
        guard case let .exact(identity) = expected else {
            return nil
        }
        let result = try files.read(at: journalURL, maximumBytes: 65_536)
        guard result.identity == identity else {
            throw SpikeStoreError.concurrentMutation
        }
        return try JournalCodec.decode(result.contents.data)
    }

    public func removeJournal() throws -> DurableRemoval {
        let expected = try files.snapshot(at: journalURL)
        return try files.remove(at: journalURL, expecting: expected)
    }

    package func createJournalFinalizationEvidence(
        _ evidence: JournalFinalizationEvidence
    ) throws -> FileIdentity {
        try files.replace(
            contents: SensitiveBytes(try JournalFinalizationEvidenceCodec.encode(evidence)),
            at: journalFinalizationEvidenceURL,
            expecting: .absent
        )
    }

    package func loadJournalFinalizationEvidenceIfPresent() throws -> JournalFinalizationEvidence? {
        guard try files.snapshot(at: journalFinalizationEvidenceURL) != .absent else {
            return nil
        }
        let result = try files.read(at: journalFinalizationEvidenceURL, maximumBytes: 1_024)
        return try JournalFinalizationEvidenceCodec.decode(result.contents.data)
    }

    package func removeJournalFinalizationEvidence() throws -> DurableRemoval {
        let expected = try files.snapshot(at: journalFinalizationEvidenceURL)
        return try files.remove(at: journalFinalizationEvidenceURL, expecting: expected)
    }

    public func tryAcquireTransactionLock() throws -> ExclusiveFileLock? {
        try ExclusiveFileLock.tryAcquire(at: rootURL.appendingPathComponent("switch.lock"))
    }

    private func credentialURL(for profileID: ProfileID) -> URL {
        credentialsURL.appendingPathComponent("\(profileID).json", isDirectory: false)
    }

    private var registryURL: URL {
        rootURL.appendingPathComponent("profiles.json", isDirectory: false)
    }

    private var journalURL: URL {
        rootURL.appendingPathComponent("switch-journal.json", isDirectory: false)
    }

    private var captureProfileIDURL: URL {
        rootURL.appendingPathComponent("capture-profile-id", isDirectory: false)
    }

    private var profileRemovalURL: URL {
        rootURL.appendingPathComponent("profile-removal.json", isDirectory: false)
    }

    private var journalFinalizationEvidenceURL: URL {
        rootURL.appendingPathComponent("journal-finalization.json", isDirectory: false)
    }

    private func replace(contents: SensitiveBytes, at url: URL) throws -> FileIdentity {
        let expected = try files.snapshot(at: url)
        return try files.replace(contents: contents, at: url, expecting: expected)
    }
}

package struct JournalFinalizationEvidence: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    package let transactionID: UUID
    package let journalPhase: SwitchPhase
    package let expectedActiveProfileID: ProfileID
    package let expectedActiveAuthSHA256: String

    package init(
        transactionID: UUID,
        journalPhase: SwitchPhase,
        expectedActiveProfileID: ProfileID,
        expectedActiveAuthSHA256: String
    ) {
        schemaVersion = 1
        self.transactionID = transactionID
        self.journalPhase = journalPhase
        self.expectedActiveProfileID = expectedActiveProfileID
        self.expectedActiveAuthSHA256 = expectedActiveAuthSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case transactionID = "transactionId"
        case journalPhase
        case expectedActiveProfileID = "expectedActiveProfileId"
        case expectedActiveAuthSHA256 = "expectedActiveAuthSha256"
    }
}

private enum JournalFinalizationEvidenceCodec {
    static func encode(_ evidence: JournalFinalizationEvidence) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(evidence)
    }

    static func decode(_ data: Data) throws -> JournalFinalizationEvidence {
        do {
            try StrictJSONDocumentValidator.validate(data, maximumBytes: 1_024)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == [
                      "schemaVersion", "transactionId", "journalPhase", "expectedActiveProfileId",
                      "expectedActiveAuthSha256",
                  ] else {
                throw SpikeStoreError.invalidJournalFinalizationEvidence
            }
        } catch {
            throw SpikeStoreError.invalidJournalFinalizationEvidence
        }
        let evidence: JournalFinalizationEvidence
        do {
            evidence = try JSONDecoder().decode(JournalFinalizationEvidence.self, from: data)
        } catch {
            throw SpikeStoreError.invalidJournalFinalizationEvidence
        }
        guard evidence.schemaVersion == 1,
              evidence.expectedActiveAuthSHA256.count == 64,
              evidence.expectedActiveAuthSHA256.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw SpikeStoreError.invalidJournalFinalizationEvidence
        }
        return evidence
    }
}

public enum SpikeStoreError: Error, Equatable, Sendable {
    case concurrentMutation
    case missingJournal
    case invalidJournalUpdate
    case invalidCaptureProfileID
    case invalidJournalFinalizationEvidence
}

enum PrivateDirectory {
    static func sync(at url: URL) throws {
        try validate(at: url)
        let fd = try openDirectory(path: url.path, code: .openDirectory)
        defer { Darwin.close(fd) }
        try sync(fd)
    }

    static func validate(at url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw PrivateDirectoryFailure(code: .invalidPath, errno: EINVAL)
        }
        let fd = try openDirectory(path: url.path, code: .openDirectory)
        defer { Darwin.close(fd) }

        var info = stat()
        var result: Int32
        repeat {
            result = Darwin.fstat(fd, &info)
        } while result == -1 && errno == EINTR
        guard result == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o700) else {
            throw PrivateDirectoryFailure(code: .unsafeDirectory, errno: EPERM)
        }
    }

    @discardableResult
    static func ensure(at url: URL) throws -> Bool {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".." else {
            throw PrivateDirectoryFailure(code: .invalidPath, errno: EINVAL)
        }

        let parentPath = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        let parentFD = try openDirectory(path: parentPath, code: .openParent)
        defer { Darwin.close(parentFD) }

        var created = false
        let createResult = name.withCString { Darwin.mkdirat(parentFD, $0, mode_t(0o700)) }
        if createResult == 0 {
            created = true
        } else if errno != EEXIST {
            let code = errno
            throw PrivateDirectoryFailure(code: .create, errno: code)
        }

        var directoryFD: Int32
        repeat {
            directoryFD = name.withCString {
                Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        } while directoryFD == -1 && errno == EINTR
        guard directoryFD >= 0 else {
            let code = errno
            throw PrivateDirectoryFailure(code: .openDirectory, errno: code)
        }
        defer { Darwin.close(directoryFD) }

        if created {
            var modeResult: Int32
            repeat {
                modeResult = Darwin.fchmod(directoryFD, mode_t(0o700))
            } while modeResult == -1 && errno == EINTR
            guard modeResult == 0 else {
                let code = errno
                _ = name.withCString { Darwin.unlinkat(parentFD, $0, AT_REMOVEDIR) }
                throw PrivateDirectoryFailure(code: .setMode, errno: code)
            }
        }

        var info = stat()
        var statResult: Int32
        repeat {
            statResult = Darwin.fstat(directoryFD, &info)
        } while statResult == -1 && errno == EINTR
        guard statResult == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o700) else {
            throw PrivateDirectoryFailure(code: .unsafeDirectory, errno: EPERM)
        }

        if created {
            try sync(directoryFD)
            try sync(parentFD)
        }
        return created
    }

    private static func openDirectory(path: String, code: PrivateDirectoryFailureCode) throws -> Int32 {
        var fd: Int32
        repeat {
            fd = path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        } while fd == -1 && errno == EINTR
        guard fd >= 0 else {
            let systemCode = errno
            throw PrivateDirectoryFailure(code: code, errno: systemCode)
        }
        return fd
    }

    private static func sync(_ fd: Int32) throws {
        var result: Int32
        repeat {
            result = Darwin.fsync(fd)
        } while result == -1 && errno == EINTR
        guard result == 0 else {
            let code = errno
            throw PrivateDirectoryFailure(code: .sync, errno: code)
        }
    }
}
