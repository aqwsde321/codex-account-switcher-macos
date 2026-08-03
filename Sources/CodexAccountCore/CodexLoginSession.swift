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
    private var used = false
    private var finished = false
    private var process: Process?
    private var pendingFailureCode: CodexLoginFailure.Code?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init(
        configuration: CodexLoginConfiguration,
        didLaunch: @escaping @Sendable (Int32) throws -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.didLaunch = didLaunch
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
        guard validateConfiguration() else {
            finish(.failure(CodexLoginFailure(code: .invalidConfiguration, childDisposition: .notStarted)))
            return
        }

        let process = Process()
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
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { await self?.childTerminated(status: status) }
        }
        self.process = process

        do {
            try process.run()
        } catch {
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
