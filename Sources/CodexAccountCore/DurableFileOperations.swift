import CryptoKit
import Darwin
import Foundation

public struct SensitiveBytes: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    let data: Data

    public let byteCount: Int

    public init(_ data: Data) {
        self.data = data
        byteCount = data.count
    }

    public var description: String { "<redacted bytes>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(reflecting: description) }
}

public struct SHA256Digest: Equatable, Hashable, Sendable, CustomStringConvertible {
    private let bytes: [UInt8]

    fileprivate init<D: Sequence>(_ bytes: D) where D.Element == UInt8 {
        self.bytes = Array(bytes)
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct FileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let sha256: SHA256Digest
}

public enum ExpectedDestination: Equatable, Sendable {
    case absent
    case exact(FileIdentity)
}

public enum DurableRemoval: Equatable, Sendable {
    case removed
    case alreadyAbsent
}

public enum DurableMutation: Equatable, Sendable {
    case inspect
    case replace
    case remove
}

public enum DurableStage: Equatable, Sendable {
    case validatePath
    case openParent
    case inspect
    case createTemporary
    case setMode
    case write
    case syncFile
    case rename
    case unlink
    case syncParent
}

public enum MutationCertainty: Equatable, Sendable {
    case destinationUnchanged
    case mutationOutcomeUnknown
    case durabilityUnknown
}

public struct DurableFileFailure: Error, Equatable, Sendable {
    public let mutation: DurableMutation
    public let stage: DurableStage
    public let errno: Int32
    public let certainty: MutationCertainty

    public init(
        mutation: DurableMutation,
        stage: DurableStage,
        errno: Int32,
        certainty: MutationCertainty
    ) {
        self.mutation = mutation
        self.stage = stage
        self.errno = errno
        self.certainty = certainty
    }
}

package struct DurableFaultInjection: Sendable {
    package let mutation: DurableMutation
    package let stage: DurableStage
    package let errno: Int32

    package init(mutation: DurableMutation, stage: DurableStage, errno: Int32 = EIO) {
        self.mutation = mutation
        self.stage = stage
        self.errno = errno
    }
}

public struct DarwinDurableFileOperations {
    private let fault: DurableFaultInjection?

    public init() {
        fault = nil
    }

    package init(fault: DurableFaultInjection) {
        self.fault = fault
    }

    public func snapshot(at url: URL) throws -> ExpectedDestination {
        let target = try validatedTarget(url, mutation: .inspect)
        let parentFD = try openParent(target.parentPath, mutation: .inspect)
        defer { Darwin.close(parentFD) }
        return try observe(parentFD: parentFD, name: target.name, mutation: .inspect)
    }

    public func read(
        at url: URL,
        maximumBytes: Int = 1_048_576
    ) throws -> (contents: SensitiveBytes, identity: FileIdentity) {
        guard maximumBytes >= 0 else {
            throw failure(.inspect, .validatePath, EINVAL, .destinationUnchanged)
        }
        let target = try validatedTarget(url, mutation: .inspect)
        let parentFD = try openParent(target.parentPath, mutation: .inspect)
        defer { Darwin.close(parentFD) }

        let result = try observeWithContents(
            parentFD: parentFD,
            name: target.name,
            mutation: .inspect,
            captureContents: true,
            maximumCapturedBytes: maximumBytes
        )
        guard case let .exact(identity) = result.destination, let data = result.data else {
            throw failure(.inspect, .inspect, ENOENT, .destinationUnchanged)
        }
        return (SensitiveBytes(data), identity)
    }

    public func replace(
        contents: SensitiveBytes,
        at url: URL,
        expecting expected: ExpectedDestination
    ) throws -> FileIdentity {
        let expectedDigest = SHA256Digest(SHA256.hash(data: contents.data))
        let target = try validatedTarget(url, mutation: .replace)
        let parentFD = try openParent(target.parentPath, mutation: .replace)
        defer { Darwin.close(parentFD) }

        let initial = try observe(parentFD: parentFD, name: target.name, mutation: .replace)
        guard initial == expected else {
            throw failure(.replace, .inspect, ESTALE, .destinationUnchanged)
        }

        let temporaryName = ".codex-account-switcher-\(UUID().uuidString).tmp"
        try injectIfNeeded(.replace, .createTemporary, .destinationUnchanged)
        let temporaryFD = try createTemporary(
            parentFD: parentFD,
            name: temporaryName,
            mutation: .replace
        )
        var renamed = false
        defer {
            Darwin.close(temporaryFD)
            if !renamed {
                _ = temporaryName.withCString { Darwin.unlinkat(parentFD, $0, 0) }
            }
        }

        try injectIfNeeded(.replace, .setMode, .destinationUnchanged)
        try setPrivateMode(fd: temporaryFD, mutation: .replace)
        try injectIfNeeded(.replace, .write, .destinationUnchanged)
        try writeAll(contents, fd: temporaryFD)
        try injectIfNeeded(.replace, .syncFile, .destinationUnchanged)
        try sync(fd: temporaryFD, mutation: .replace, stage: .syncFile, certainty: .destinationUnchanged)

        let beforeRename = try observe(parentFD: parentFD, name: target.name, mutation: .replace)
        guard beforeRename == expected else {
            throw failure(.replace, .inspect, ESTALE, .destinationUnchanged)
        }

        try injectIfNeeded(.replace, .rename, .mutationOutcomeUnknown)
        let renameResult = temporaryName.withCString { source in
            target.name.withCString { destination in
                Darwin.renameat(parentFD, source, parentFD, destination)
            }
        }
        guard renameResult == 0 else {
            let code = errno
            throw failure(.replace, .rename, code, .mutationOutcomeUnknown)
        }
        renamed = true

        try injectIfNeeded(.replace, .syncParent, .durabilityUnknown)
        try sync(fd: parentFD, mutation: .replace, stage: .syncParent, certainty: .durabilityUnknown)

        guard case let .exact(identity) = try observe(
            parentFD: parentFD,
            name: target.name,
            mutation: .replace,
            certainty: .mutationOutcomeUnknown
        ), identity.size == UInt64(contents.byteCount), identity.sha256 == expectedDigest else {
            throw failure(.replace, .inspect, EIO, .mutationOutcomeUnknown)
        }
        return identity
    }

    public func remove(
        at url: URL,
        expecting expected: ExpectedDestination
    ) throws -> DurableRemoval {
        let target = try validatedTarget(url, mutation: .remove)
        let parentFD = try openParent(target.parentPath, mutation: .remove)
        defer { Darwin.close(parentFD) }

        let observed = try observe(parentFD: parentFD, name: target.name, mutation: .remove)
        guard observed == expected else {
            throw failure(.remove, .inspect, ESTALE, .destinationUnchanged)
        }

        if observed == .absent {
            try sync(fd: parentFD, mutation: .remove, stage: .syncParent, certainty: .durabilityUnknown)
            return .alreadyAbsent
        }

        try injectIfNeeded(.remove, .unlink, .mutationOutcomeUnknown)
        let result = target.name.withCString { Darwin.unlinkat(parentFD, $0, 0) }
        guard result == 0 else {
            let code = errno
            throw failure(.remove, .unlink, code, .mutationOutcomeUnknown)
        }

        try injectIfNeeded(.remove, .syncParent, .durabilityUnknown)
        try sync(fd: parentFD, mutation: .remove, stage: .syncParent, certainty: .durabilityUnknown)
        return .removed
    }
}

private extension DarwinDurableFileOperations {
    typealias ValidatedTarget = (parentPath: String, name: String)

    func validatedTarget(_ url: URL, mutation: DurableMutation) throws -> ValidatedTarget {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".." else {
            throw failure(mutation, .validatePath, EINVAL, .destinationUnchanged)
        }
        return (url.deletingLastPathComponent().path, url.lastPathComponent)
    }

    func openParent(_ path: String, mutation: DurableMutation) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd: Int32
        repeat {
            fd = path.withCString { Darwin.open($0, flags) }
        } while fd == -1 && errno == EINTR
        guard fd >= 0 else {
            let code = errno
            throw failure(mutation, .openParent, code, .destinationUnchanged)
        }

        do {
            let information = try fileStat(fd: fd, mutation: mutation, stage: .openParent)
            let permissions = permissionBits(information)
            guard isDirectory(information),
                  information.st_uid == getuid(),
                  permissions & mode_t(0o022) == 0,
                  permissions & mode_t(0o700) == mode_t(0o700) else {
                throw failure(mutation, .openParent, EPERM, .destinationUnchanged)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func observe(
        parentFD: Int32,
        name: String,
        mutation: DurableMutation,
        certainty: MutationCertainty = .destinationUnchanged
    ) throws -> ExpectedDestination {
        try observeWithContents(
            parentFD: parentFD,
            name: name,
            mutation: mutation,
            certainty: certainty,
            captureContents: false
        ).destination
    }

    func observeWithContents(
        parentFD: Int32,
        name: String,
        mutation: DurableMutation,
        certainty: MutationCertainty = .destinationUnchanged,
        captureContents: Bool,
        maximumCapturedBytes: Int? = nil
    ) throws -> (destination: ExpectedDestination, data: Data?) {
        var pathInformation = stat()
        var statResult: Int32
        repeat {
            statResult = name.withCString {
                Darwin.fstatat(parentFD, $0, &pathInformation, AT_SYMLINK_NOFOLLOW)
            }
        } while statResult == -1 && errno == EINTR

        if statResult == -1 && errno == ENOENT {
            return (.absent, nil)
        }
        guard statResult == 0 else {
            let code = errno
            throw failure(mutation, .inspect, code, certainty)
        }
        guard isRegularFile(pathInformation),
              pathInformation.st_uid == getuid(),
              permissionBits(pathInformation) == 0o600 else {
            throw failure(mutation, .inspect, EPERM, certainty)
        }

        let fd = try openExisting(parentFD: parentFD, name: name, mutation: mutation, certainty: certainty)
        defer { Darwin.close(fd) }
        let before = try fileStat(fd: fd, mutation: mutation, stage: .inspect, certainty: certainty)
        guard isRegularFile(before),
              before.st_uid == getuid(),
              permissionBits(before) == 0o600,
              sameNode(before, pathInformation) else {
            throw failure(mutation, .inspect, ESTALE, certainty)
        }
        if let maximumCapturedBytes {
            guard before.st_size >= 0,
                  UInt64(before.st_size) <= UInt64(maximumCapturedBytes) else {
                throw failure(mutation, .inspect, EFBIG, certainty)
            }
        }

        var hasher = SHA256()
        var capturedData = captureContents ? Data() : nil
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                hasher.update(data: chunk)
                if let maximumCapturedBytes,
                   count > maximumCapturedBytes - (capturedData?.count ?? 0) {
                    throw failure(mutation, .inspect, EFBIG, certainty)
                }
                capturedData?.append(chunk)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                let code = errno
                throw failure(mutation, .inspect, code, certainty)
            }
        }

        let after = try fileStat(fd: fd, mutation: mutation, stage: .inspect, certainty: certainty)
        guard stableMetadata(before, after) else {
            throw failure(mutation, .inspect, ESTALE, certainty)
        }

        let identity = identity(from: after, digest: SHA256Digest(hasher.finalize()))
        return (.exact(identity), capturedData)
    }

    func openExisting(
        parentFD: Int32,
        name: String,
        mutation: DurableMutation,
        certainty: MutationCertainty
    ) throws -> Int32 {
        var fd: Int32
        repeat {
            fd = name.withCString {
                Darwin.openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
        } while fd == -1 && errno == EINTR
        guard fd >= 0 else {
            let code = errno
            throw failure(mutation, .inspect, code, certainty)
        }
        return fd
    }

    func createTemporary(parentFD: Int32, name: String, mutation: DurableMutation) throws -> Int32 {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var fd: Int32
        repeat {
            fd = name.withCString { Darwin.openat(parentFD, $0, flags, mode_t(0o600)) }
        } while fd == -1 && errno == EINTR
        guard fd >= 0 else {
            let code = errno
            throw failure(mutation, .createTemporary, code, .destinationUnchanged)
        }
        return fd
    }

    func setPrivateMode(fd: Int32, mutation: DurableMutation) throws {
        var result: Int32
        repeat {
            result = Darwin.fchmod(fd, mode_t(0o600))
        } while result == -1 && errno == EINTR
        guard result == 0 else {
            let code = errno
            throw failure(mutation, .setMode, code, .destinationUnchanged)
        }
    }

    func writeAll(_ contents: SensitiveBytes, fd: Int32) throws {
        try contents.data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    fd,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    let code = written == 0 ? EIO : errno
                    throw failure(.replace, .write, code, .destinationUnchanged)
                }
            }
        }
    }

    func sync(
        fd: Int32,
        mutation: DurableMutation,
        stage: DurableStage,
        certainty: MutationCertainty
    ) throws {
        var result: Int32
        repeat {
            result = Darwin.fsync(fd)
        } while result == -1 && errno == EINTR
        guard result == 0 else {
            let code = errno
            throw failure(mutation, stage, code, certainty)
        }
    }

    func fileStat(
        fd: Int32,
        mutation: DurableMutation,
        stage: DurableStage,
        certainty: MutationCertainty = .destinationUnchanged
    ) throws -> stat {
        var information = stat()
        var result: Int32
        repeat {
            result = Darwin.fstat(fd, &information)
        } while result == -1 && errno == EINTR
        guard result == 0 else {
            let code = errno
            throw failure(mutation, stage, code, certainty)
        }
        return information
    }

    func identity(from information: stat, digest: SHA256Digest) -> FileIdentity {
        FileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: UInt64(information.st_size),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            sha256: digest
        )
    }

    func stableMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        sameNode(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    func sameNode(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    func isDirectory(_ information: stat) -> Bool {
        information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    func isRegularFile(_ information: stat) -> Bool {
        information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    func permissionBits(_ information: stat) -> mode_t {
        information.st_mode & mode_t(0o777)
    }

    func failure(
        _ mutation: DurableMutation,
        _ stage: DurableStage,
        _ code: Int32,
        _ certainty: MutationCertainty
    ) -> DurableFileFailure {
        DurableFileFailure(mutation: mutation, stage: stage, errno: code, certainty: certainty)
    }

    func injectIfNeeded(
        _ mutation: DurableMutation,
        _ stage: DurableStage,
        _ certainty: MutationCertainty
    ) throws {
        guard let fault, fault.mutation == mutation, fault.stage == stage else { return }
        throw failure(mutation, stage, fault.errno, certainty)
    }
}
