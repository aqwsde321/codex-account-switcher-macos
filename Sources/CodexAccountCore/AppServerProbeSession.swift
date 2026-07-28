import Darwin
import Foundation

public struct AppServerProbeTimeouts: Sendable, Equatable {
    public let initializeResponse: Duration
    public let accountResponse: Duration
    public let normalExit: Duration
    public let terminateExit: Duration

    public init(
        initializeResponse: Duration,
        accountResponse: Duration,
        normalExit: Duration,
        terminateExit: Duration
    ) {
        self.initializeResponse = initializeResponse
        self.accountResponse = accountResponse
        self.normalExit = normalExit
        self.terminateExit = terminateExit
    }
}

public struct AppServerProbeConfiguration: Sendable, Equatable {
    public let executableURL: URL
    public let codexHomeURL: URL
    public let refreshToken: Bool
    public let timeouts: AppServerProbeTimeouts

    public init(
        executableURL: URL,
        codexHomeURL: URL,
        refreshToken: Bool,
        timeouts: AppServerProbeTimeouts
    ) {
        self.executableURL = executableURL
        self.codexHomeURL = codexHomeURL
        self.refreshToken = refreshToken
        self.timeouts = timeouts
    }
}

public enum AppServerProbeStage: Sendable, Equatable {
    case launching
    case initializing
    case readingAccount
    case awaitingNormalExit
    case terminating
}

public struct AppServerProbeFailure: Error, Sendable, Equatable {
    public enum Code: Sendable, Equatable {
        case alreadyUsed
        case invalidConfiguration
        case launchFailed
        case transportFailed
        case malformedFrame
        case protocolViolation
        case rpcError
        case unexpectedEOF
        case timeout
        case unsupportedAccountType
        case abnormalExit
        case childExitUnconfirmed
        case cancelled
    }

    public enum ChildDisposition: Sendable, Equatable {
        case notStarted
        case confirmedExited
        case unconfirmed
    }

    public let code: Code
    public let stage: AppServerProbeStage
    public let childDisposition: ChildDisposition
    public let rpcCode: Int?
    public let exitCode: Int32?
    public let childPID: Int32?

    public init(
        code: Code,
        stage: AppServerProbeStage,
        childDisposition: ChildDisposition,
        rpcCode: Int? = nil,
        exitCode: Int32? = nil,
        childPID: Int32? = nil
    ) {
        self.code = code
        self.stage = stage
        self.childDisposition = childDisposition
        self.rpcCode = rpcCode
        self.exitCode = exitCode
        self.childPID = childPID
    }
}

public actor AppServerProbeSession {
    private let configuration: AppServerProbeConfiguration

    private var used = false
    private var finished = false
    private var stage = AppServerProbeStage.launching
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var standardInputClosed = false
    private var standardOutputEOF = false
    private var standardErrorEOF = false
    private var exitCode: Int32?
    private var machine = AppServerProtocolMachine()
    private var account: AppServerAccountRead?
    private var pendingFailure: AppServerProbeFailure?
    private var continuation: CheckedContinuation<AppServerAccountRead, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init(configuration: AppServerProbeConfiguration) {
        self.configuration = configuration
    }

    public func run() async throws -> AppServerAccountRead {
        guard !used else {
            throw AppServerProbeFailure(
                code: .alreadyUsed,
                stage: .launching,
                childDisposition: .notStarted
            )
        }
        used = true

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.start()
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
}

private extension AppServerProbeSession {
    func start() {
        guard validateConfiguration() else {
            finish(
                .failure(
                    AppServerProbeFailure(
                        code: .invalidConfiguration,
                        stage: .launching,
                        childDisposition: .notStarted
                    )
                )
            )
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.currentDirectoryURL = configuration.codexHomeURL
        process.arguments = [
            "--config",
            "cli_auth_credentials_store=\"file\"",
            "app-server",
            "--stdio",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment["CODEX_HOME"] = configuration.codexHomeURL.path
        environment["CODEX_SQLITE_HOME"] = configuration.codexHomeURL.path
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputPipe.fileHandleForReading
        standardError = errorPipe.fileHandleForReading
        self.process = process

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveStandardOutput(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveStandardError(data) }
        }
        process.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { await self?.childTerminated(status: status) }
        }

        do {
            try process.run()
            stage = .initializing
            scheduleTimeout(configuration.timeouts.initializeResponse, expectedStage: .initializing)
            let initial = try machine.start(refreshToken: configuration.refreshToken)
            try write(initial)
        } catch let failure as AppServerProbeFailure {
            beginFailure(failure)
        } catch {
            finish(
                .failure(
                    AppServerProbeFailure(
                        code: .launchFailed,
                        stage: .launching,
                        childDisposition: process.isRunning ? .unconfirmed : .notStarted,
                        childPID: process.isRunning ? process.processIdentifier : nil
                    )
                )
            )
        }
    }

    func validateConfiguration() -> Bool {
        guard configuration.executableURL.isFileURL,
              configuration.executableURL.path.hasPrefix("/"),
              configuration.codexHomeURL.isFileURL,
              configuration.codexHomeURL.path.hasPrefix("/") else {
            return false
        }
        guard let executable = pathInformation(configuration.executableURL.path),
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

    func receiveStandardOutput(_ data: Data) {
        guard !finished else { return }
        if data.isEmpty {
            standardOutputEOF = true
            standardOutput?.readabilityHandler = nil
            do {
                try machine.validateEndOfFile()
            } catch {
                if account == nil {
                    beginFailure(protocolFailure(error, stage: stage))
                }
            }
            tryFinish()
            return
        }

        do {
            let outbound = try machine.receive(data)
            if outbound.count == 2, stage == .initializing {
                stage = .readingAccount
                scheduleTimeout(configuration.timeouts.accountResponse, expectedStage: .readingAccount)
            }
            try write(outbound)
            if machine.readyToCloseStandardInput, account == nil {
                account = machine.account
                stage = .awaitingNormalExit
                closeStandardInput()
                scheduleTimeout(configuration.timeouts.normalExit, expectedStage: .awaitingNormalExit)
            }
        } catch {
            beginFailure(protocolFailure(error, stage: stage))
        }
        tryFinish()
    }

    func receiveStandardError(_ data: Data) {
        guard !finished else { return }
        if data.isEmpty {
            standardErrorEOF = true
            standardError?.readabilityHandler = nil
            tryFinish()
        }
    }

    func childTerminated(status: Int32) {
        guard !finished else { return }
        exitCode = status
        if status != 0, pendingFailure == nil {
            pendingFailure = AppServerProbeFailure(
                code: .abnormalExit,
                stage: stage,
                childDisposition: .confirmedExited,
                exitCode: status,
                childPID: process?.processIdentifier
            )
        } else if account == nil, pendingFailure == nil {
            pendingFailure = AppServerProbeFailure(
                code: .unexpectedEOF,
                stage: stage,
                childDisposition: .confirmedExited,
                exitCode: status,
                childPID: process?.processIdentifier
            )
        }
        tryFinish()
        if !finished && (!standardOutputEOF || !standardErrorEOF) {
            schedulePipeEOFTimeout(configuration.timeouts.terminateExit)
        }
    }

    func write(_ messages: [Data]) throws {
        guard let standardInput, !standardInputClosed else {
            throw AppServerProbeFailure(
                code: .transportFailed,
                stage: stage,
                childDisposition: process?.isRunning == true ? .unconfirmed : .confirmedExited,
                childPID: process?.processIdentifier
            )
        }
        do {
            for message in messages {
                try standardInput.write(contentsOf: message)
            }
        } catch {
            throw AppServerProbeFailure(
                code: .transportFailed,
                stage: stage,
                childDisposition: process?.isRunning == true ? .unconfirmed : .confirmedExited,
                childPID: process?.processIdentifier
            )
        }
    }

    func beginFailure(_ failure: AppServerProbeFailure) {
        guard !finished, pendingFailure == nil else { return }
        pendingFailure = failure
        timeoutTask?.cancel()
        closeStandardInput()
        if exitCode != nil {
            tryFinish()
            if !finished {
                schedulePipeEOFTimeout(configuration.timeouts.terminateExit)
            }
        } else {
            scheduleCleanupTimeout(configuration.timeouts.normalExit)
        }
    }

    func tryFinish() {
        guard !finished else { return }

        if let failure = pendingFailure {
            guard exitCode != nil, standardOutputEOF, standardErrorEOF else { return }
            finish(
                .failure(
                    AppServerProbeFailure(
                        code: failure.code,
                        stage: failure.stage,
                        childDisposition: .confirmedExited,
                        rpcCode: failure.rpcCode,
                        exitCode: exitCode,
                        childPID: process?.processIdentifier
                    )
                )
            )
            return
        }

        guard let account,
              exitCode == 0,
              standardOutputEOF,
              standardErrorEOF else {
            return
        }
        do {
            try machine.validateEndOfFile()
            finish(.success(account))
        } catch {
            finish(.failure(protocolFailure(error, stage: stage)))
        }
    }

    func scheduleTimeout(_ duration: Duration, expectedStage: AppServerProbeStage) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            await self?.stageTimedOut(expectedStage)
        }
    }

    func scheduleCleanupTimeout(_ duration: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            await self?.cleanupGraceExpired()
        }
    }

    func schedulePipeEOFTimeout(_ duration: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            await self?.pipeEOFGraceExpired()
        }
    }

    func stageTimedOut(_ expectedStage: AppServerProbeStage) {
        guard !finished, stage == expectedStage else { return }
        beginFailure(
            AppServerProbeFailure(
                code: .timeout,
                stage: stage,
                childDisposition: process?.isRunning == true ? .unconfirmed : .confirmedExited,
                childPID: process?.processIdentifier
            )
        )
    }

    func cleanupGraceExpired() {
        guard !finished, exitCode == nil else {
            tryFinish()
            if !finished {
                schedulePipeEOFTimeout(configuration.timeouts.terminateExit)
            }
            return
        }
        guard let process, process.isRunning else {
            tryFinish()
            return
        }
        process.terminate()
        stage = .terminating
        timeoutTask?.cancel()
        let terminateExit = configuration.timeouts.terminateExit
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: terminateExit)
            } catch {
                return
            }
            await self.terminateGraceExpired()
        }
    }

    func pipeEOFGraceExpired() {
        guard !finished else { return }
        if standardOutputEOF, standardErrorEOF {
            tryFinish()
            return
        }
        finish(
            .failure(
                AppServerProbeFailure(
                    code: .childExitUnconfirmed,
                    stage: stage,
                    childDisposition: .unconfirmed,
                    exitCode: exitCode,
                    childPID: process?.processIdentifier
                )
            )
        )
    }

    func terminateGraceExpired() {
        guard !finished, exitCode == nil else {
            tryFinish()
            return
        }
        finish(
            .failure(
                AppServerProbeFailure(
                    code: .childExitUnconfirmed,
                    stage: .terminating,
                    childDisposition: .unconfirmed,
                    childPID: process?.processIdentifier
                )
            )
        )
    }

    func cancel() {
        beginFailure(
            AppServerProbeFailure(
                code: .cancelled,
                stage: stage,
                childDisposition: process?.isRunning == true ? .unconfirmed : .confirmedExited,
                childPID: process?.processIdentifier
            )
        )
    }

    func closeStandardInput() {
        guard !standardInputClosed else { return }
        standardInputClosed = true
        try? standardInput?.close()
    }

    func finish(_ result: Result<AppServerAccountRead, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        process?.terminationHandler = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func protocolFailure(_ error: Error, stage: AppServerProbeStage) -> AppServerProbeFailure {
        guard let failure = error as? AppServerProtocolFailure else {
            return AppServerProbeFailure(
                code: .protocolViolation,
                stage: stage,
                childDisposition: process?.isRunning == true ? .unconfirmed : .confirmedExited,
                childPID: process?.processIdentifier
            )
        }
        let code: AppServerProbeFailure.Code
        switch failure.code {
        case .malformedFrame, .frameTooLarge:
            code = .malformedFrame
        case .rpcError:
            code = .rpcError
        case .unexpectedEOF:
            code = .unexpectedEOF
        case .unsupportedAccountType:
            code = .unsupportedAccountType
        case .alreadyStarted, .protocolViolation:
            code = .protocolViolation
        }
        return AppServerProbeFailure(
            code: code,
            stage: stage,
            childDisposition: process?.isRunning == true ? .unconfirmed : .confirmedExited,
            rpcCode: failure.rpcCode,
            exitCode: exitCode,
            childPID: process?.processIdentifier
        )
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
