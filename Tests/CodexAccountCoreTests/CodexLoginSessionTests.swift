import Foundation
import CodexAccountCore

func codexLoginSessionTests() -> [TestCase] {
    [
        TestCase("CodexLoginSession confines browser login to its private home") {
            try await withLoginTemporaryDirectory { directory in
                let home = try makePrivateLoginHome(in: directory)
                let executable = try makeSuccessfulLoginExecutable(in: directory, expectedHome: home)
                let session = CodexLoginSession(
                    configuration: CodexLoginConfiguration(
                        executableURL: executable,
                        codexHomeURL: home,
                        timeouts: CodexLoginTimeouts(login: .seconds(2), terminateExit: .seconds(1))
                    )
                )

                try await session.run()

                try expect(
                    FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path),
                    "isolated login did not write its private auth file"
                )
                do {
                    try await session.run()
                    throw TestFailure(description: "login session ran twice")
                } catch let failure as CodexLoginFailure {
                    try expect(failure.code == .alreadyUsed, "second login returned the wrong failure")
                }
            }
        },
        TestCase("Codex child environment removes inherited auth overrides") {
            let home = URL(fileURLWithPath: "/private/tmp/isolated-codex-home", isDirectory: true)
            let environment = sanitizedCodexEnvironment(
                homeURL: home,
                base: [
                    "PATH": "/usr/bin",
                    "CODEX_AUTH": "secret",
                    "CODEX_AUTHAPI_BASE_URL": "https://attacker.invalid",
                    "CODEX_ACCESS_TOKEN": "secret",
                    "OPENAI_API_KEY": "secret",
                ]
            )

            try expect(environment["PATH"] == "/usr/bin", "sanitizer removed an unrelated variable")
            try expect(environment["CODEX_HOME"] == home.path, "sanitizer omitted CODEX_HOME")
            try expect(environment["CODEX_SQLITE_HOME"] == home.path, "sanitizer omitted CODEX_SQLITE_HOME")
            try expect(environment["CODEX_AUTH"] == nil, "sanitizer kept CODEX_AUTH")
            try expect(environment["CODEX_AUTHAPI_BASE_URL"] == nil, "sanitizer kept auth base override")
            try expect(environment["CODEX_ACCESS_TOKEN"] == nil, "sanitizer kept an access token")
            try expect(environment["OPENAI_API_KEY"] == nil, "sanitizer kept an API key")
        },
        TestCase("CodexLoginSession cancels only its confirmed child") {
            try await withLoginTemporaryDirectory { directory in
                let home = try makePrivateLoginHome(in: directory)
                let executable = try makeWaitingLoginExecutable(in: directory)
                let session = CodexLoginSession(
                    configuration: CodexLoginConfiguration(
                        executableURL: executable,
                        codexHomeURL: home,
                        timeouts: CodexLoginTimeouts(login: .seconds(2), terminateExit: .seconds(1))
                    )
                )
                let task = Task { try await session.run() }
                try await Task.sleep(for: .milliseconds(50))
                await session.cancel()

                do {
                    try await task.value
                    throw TestFailure(description: "cancelled login returned success")
                } catch let failure as CodexLoginFailure {
                    try expect(failure.code == .cancelled, "cancelled login returned the wrong failure")
                    try expect(
                        failure.childDisposition == .confirmedExited,
                        "cancelled login child exit was not confirmed"
                    )
                }
            }
        },
    ]
}

private func withLoginTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-login-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func makePrivateLoginHome(in directory: URL) throws -> URL {
    let home = directory.appendingPathComponent("login-home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    return home
}

private func makeSuccessfulLoginExecutable(in directory: URL, expectedHome: URL) throws -> URL {
    let executable = directory.appendingPathComponent("fake-codex-login")
    let script = #"""
    #!/bin/zsh
    [[ "$CODEX_HOME" == "\#(expectedHome.path)" ]] || exit 20
    [[ "$CODEX_SQLITE_HOME" == "\#(expectedHome.path)" ]] || exit 21
    [[ "$*" == *'cli_auth_credentials_store="file"'* ]] || exit 22
    [[ "$*" == *'login'* ]] || exit 23
    [[ -z "${OPENAI_API_KEY:-}" && -z "${CODEX_API_KEY:-}" && -z "${CODEX_ACCESS_TOKEN:-}" ]] || exit 24
    print -rn -- '{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"id","access_token":"access","refresh_token":"refresh"}}' > "$CODEX_HOME/auth.json"
    chmod 600 "$CODEX_HOME/auth.json"
    """#
    try Data(script.utf8).write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

private func makeWaitingLoginExecutable(in directory: URL) throws -> URL {
    let executable = directory.appendingPathComponent("waiting-codex-login")
    let script = #"""
    #!/bin/zsh
    trap 'exit 0' TERM
    while true; do sleep 0.05; done
    """#
    try Data(script.utf8).write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}
