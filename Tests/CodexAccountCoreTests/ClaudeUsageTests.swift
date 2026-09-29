import CodexAccountCore
import Foundation

func claudeUsageTests() -> [TestCase] {
    [
        TestCase("Claude usage parses subscription windows and reset dates") {
            let status = Data(#"{"loggedIn":true,"email":"user@example.com","subscriptionType":"pro"}"#.utf8)
            let text = """
                You are currently using your subscription to power your Claude Code usage

                Current session: 10% used · resets Sep 28 at 2:29am (Asia/Seoul)
                Current week (all models): 48% used · resets Sep 30 at 10:59pm (Asia/Seoul)
                """
            let output = try JSONSerialization.data(withJSONObject: [
                "is_error": false,
                "local_command": "usage",
                "result": text,
            ])
            let now = ISO8601DateFormatter().date(from: "2026-09-27T00:00:00Z")!
            let snapshot = try ClaudeUsageParser.parse(
                authStatus: status,
                usageOutput: output,
                now: now
            )
            try expect(snapshot.email == "user@example.com", "Claude email should match auth status")
            try expect(snapshot.plan == "pro", "Claude plan should match auth status")
            try expect(snapshot.windows.map(\.remainingPercent) == [90, 52], "remaining percentages should invert used percentages")
            let expectedReset = ISO8601DateFormatter().date(from: "2026-09-27T17:29:00Z")
            try expect(snapshot.windows[0].resetsAt == expectedReset, "session reset should use Asia/Seoul time")
        },
        TestCase("Claude usage rejects signed-out status") {
            let status = Data(#"{"loggedIn":false}"#.utf8)
            try expectError(ClaudeUsageError.signedOut, "signed-out status must not show cached usage") {
                _ = try ClaudeUsageParser.parse(authStatus: status, usageOutput: Data())
            }
        },
    ]
}
