import Darwin
import Foundation

package struct CodexExecConfiguration: Equatable, Sendable {
    package let executableURL: URL
    package let codexHomeURL: URL
    package let outputURL: URL
    package let timeout: Duration
    package let terminateExitTimeout: Duration
}

package struct CodexExecFailure: Error, Equatable, Sendable {
    package enum Code: Equatable, Sendable {
        case alreadyUsed
        case invalidConfiguration
        case launchFailed
        case abnormalExit
        case timeout
        case cancelled
        case childExitUnconfirmed
    }

    package enum ChildDisposition: Equatable, Sendable {
        case notStarted
        case confirmedExited
        case unconfirmed
    }

    package let code: Code
    package let childDisposition: ChildDisposition
    package let exitCode: Int32?
    package let childPID: Int32?
}

package actor CodexExecSession {
    private let configuration: CodexExecConfiguration
    private let didLaunch: @Sendable (Int32) throws -> Void
    private var used = false
    private var finished = false
    private var process: Process?
    private var pendingFailureCode: CodexExecFailure.Code?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    package init(
        configuration: CodexExecConfiguration,
        didLaunch: @escaping @Sendable (Int32) throws -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.didLaunch = didLaunch
    }

    package func run() async throws {
        guard !used else {
            throw failure(.alreadyUsed, disposition: .notStarted)
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

    package func cancel() {
        requestTermination(.cancelled)
    }
}

private extension CodexExecSession {
    func start() {
        guard validateConfiguration() else {
            finish(.failure(failure(.invalidConfiguration, disposition: .notStarted)))
            return
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.currentDirectoryURL = configuration.codexHomeURL
        process.arguments = [
            "--config",
            "cli_auth_credentials_store=\"file\"",
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--output-last-message",
            configuration.outputURL.path,
            "Respond with exactly OK. Do not use tools.",
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
            try didLaunch(process.processIdentifier)
            scheduleTimeout()
        } catch {
            if process.isRunning {
                requestTermination(.launchFailed)
            } else {
                finish(.failure(failure(.launchFailed, disposition: .notStarted)))
            }
        }
    }

    func childTerminated(status: Int32) {
        guard !finished else { return }
        if let code = pendingFailureCode ?? (status == 0 ? nil : .abnormalExit) {
            finish(.failure(failure(code, disposition: .confirmedExited, exitCode: status)))
        } else {
            finish(.success(()))
        }
    }

    func scheduleTimeout() {
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.configuration.timeout)
            } catch {
                return
            }
            await self.requestTermination(.timeout)
        }
    }

    func requestTermination(_ code: CodexExecFailure.Code) {
        guard !finished, pendingFailureCode == nil else { return }
        pendingFailureCode = code
        timeoutTask?.cancel()
        guard let process, process.isRunning else { return }
        process.terminate()
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: configuration.terminateExitTimeout)
            } catch {
                return
            }
            await self.terminationGraceExpired()
        }
    }

    func terminationGraceExpired() {
        guard !finished else { return }
        finish(.failure(failure(.childExitUnconfirmed, disposition: .unconfirmed)))
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

    func failure(
        _ code: CodexExecFailure.Code,
        disposition: CodexExecFailure.ChildDisposition,
        exitCode: Int32? = nil
    ) -> CodexExecFailure {
        CodexExecFailure(
            code: code,
            childDisposition: disposition,
            exitCode: exitCode,
            childPID: process?.processIdentifier
        )
    }

    func validateConfiguration() -> Bool {
        guard configuration.executableURL.isFileURL,
              configuration.executableURL.path.hasPrefix("/"),
              configuration.codexHomeURL.isFileURL,
              configuration.codexHomeURL.path.hasPrefix("/"),
              configuration.outputURL.deletingLastPathComponent() == configuration.codexHomeURL,
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
