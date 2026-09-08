import Foundation

public struct TokenUseResult: Codable, Sendable {
    public let completedAt: Date
    public let response: String
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(response: String, events: Data = Data()) {
        completedAt = .now
        self.response = response
        var input: Int?
        var output: Int?
        for line in events.split(separator: 10) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  event["type"] as? String == "turn.completed",
                  let usage = event["usage"] as? [String: Any] else { continue }
            input = usage["input_tokens"] as? Int
            output = usage["output_tokens"] as? Int
        }
        inputTokens = input
        outputTokens = output
    }
}
