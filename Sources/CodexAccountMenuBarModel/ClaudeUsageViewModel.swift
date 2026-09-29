import Combine
import CodexAccountCore
import Foundation

@MainActor
public final class ClaudeUsageViewModel: ObservableObject {
    @Published public private(set) var snapshot: ClaudeUsageSnapshot?
    @Published public private(set) var refreshedAt: Date?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isRefreshing = false

    public init() {}

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await ClaudeUsageProbe.read()
            refreshedAt = .now
            errorMessage = nil
        } catch ClaudeUsageError.executableMissing {
            errorMessage = "Claude Code CLI를 찾을 수 없습니다."
        } catch ClaudeUsageError.signedOut {
            snapshot = nil
            refreshedAt = nil
            errorMessage = "Claude Code CLI 로그인이 필요합니다."
        } catch {
            errorMessage = "Claude 사용량 조회에 실패했습니다."
        }
    }
}
