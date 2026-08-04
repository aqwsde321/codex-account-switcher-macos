import Foundation
import CodexAccountCore

func appServerProtocolTests() -> [TestCase] {
    [
        TestCase("AppServerProtocolMachine handles fragmented JSONL and notification interleaving") {
            var machine = AppServerProtocolMachine()
            let initial = try machine.start(refreshToken: false)

            try expect(initial.count == 1, "initialize request was not emitted once")
            let initialMethod = try wireMethod(initial[0])
            try expect(initialMethod == "initialize", "first request is not initialize")
            try expect(!String(decoding: initial[0], as: UTF8.self).contains("jsonrpc"), "wire includes jsonrpc")

            let firstChunk = Data(
                "{\"method\":\"server/notice\",\"params\":{}}\n{\"id\":1,\"res".utf8
            )
            let noOutput = try machine.receive(firstChunk)
            try expect(noOutput.isEmpty, "fragment advanced protocol state")

            let secondChunk = Data(
                "ult\":{}}\n{\"id\":99,\"result\":{}}\n".utf8
            )
            let afterInitialize = try machine.receive(secondChunk)
            try expect(afterInitialize.count == 2, "handshake did not emit two messages")
            let initializedMethod = try wireMethod(afterInitialize[0])
            let accountMethod = try wireMethod(afterInitialize[1])
            let refreshToken = try wireRefreshToken(afterInitialize[1])
            try expect(initializedMethod == "initialized", "initialized notification missing")
            try expect(accountMethod == "account/read", "account/read request missing")
            try expect(refreshToken == false, "refreshToken value changed")

            let accountJSON =
                "{\"method\":\"account/updated\",\"params\":{}}\n"
                    + "{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\","
                    + "\"email\":\"person@example.invalid\",\"planType\":\"pro\"},"
                    + "\"requiresOpenaiAuth\":true}}\n"
            let accountChunk = Data(accountJSON.utf8)
            _ = try machine.receive(accountChunk)

            try expect(
                machine.account == .chatGPT(
                    email: "person@example.invalid",
                    planType: "pro",
                    requiresOpenAIAuth: true
                ),
                "account response decoded incorrectly"
            )
            try expect(machine.readyToCloseStandardInput, "stdin close gate did not open")
        },
        TestCase("AppServerProtocolMachine reads only the main Codex rate-limit bucket") {
            var machine = try makeRateLimitsMachine()

            let response = Data(
                ("{\"id\":3,\"result\":{" +
                    "\"rateLimits\":{\"planType\":\"free\",\"primary\":{" +
                    "\"usedPercent\":2,\"windowDurationMins\":43200}}," +
                    "\"rateLimitsByLimitId\":{" +
                    "\"codex\":{\"planType\":\"pro\",\"primary\":{" +
                    "\"usedPercent\":25.5,\"windowDurationMins\":300," +
                    "\"resetsAt\":1800000000},\"secondary\":{" +
                    "\"usedPercent\":40,\"windowDurationMins\":10080," +
                    "\"resetsAt\":null}}," +
                    "\"codex_bengalfox\":{\"primary\":{\"usedPercent\":\"ignored\"}}}}}\n").utf8
            )
            _ = try machine.receive(response)

            try expect(
                machine.rateLimits == AppServerRateLimitsRead(
                    planType: "pro",
                    windows: [
                        AppServerRateLimitWindow(
                            usedPercent: 25.5,
                            windowDurationMinutes: 300,
                            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
                        ),
                        AppServerRateLimitWindow(
                            usedPercent: 40,
                            windowDurationMinutes: 10_080,
                            resetsAt: nil
                        ),
                    ]
                ),
                "main Codex windows were not selected"
            )
            try expect(machine.readyToCloseStandardInput, "rate-limit response did not open stdin gate")
            try machine.validateEndOfFile()

            var fallback = try makeRateLimitsMachine()
            _ = try fallback.receive(
                Data(
                    ("{\"id\":3,\"result\":{" +
                        "\"rateLimits\":{\"limitId\":\"codex\",\"planType\":\"free\",\"primary\":{" +
                        "\"usedPercent\":4,\"windowDurationMins\":43200}}," +
                        "\"rateLimitsByLimitId\":null}}\n").utf8
                )
            )
            try expect(fallback.rateLimits?.planType == "free", "top-level fallback was not used")
            try expect(
                fallback.rateLimits?.windows.first?.windowDurationMinutes == 43_200,
                "top-level fallback window changed"
            )

            var sparkOnly = try makeRateLimitsMachine()
            _ = try sparkOnly.receive(
                Data(
                    ("{\"id\":3,\"result\":{" +
                        "\"rateLimits\":{\"limitId\":\"codex_bengalfox\",\"primary\":{" +
                        "\"usedPercent\":99,\"windowDurationMins\":10080}}," +
                        "\"rateLimitsByLimitId\":{\"codex_bengalfox\":{\"primary\":{" +
                        "\"usedPercent\":99,\"windowDurationMins\":10080}}}}}\n").utf8
                )
            )
            try expect(sparkOnly.rateLimits?.windows.isEmpty == true, "Spark-only limit was exposed")

            var unknownDuration = try makeRateLimitsMachine()
            _ = try unknownDuration.receive(
                Data(
                    ("{\"id\":3,\"result\":{\"rateLimits\":{\"primary\":{" +
                        "\"usedPercent\":10,\"windowDurationMins\":null},\"secondary\":{" +
                        "\"usedPercent\":20,\"windowDurationMins\":300}}}}\n").utf8
                )
            )
            try expect(
                unknownDuration.rateLimits?.windows.map(\.windowDurationMinutes) == [300],
                "a schema-valid unknown duration hid known windows"
            )
        },
        TestCase("AppServerProtocolMachine rejects invalid rate-limit windows") {
            let invalidWindows = [
                "{\"usedPercent\":101,\"windowDurationMins\":300}",
                "{\"usedPercent\":20,\"windowDurationMins\":0}",
                "{\"usedPercent\":20,\"windowDurationMins\":300.5}",
                "{\"usedPercent\":true,\"windowDurationMins\":300}",
                "{\"usedPercent\":20,\"windowDurationMins\":300,\"resetsAt\":\"later\"}",
            ]
            for window in invalidWindows {
                var machine = try makeRateLimitsMachine()
                try expectError(
                    AppServerProtocolFailure(code: .protocolViolation),
                    "invalid rate-limit window was accepted"
                ) {
                    _ = try machine.receive(
                        Data(
                            "{\"id\":3,\"result\":{\"rateLimits\":{\"primary\":\(window)}}}\n".utf8
                        )
                    )
                }
            }
        },
        TestCase("AccountIdentityValidator uses exact email equality") {
            let account = AppServerAccountRead.chatGPT(
                email: "Person@example.invalid",
                planType: nil,
                requiresOpenAIAuth: true
            )

            try AccountIdentityValidator.validate(
                expectedEmail: "Person@example.invalid",
                account: account
            )
            try expectError(AccountIdentityError.emailMismatch, "case-folded email was accepted") {
                try AccountIdentityValidator.validate(
                    expectedEmail: "person@example.invalid",
                    account: account
                )
            }
            try expectError(AccountIdentityError.emailMismatch, "trimmed email was accepted") {
                try AccountIdentityValidator.validate(
                    expectedEmail: "Person@example.invalid ",
                    account: account
                )
            }
        },
        TestCase("AppServerProtocolMachine rejects fractional and duplicate response IDs") {
            var fractional = AppServerProtocolMachine()
            _ = try fractional.start(refreshToken: false)
            try expectError(
                AppServerProtocolFailure(code: .protocolViolation),
                "fractional response ID was accepted"
            ) {
                _ = try fractional.receive(Data("{\"id\":1.5,\"result\":{}}\n".utf8))
            }

            var duplicate = AppServerProtocolMachine()
            _ = try duplicate.start(refreshToken: false)
            try expectError(
                AppServerProtocolFailure(code: .malformedFrame),
                "duplicate response ID was accepted"
            ) {
                _ = try duplicate.receive(Data("{\"id\":1,\"id\":1,\"result\":{}}\n".utf8))
            }
        },
        TestCase("AppServerProbeSession waits for account, pipe EOF, and normal child exit") {
            try await withProbeTemporaryDirectory { directory in
                let executable = try makeFakeAppServer(in: directory)
                let home = directory.appendingPathComponent("codex-home", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
                let configuration = AppServerProbeConfiguration(
                    executableURL: executable,
                    codexHomeURL: home,
                    refreshToken: true,
                    timeouts: AppServerProbeTimeouts(
                        initializeResponse: .seconds(2),
                        accountResponse: .seconds(2),
                        normalExit: .seconds(2),
                        terminateExit: .seconds(1)
                    )
                )
                let launch = ProbeLaunchRecorder()
                let session = AppServerProbeSession(
                    configuration: configuration,
                    didLaunch: { launch.record($0) }
                )

                let account = try await session.run()

                try expect(
                    account == .chatGPT(
                        email: "probe@example.invalid",
                        planType: "test",
                        requiresOpenAIAuth: true
                    ),
                    "probe account result differs"
                )
                try expect(launch.pid != nil, "probe launch PID was not recorded")

                do {
                    _ = try await session.run()
                    throw TestFailure(description: "probe session ran twice")
                } catch let failure as AppServerProbeFailure {
                    try expect(failure.code == .alreadyUsed, "second run returned the wrong error")
                }
            }
        },
        TestCase("AppServerProbeSession returns account usage after normal child exit") {
            try await withProbeTemporaryDirectory { directory in
                let executable = try makeUsageFakeAppServer(in: directory)
                let home = directory.appendingPathComponent("codex-home", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
                let session = AppServerProbeSession(
                    configuration: AppServerProbeConfiguration(
                        executableURL: executable,
                        codexHomeURL: home,
                        refreshToken: false,
                        timeouts: AppServerProbeTimeouts(
                            initializeResponse: .seconds(2),
                            accountResponse: .seconds(2),
                            normalExit: .seconds(2),
                            terminateExit: .seconds(1)
                        )
                    )
                )

                let result = try await session.runAccountUsage()

                try expect(
                    result.account == .chatGPT(
                        email: "probe@example.invalid",
                        planType: "test",
                        requiresOpenAIAuth: true
                    ),
                    "usage probe account changed"
                )
                try expect(result.rateLimits.planType == "test", "usage probe plan changed")
                try expect(
                    result.rateLimits.windows.first?.windowDurationMinutes == 300,
                    "usage probe window changed"
                )
            }
        },
        TestCase("AppServerProbeSession stops when an exited child leaves inherited pipes open") {
            try await withProbeTemporaryDirectory { directory in
                let executable = try makePipeHoldingAppServer(in: directory)
                let home = directory.appendingPathComponent("codex-home", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
                let session = AppServerProbeSession(
                    configuration: AppServerProbeConfiguration(
                        executableURL: executable,
                        codexHomeURL: home,
                        refreshToken: false,
                        timeouts: AppServerProbeTimeouts(
                            initializeResponse: .seconds(1),
                            accountResponse: .seconds(1),
                            normalExit: .milliseconds(20),
                            terminateExit: .milliseconds(20)
                        )
                    )
                )

                do {
                    _ = try await session.run()
                    throw TestFailure(description: "open inherited pipes returned success")
                } catch let failure as AppServerProbeFailure {
                    try expect(failure.code == .childExitUnconfirmed, "open pipes returned the wrong failure")
                    try expect(failure.childDisposition == .unconfirmed, "open pipes were marked clean")
                }
            }
        },
        TestCase("AppServerProbeSession permits an owner-controlled default Codex home") {
            try await withProbeTemporaryDirectory { directory in
                let executable = try makeFakeAppServer(in: directory)
                let home = directory.appendingPathComponent("default-codex-home", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
                let session = AppServerProbeSession(
                    configuration: AppServerProbeConfiguration(
                        executableURL: executable,
                        codexHomeURL: home,
                        homePolicy: .ownerControlled,
                        refreshToken: true,
                        timeouts: AppServerProbeTimeouts(
                            initializeResponse: .seconds(2),
                            accountResponse: .seconds(2),
                            normalExit: .seconds(2),
                            terminateExit: .seconds(1)
                        )
                    )
                )

                let account = try await session.run()

                try expect(
                    account == .chatGPT(
                        email: "probe@example.invalid",
                        planType: "test",
                        requiresOpenAIAuth: true
                    ),
                    "owner-controlled default home was rejected"
                )
            }
        },
    ]
}

private final class ProbeLaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPID: Int32?

    var pid: Int32? { lock.withLock { recordedPID } }

    func record(_ pid: Int32) {
        lock.withLock { recordedPID = pid }
    }
}

private func withProbeTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-probe-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func makeFakeAppServer(in directory: URL) throws -> URL {
    let executable = directory.appendingPathComponent("fake-app-server")
    let script = #"""
    #!/bin/zsh
    IFS= read -r initialize
    print -r -- '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r account_read
    print -u2 -- 'discard-this-stderr-canary'
    print -r -- '{"id":2,"result":{"account":{"type":"chatgpt","email":"probe@example.invalid","planType":"test"},"requiresOpenaiAuth":true}}'
    while IFS= read -r ignored; do :; done
    """#
    try Data(script.utf8).write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

private func makeUsageFakeAppServer(in directory: URL) throws -> URL {
    let executable = directory.appendingPathComponent("fake-usage-app-server")
    let script = #"""
    #!/bin/zsh
    IFS= read -r initialize
    print -r -- '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r account_read
    print -r -- '{"id":2,"result":{"account":{"type":"chatgpt","email":"probe@example.invalid","planType":"test"},"requiresOpenaiAuth":true}}'
    IFS= read -r rate_limits_read
    print -r -- '{"id":3,"result":{"rateLimits":{"planType":"fallback","primary":{"usedPercent":1,"windowDurationMins":43200}},"rateLimitsByLimitId":{"codex":{"planType":"test","primary":{"usedPercent":12,"windowDurationMins":300}},"codex_bengalfox":{"primary":{"usedPercent":99,"windowDurationMins":10080}}}}}'
    while IFS= read -r ignored; do :; done
    """#
    try Data(script.utf8).write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

private func makePipeHoldingAppServer(in directory: URL) throws -> URL {
    let executable = directory.appendingPathComponent("pipe-holding-app-server")
    let script = #"""
    #!/bin/zsh
    IFS= read -r initialize
    print -r -- '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r account_read
    print -r -- '{"id":2,"result":{"account":{"type":"chatgpt","email":"probe@example.invalid","planType":"test"},"requiresOpenaiAuth":true}}'
    (sleep 0.3) &!
    exit 0
    """#
    try Data(script.utf8).write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

private func wireMethod(_ data: Data) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return object?["method"] as? String
}

private func wireRefreshToken(_ data: Data) throws -> Bool? {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let params = object?["params"] as? [String: Any]
    return params?["refreshToken"] as? Bool
}

private func makeRateLimitsMachine() throws -> AppServerProtocolMachine {
    var machine = AppServerProtocolMachine()
    _ = try machine.start(refreshToken: false, readRateLimits: true)
    _ = try machine.receive(Data("{\"id\":1,\"result\":{}}\n".utf8))
    let rateLimitRequest = try machine.receive(
        Data(
            ("{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\"," +
                "\"email\":\"probe@example.invalid\",\"planType\":\"test\"}," +
                "\"requiresOpenaiAuth\":true}}\n").utf8
        )
    )
    try expect(rateLimitRequest.count == 1, "rate-limit request count changed")
    let rateLimitMethod = try wireMethod(rateLimitRequest[0])
    try expect(
        rateLimitMethod == "account/rateLimits/read",
        "rate-limit request method changed"
    )
    try expect(!machine.readyToCloseStandardInput, "stdin closed before rate-limit response")
    return machine
}
