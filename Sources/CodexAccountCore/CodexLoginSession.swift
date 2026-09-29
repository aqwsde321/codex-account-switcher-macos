import Darwin
import Foundation

package func sanitizedCodexEnvironment(
    homeURL: URL,
    base: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var environment = base
    for key in Array(environment.keys)
        where key.hasPrefix("CODEX_") || key.hasPrefix("OPENAI_") {
        environment.removeValue(forKey: key)
    }
    environment["CODEX_HOME"] = homeURL.path
    environment["CODEX_SQLITE_HOME"] = homeURL.path
    return environment
}

public struct CodexLoginTimeouts: Equatable, Sendable {
    public let login: Duration
    public let terminateExit: Duration

    public init(login: Duration, terminateExit: Duration) {
        self.login = login
        self.terminateExit = terminateExit
    }
}

public struct CodexLoginConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let codexHomeURL: URL
    public let timeouts: CodexLoginTimeouts

    public init(
        executableURL: URL,
        codexHomeURL: URL,
        timeouts: CodexLoginTimeouts
    ) {
        self.executableURL = executableURL
        self.codexHomeURL = codexHomeURL
        self.timeouts = timeouts
    }
}

public struct CodexLoginFailure: Error, Equatable, Sendable {
    public enum Code: Equatable, Sendable {
        case alreadyUsed
        case invalidConfiguration
        case launchFailed
        case abnormalExit
        case timeout
        case cancelled
        case childExitUnconfirmed
    }

    public enum ChildDisposition: Equatable, Sendable {
        case notStarted
        case confirmedExited
        case unconfirmed
    }

    public let code: Code
    public let childDisposition: ChildDisposition
    public let exitCode: Int32?
    public let childPID: Int32?

    public init(
        code: Code,
        childDisposition: ChildDisposition,
        exitCode: Int32? = nil,
        childPID: Int32? = nil
    ) {
        self.code = code
        self.childDisposition = childDisposition
        self.exitCode = exitCode
        self.childPID = childPID
    }
}

public actor CodexLoginSession {
    private let configuration: CodexLoginConfiguration
    private let didLaunch: @Sendable (Int32) throws -> Void
    private let onAuthorizationURL: @Sendable (URL) async -> Void
    private var used = false
    private var finished = false
    private var process: Process?
    private var pendingFailureCode: CodexLoginFailure.Code?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var authorizationOutput: CodexLoginAuthorizationOutput?
    private var authorizationURLTask: Task<Void, Never>?

    public init(
        configuration: CodexLoginConfiguration,
        onAuthorizationURL: @escaping @Sendable (URL) async -> Void = { _ in },
        didLaunch: @escaping @Sendable (Int32) throws -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.didLaunch = didLaunch
        self.onAuthorizationURL = onAuthorizationURL
    }

    public func run() async throws {
        guard !used else {
            throw CodexLoginFailure(code: .alreadyUsed, childDisposition: .notStarted)
        }
        used = true

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                start()
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    public func cancel() {
        requestTermination(.cancelled)
    }
}

private extension CodexLoginSession {
    func start() {
        guard pendingFailureCode == nil, !Task.isCancelled else {
            finish(.failure(CodexLoginFailure(code: .cancelled, childDisposition: .notStarted)))
            return
        }
        guard validateConfiguration() else {
            finish(.failure(CodexLoginFailure(code: .invalidConfiguration, childDisposition: .notStarted)))
            return
        }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.currentDirectoryURL = configuration.codexHomeURL
        process.arguments = [
            "--config",
            "cli_auth_credentials_store=\"file\"",
            "login",
        ]
        process.environment = sanitizedCodexEnvironment(homeURL: configuration.codexHomeURL)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        authorizationOutput = CodexLoginAuthorizationOutput(handle: errorPipe.fileHandleForReading) {
            [weak self] url in
            Task { await self?.receiveAuthorizationURL(url) }
        }
        authorizationOutput?.start()
        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { await self?.childTerminated(status: status) }
        }
        self.process = process

        do {
            try process.run()
            try? errorPipe.fileHandleForWriting.close()
        } catch {
            try? errorPipe.fileHandleForWriting.close()
            if process.isRunning {
                requestTermination(.launchFailed)
                return
            }
            finish(
                .failure(
                    CodexLoginFailure(
                        code: .launchFailed,
                        childDisposition: .notStarted
                    )
                )
            )
            return
        }
        do {
            try didLaunch(process.processIdentifier)
            scheduleLoginTimeout()
        } catch {
            requestTermination(.launchFailed)
        }
    }

    func receiveAuthorizationURL(_ url: URL) {
        guard !finished, pendingFailureCode == nil, process?.isRunning == true,
              authorizationURLTask == nil else { return }
        let callback = onAuthorizationURL
        authorizationURLTask = Task {
            guard !Task.isCancelled else { return }
            await callback(url)
        }
    }

    func childTerminated(status: Int32) {
        guard !finished else { return }
        let code = pendingFailureCode ?? (status == 0 ? nil : .abnormalExit)
        if let code {
            finish(
                .failure(
                    CodexLoginFailure(
                        code: code,
                        childDisposition: .confirmedExited,
                        exitCode: status,
                        childPID: process?.processIdentifier
                    )
                )
            )
        } else {
            finish(.success(()))
        }
    }

    func scheduleLoginTimeout() {
        timeoutTask?.cancel()
        let loginTimeout = configuration.timeouts.login
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: loginTimeout)
            } catch {
                return
            }
            await self?.requestTermination(.timeout)
        }
    }

    func requestTermination(_ code: CodexLoginFailure.Code) {
        guard !finished, pendingFailureCode == nil else { return }
        pendingFailureCode = code
        authorizationURLTask?.cancel()
        timeoutTask?.cancel()
        guard let process, process.isRunning else { return }
        process.terminate()
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: configuration.timeouts.terminateExit)
            } catch {
                return
            }
            await self.terminationGraceExpired()
        }
    }

    func terminationGraceExpired() {
        guard !finished else { return }
        finish(
            .failure(
                CodexLoginFailure(
                    code: .childExitUnconfirmed,
                    childDisposition: .unconfirmed,
                    childPID: process?.processIdentifier
                )
            )
        )
    }

    func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        process?.terminationHandler = nil
        authorizationURLTask?.cancel()
        authorizationURLTask = nil
        authorizationOutput?.stop()
        authorizationOutput = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func validateConfiguration() -> Bool {
        guard configuration.executableURL.isFileURL,
              configuration.executableURL.path.hasPrefix("/"),
              configuration.codexHomeURL.isFileURL,
              configuration.codexHomeURL.path.hasPrefix("/"),
              let executable = pathInformation(configuration.executableURL.path),
              executable.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              executable.st_mode & mode_t(0o111) != 0,
              let home = pathInformation(configuration.codexHomeURL.path),
              home.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              home.st_uid == getuid(),
              home.st_mode & mode_t(0o777) == mode_t(0o700) else {
            return false
        }
        return true
    }

    func pathInformation(_ path: String) -> stat? {
        var information = stat()
        var result: Int32
        repeat {
            result = path.withCString { Darwin.lstat($0, &information) }
        } while result == -1 && errno == EINTR
        return result == 0 ? information : nil
    }
}

// Only a complete URL on its own output line can be offered to the UI. The login
// URL contains transient OAuth state, so neither this buffer nor rejected output
// is included in errors, logs, or persistent storage.
package struct CodexLoginAuthorizationURLParser {
    private static let maximumLineBytes = 8_192
    private var line = [UInt8]()
    private var discardingLine = false
    private var emitted = false

    package init() {}

    package mutating func consume(_ data: Data) -> URL? {
        guard !emitted else { return nil }
        for byte in data {
            if byte == 10 {
                if !discardingLine, let url = Self.authorizationURL(in: line) {
                    emitted = true
                    line.removeAll(keepingCapacity: false)
                    return url
                }
                line.removeAll(keepingCapacity: true)
                discardingLine = false
            } else if !discardingLine {
                if line.count == Self.maximumLineBytes {
                    line.removeAll(keepingCapacity: true)
                    discardingLine = true
                } else {
                    line.append(byte)
                }
            }
        }
        return nil
    }

    private static func authorizationURL(in bytes: [UInt8]) -> URL? {
        guard let line = String(bytes: bytes, encoding: .utf8) else { return nil }
        let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              let components = URLComponents(string: candidate),
              components.scheme == "https", components.host == "auth.openai.com",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.percentEncodedPath == "/oauth/authorize", components.fragment == nil,
              let items = components.queryItems else { return nil }
        var query = [String: String]()
        for item in items {
            guard query[item.name] == nil, let value = item.value,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            query[item.name] = value
        }
        guard query["response_type"] == "code", query["code_challenge_method"] == "S256",
              let clientID = query["client_id"], !clientID.isEmpty,
              let challenge = query["code_challenge"], !challenge.isEmpty,
              let state = query["state"], !state.isEmpty,
              let scope = query["scope"], scope.split(separator: " ").contains("openid"),
              let redirect = query["redirect_uri"],
              let callback = URLComponents(string: redirect),
              callback.scheme == "http", callback.host == "localhost",
              let port = callback.port, (1...65_535).contains(port),
              callback.user == nil, callback.password == nil,
              callback.percentEncodedPath == "/auth/callback",
              callback.query == nil, callback.fragment == nil else { return nil }
        return components.url
    }
}

// Parse on the pipe callback rather than queuing every output chunk onto the
// session actor. Even a noisy child can retain only one bounded line and enqueue
// at most one URL notification. Reads never wait for a child to close its pipe.
private final class CodexLoginAuthorizationOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let onURL: @Sendable (URL) -> Void
    private var parser = CodexLoginAuthorizationURLParser()
    private var stopped = false

    init(handle: FileHandle, onURL: @escaping @Sendable (URL) -> Void) {
        self.handle = handle
        self.onURL = onURL
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        if flags != -1 { _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    func start() {
        handle.readabilityHandler = { [weak self] _ in self?.readAvailableBytes() }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopWhileLocked()
    }

    private func stopWhileLocked() {
        guard !stopped else { return }
        stopped = true
        handle.readabilityHandler = nil
        try? handle.close()
        parser = CodexLoginAuthorizationURLParser()
    }

    private func readAvailableBytes() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        let url: URL?
        if count > 0 {
            url = parser.consume(Data(bytes.prefix(count)))
        } else {
            url = nil
            if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                stopWhileLocked()
            }
        }
        lock.unlock()
        if let url { onURL(url) }
    }
}
