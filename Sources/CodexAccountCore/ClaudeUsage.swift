import Foundation

public struct ClaudeUsageWindow: Equatable, Sendable {
    public let label: String
    public let usedPercent: Int
    public let resetsAt: Date?
    public let resetDescription: String

    public var remainingPercent: Int { 100 - usedPercent }
}

public struct ClaudeUsageSnapshot: Equatable, Sendable {
    public let email: String?
    public let plan: String?
    public let windows: [ClaudeUsageWindow]
}

public enum ClaudeUsageError: Error, Equatable {
    case executableMissing
    case signedOut
    case commandFailed
    case invalidResponse
    case noLimits
}

public enum ClaudeUsageParser {
    public static func parse(
        authStatus: Data,
        usageOutput: Data,
        now: Date = .now
    ) throws -> ClaudeUsageSnapshot {
        guard let status = try? JSONSerialization.jsonObject(with: authStatus) as? [String: Any],
              let loggedIn = status["loggedIn"] as? Bool else {
            throw ClaudeUsageError.invalidResponse
        }
        guard loggedIn else { throw ClaudeUsageError.signedOut }
        guard let envelope = try? JSONSerialization.jsonObject(with: usageOutput) as? [String: Any],
              envelope["is_error"] as? Bool == false,
              envelope["local_command"] as? String == "usage",
              let result = envelope["result"] as? String else {
            throw ClaudeUsageError.invalidResponse
        }

        let prefixes = [
            ("Current session: ", "5시간"),
            ("Current week (all models): ", "주간"),
        ]
        var windows = [ClaudeUsageWindow]()
        for line in result.components(separatedBy: .newlines) {
            guard let (prefix, label) = prefixes.first(where: { line.hasPrefix($0.0) }),
                  let percentRange = line.range(of: "% used"),
                  let used = Int(line[line.index(line.startIndex, offsetBy: prefix.count)..<percentRange.lowerBound]),
                  (0...100).contains(used) else { continue }
            let resetDescription = line.range(of: " · resets ").map {
                String(line[$0.upperBound...])
            } ?? ""
            windows.append(ClaudeUsageWindow(
                label: label,
                usedPercent: used,
                resetsAt: parseReset(resetDescription, now: now),
                resetDescription: resetDescription
            ))
        }
        guard !windows.isEmpty else { throw ClaudeUsageError.noLimits }
        return ClaudeUsageSnapshot(
            email: status["email"] as? String,
            plan: status["subscriptionType"] as? String,
            windows: windows
        )
    }

    private static func parseReset(_ description: String, now: Date) -> Date? {
        guard let opening = description.lastIndex(of: "("),
              description.hasSuffix(")"),
              let timeZone = TimeZone(identifier: String(description[description.index(after: opening)..<description.index(before: description.endIndex)])) else {
            return nil
        }
        let dateText = description[..<opening].trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        let year = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: now).year ?? 2000
        // Claude omits minutes when the reset falls exactly on the hour.
        for format in ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy"] {
            formatter.dateFormat = format
            guard let candidate = formatter.date(from: "\(dateText) \(year)") else { continue }
            if candidate < now.addingTimeInterval(-3600) {
                return formatter.date(from: "\(dateText) \(year + 1)")
            }
            return candidate
        }
        return nil
    }
}

public enum ClaudeUsageProbe {
    public static func read() async throws -> ClaudeUsageSnapshot {
        try await Task.detached(priority: .utility) {
            try readSynchronously()
        }.value
    }

    private static func readSynchronously() throws -> ClaudeUsageSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".local/bin/claude").path,
        ]
        var lastError: Error = ClaudeUsageError.executableMissing
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            do {
                let status = try run(path, arguments: ["auth", "status"])
                let usage = try run(path, arguments: [
                    "-p", "/usage", "--output-format", "json", "--no-session-persistence",
                ])
                return try ClaudeUsageParser.parse(authStatus: status, usageOutput: usage)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func run(_ path: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ClaudeUsageError.commandFailed }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { throw ClaudeUsageError.commandFailed }
        return data
    }
}
