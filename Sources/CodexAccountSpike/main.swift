import Darwin
import Foundation
import CodexAccountCore

@main
struct CodexAccountSpikeCLI {
    static func main() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let storeURL = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("CodexAccountSwitcherSpike", isDirectory: true)
        let authURL = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        let provider = LocalReadOnlyCLIDataProvider(
            storeURL: storeURL,
            activeAuthURL: authURL
        )
        let application = CLIApplication(provider: provider)
        let result = await application.run(arguments: Array(CommandLine.arguments.dropFirst()))

        if let output = result.standardOutput.data(using: .utf8) {
            try? FileHandle.standardOutput.write(contentsOf: output)
        }
        if let error = result.standardError.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: error)
        }
        exit(result.exitCode)
    }
}
