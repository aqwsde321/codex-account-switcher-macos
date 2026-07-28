import Darwin
import Foundation

@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public enum LockFailureCode: Equatable, Sendable {
    case invalidPath
    case openParent
    case unsafeParent
    case openLock
    case unsafeLock
    case identityChanged
    case acquire
}

public struct LockFailure: Error, Equatable, Sendable {
    public let code: LockFailureCode
    public let errno: Int32

    public init(code: LockFailureCode, errno: Int32) {
        self.code = code
        self.errno = errno
    }
}

public final class ExclusiveFileLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public var closeOnExecConfigured: Bool {
        guard descriptor >= 0 else { return false }
        return Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0
    }

    public static func tryAcquire(at url: URL) throws -> ExclusiveFileLock? {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".." else {
            throw LockFailure(code: .invalidPath, errno: EINVAL)
        }

        let parentPath = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        let parentFD = try openPrivateDirectory(parentPath)
        defer { Darwin.close(parentFD) }

        let lockFD = try openLock(parentFD: parentFD, name: name)
        var retained = false
        defer {
            if !retained {
                Darwin.close(lockFD)
            }
        }

        let descriptorInfo = try lockStat(fd: lockFD, code: .unsafeLock)
        guard descriptorInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              descriptorInfo.st_uid == getuid(),
              descriptorInfo.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw LockFailure(code: .unsafeLock, errno: EPERM)
        }

        var result: Int32
        repeat {
            result = systemFlock(lockFD, LOCK_EX | LOCK_NB)
        } while result == -1 && errno == EINTR
        if result == -1 && (errno == EWOULDBLOCK || errno == EAGAIN) {
            return nil
        }
        guard result == 0 else {
            let code = errno
            throw LockFailure(code: .acquire, errno: code)
        }

        var pathInfo = stat()
        var statResult: Int32
        repeat {
            statResult = name.withCString {
                Darwin.fstatat(parentFD, $0, &pathInfo, AT_SYMLINK_NOFOLLOW)
            }
        } while statResult == -1 && errno == EINTR
        guard statResult == 0,
              pathInfo.st_dev == descriptorInfo.st_dev,
              pathInfo.st_ino == descriptorInfo.st_ino else {
            throw LockFailure(code: .identityChanged, errno: ESTALE)
        }

        retained = true
        return ExclusiveFileLock(descriptor: lockFD)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

private extension ExclusiveFileLock {
    static func openPrivateDirectory(_ path: String) throws -> Int32 {
        var fd: Int32
        repeat {
            fd = path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        } while fd == -1 && errno == EINTR
        guard fd >= 0 else {
            let code = errno
            throw LockFailure(code: .openParent, errno: code)
        }

        do {
            let info = try lockStat(fd: fd, code: .unsafeParent)
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_uid == getuid(),
                  info.st_mode & mode_t(0o777) == mode_t(0o700) else {
                throw LockFailure(code: .unsafeParent, errno: EPERM)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func openLock(parentFD: Int32, name: String) throws -> Int32 {
        let createFlags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var fd: Int32
        repeat {
            fd = name.withCString { Darwin.openat(parentFD, $0, createFlags, mode_t(0o600)) }
        } while fd == -1 && errno == EINTR

        if fd >= 0 {
            var modeResult: Int32
            repeat {
                modeResult = Darwin.fchmod(fd, mode_t(0o600))
            } while modeResult == -1 && errno == EINTR
            guard modeResult == 0 else {
                let code = errno
                Darwin.close(fd)
                throw LockFailure(code: .unsafeLock, errno: code)
            }
            return fd
        }

        guard errno == EEXIST else {
            let code = errno
            throw LockFailure(code: .openLock, errno: code)
        }

        repeat {
            fd = name.withCString {
                Darwin.openat(parentFD, $0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            }
        } while fd == -1 && errno == EINTR
        guard fd >= 0 else {
            let code = errno
            throw LockFailure(code: .openLock, errno: code)
        }
        return fd
    }

    static func lockStat(fd: Int32, code: LockFailureCode) throws -> stat {
        var info = stat()
        var result: Int32
        repeat {
            result = Darwin.fstat(fd, &info)
        } while result == -1 && errno == EINTR
        guard result == 0 else {
            let systemCode = errno
            throw LockFailure(code: code, errno: systemCode)
        }
        return info
    }
}
