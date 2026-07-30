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
        let provider = LocalCLIDataProvider(
            storeURL: storeURL,
            activeAuthURL: authURL,
            confirmAppOwnedTermination: { count in
                guard isatty(STDIN_FILENO) == 1 else { return false }
                let prompt = "정상 종료 후 ChatGPT 앱 소유 프로세스 \(count)개가 남았습니다. SIGTERM으로 종료하고 전환을 계속하려면 TERMINATE 입력: "
                if let data = prompt.data(using: .utf8) {
                    try? FileHandle.standardError.write(contentsOf: data)
                }
                return readLine() == "TERMINATE"
            }
        )
        let application = CLIApplication(provider: provider)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mutationConfirmed: Bool
        if arguments.count == 3,
           arguments[0...1] == ["switch", "--target"],
           isatty(STDIN_FILENO) == 1 {
            let prompt = "공식 ChatGPT 앱을 정상 종료하고 기본 Codex 인증을 대상 프로필로 교체한 뒤 앱을 다시 실행합니다. 잔존 앱 프로세스 SIGTERM은 별도 확인합니다. 계속하려면 SWITCH 입력: "
            if let data = prompt.data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
            mutationConfirmed = readLine() == "SWITCH"
        } else if arguments == ["profile", "sync-active"], isatty(STDIN_FILENO) == 1 {
            let prompt = "현재 인증의 계정 이메일을 확인한 뒤 저장된 활성 프로필 인증만 교체합니다. 계정 전환은 하지 않습니다. 계속하려면 SYNC 입력: "
            if let data = prompt.data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
            mutationConfirmed = readLine() == "SYNC"
        } else if arguments.count == 4,
                  arguments[0...2] == ["profile", "capture", "--label"],
                  isatty(STDIN_FILENO) == 1 {
            let prompt = "현재 인증을 갱신해 Spike private store에 저장합니다. 두 번째 프로필이면 저장 후 첫 프로필로 복귀하고 ChatGPT 앱을 실행합니다. 계속하려면 CAPTURE 입력: "
            if let data = prompt.data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
            mutationConfirmed = readLine() == "CAPTURE"
        } else {
            mutationConfirmed = false
        }
        let result = await application.run(
            arguments: arguments,
            mutationConfirmed: mutationConfirmed
        )

        if let output = result.standardOutput.data(using: .utf8) {
            try? FileHandle.standardOutput.write(contentsOf: output)
        }
        if let error = result.standardError.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: error)
        }
        exit(result.exitCode)
    }
}
