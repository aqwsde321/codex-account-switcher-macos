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
        TestCase("Login URL parser accepts a complete split trusted URL only once") {
            var parser = CodexLoginAuthorizationURLParser()
            let bytes = Array(loginAuthorizationURL.utf8)
            let split = bytes.count / 2
            try expect(parser.consume(Data(bytes[..<split])) == nil, "partial URL escaped the parser")
            let result = parser.consume(Data(bytes[split...] + [10]))
            try expect(result?.absoluteString == loginAuthorizationURL, "split URL was not reassembled")
            try expect(
                parser.consume(Data((loginAuthorizationURL + "\n").utf8)) == nil,
                "login URL was emitted more than once"
            )
        },
        TestCase("Login URL parser rejects unsafe endpoints and incomplete OAuth requests") {
            let rejected = [
                loginAuthorizationURL.replacingOccurrences(of: "https://", with: "http://"),
                loginAuthorizationURL.replacingOccurrences(of: "auth.openai.com", with: "auth.openai.com.evil.invalid"),
                loginAuthorizationURL.replacingOccurrences(of: "auth.openai.com", with: "auth.openai.com:9443"),
                loginAuthorizationURL.replacingOccurrences(of: "auth.openai.com", with: "user:secret@auth.openai.com"),
                loginAuthorizationURL.replacingOccurrences(of: "/oauth/authorize", with: "/oauth/token"),
                loginAuthorizationURL.replacingOccurrences(of: "localhost", with: "evil.invalid"),
                loginAuthorizationURL.replacingOccurrences(of: "%2Fauth%2Fcallback", with: "%2Fother"),
                loginAuthorizationURL.replacingOccurrences(of: "response_type=code", with: "response_type=token"),
                loginAuthorizationURL.replacingOccurrences(of: "code_challenge_method=S256", with: "code_challenge_method=plain"),
                loginAuthorizationURL.replacingOccurrences(of: "&state=fake-state", with: ""),
                loginAuthorizationURL + "&state=duplicate",
                loginAuthorizationURL + "#fragment",
                "untrusted prefix " + loginAuthorizationURL,
            ]
            for candidate in rejected {
                var parser = CodexLoginAuthorizationURLParser()
                try expect(parser.consume(Data((candidate + "\n").utf8)) == nil, "unsafe login URL was accepted")
                try expect(
                    parser.consume(Data((loginAuthorizationURL + "\n").utf8)) != nil,
                    "rejected output prevented a later valid URL"
                )
            }
        },
        TestCase("Login URL parser discards oversized lines before accepting a fresh line") {
            var parser = CodexLoginAuthorizationURLParser()
            for _ in 0..<256 {
                try expect(parser.consume(Data(repeating: 120, count: 4_096)) == nil, "noise became a URL")
            }
            try expect(
                parser.consume(Data((loginAuthorizationURL + "\n").utf8)) == nil,
                "URL suffix of an oversized line was accepted"
            )
            try expect(
                parser.consume(Data((loginAuthorizationURL + "\n").utf8)) != nil,
                "parser did not recover after an oversized line"
            )
        },
        TestCase("CodexLoginSession drains noisy stderr and delivers a split login URL once") {
            try await withLoginTemporaryDirectory { directory in
                let home = try makePrivateLoginHome(in: directory)
                let split = loginAuthorizationURL.index(loginAuthorizationURL.startIndex, offsetBy: 50)
                let executable = try makeOutputLoginExecutable(in: directory, script: #"""
                for i in {1..4096}; do print -rn -- 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done >&2
                print -r -- '' >&2
                print -rn -- '\#(loginAuthorizationURL[..<split])' >&2
                sleep 0.02
                print -r -- '\#(loginAuthorizationURL[split...])' >&2
                print -r -- '\#(loginAuthorizationURL)' >&2
                while [[ ! -f "$CODEX_HOME/url-seen" ]]; do sleep 0.01; done
                """#)
                let observer = LoginURLObserver()
                let session = CodexLoginSession(
                    configuration: CodexLoginConfiguration(
                        executableURL: executable,
                        codexHomeURL: home,
                        timeouts: CodexLoginTimeouts(login: .seconds(5), terminateExit: .seconds(1))
                    ),
                    onAuthorizationURL: { url in
                        await observer.record(url)
                        try? Data().write(to: home.appendingPathComponent("url-seen"))
                    }
                )
                try await session.run()
                let urls = await observer.urls
                try expect(urls.count == 1, "noisy login did not deliver exactly one URL")
                try expect(urls.first?.absoluteString == loginAuthorizationURL, "login URL changed")
            }
        },
        TestCase("CodexLoginSession suppresses URLs printed while cancellation terminates the child") {
            try await withLoginTemporaryDirectory { directory in
                let home = try makePrivateLoginHome(in: directory)
                let executable = try makeOutputLoginExecutable(in: directory, script: #"""
                trap 'print -r -- "\#(loginAuthorizationURL)" >&2; exit 0' TERM
                touch "$CODEX_HOME/ready"
                while true; do sleep 0.01; done
                """#)
                let observer = LoginURLObserver()
                let session = CodexLoginSession(
                    configuration: CodexLoginConfiguration(
                        executableURL: executable,
                        codexHomeURL: home,
                        timeouts: CodexLoginTimeouts(login: .seconds(5), terminateExit: .seconds(1))
                    ),
                    onAuthorizationURL: { await observer.record($0) }
                )
                let task = Task { try await session.run() }
                let deadline = ContinuousClock.now + .seconds(2)
                while !FileManager.default.fileExists(atPath: home.appendingPathComponent("ready").path),
                      ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                await session.cancel()
                do {
                    try await task.value
                    throw TestFailure(description: "cancelled noisy child returned success")
                } catch let failure as CodexLoginFailure {
                    try expect(failure.code == .cancelled, "noisy child cancellation changed failure")
                }
                let urls = await observer.urls
                try expect(urls.isEmpty, "cancelled login published a late authorization URL")
            }
        },
        TestCase("CodexLoginSession finishes without waiting for an inherited stderr pipe") {
            try await withLoginTemporaryDirectory { directory in
                let home = try makePrivateLoginHome(in: directory)
                let executable = try makeOutputLoginExecutable(in: directory, script: #"""
                (sleep 0.3; print -r -- '\#(loginAuthorizationURL)' >&2) &!
                exit 0
                """#)
                let observer = LoginURLObserver()
                let session = CodexLoginSession(
                    configuration: CodexLoginConfiguration(
                        executableURL: executable,
                        codexHomeURL: home,
                        timeouts: CodexLoginTimeouts(login: .seconds(2), terminateExit: .seconds(1))
                    ),
                    onAuthorizationURL: { await observer.record($0) }
                )
                try await session.run()
                try await Task.sleep(for: .milliseconds(400))
                let urls = await observer.urls
                try expect(urls.isEmpty, "finished login published an inherited pipe's late URL")
            }
        },
    ]
}

private let loginAuthorizationURL = "https://auth.openai.com/oauth/authorize?client_id=fake-client&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid%20profile%20email%20offline_access&code_challenge=fake-challenge&code_challenge_method=S256&state=fake-state"

private actor LoginURLObserver {
    private(set) var urls = [URL]()
    func record(_ url: URL) { urls.append(url) }
}

private func makeOutputLoginExecutable(in directory: URL, script: String) throws -> URL {
    let executable = directory.appendingPathComponent("output-codex-login")
    try Data(("#!/bin/zsh\n" + script + "\n").utf8).write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
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
