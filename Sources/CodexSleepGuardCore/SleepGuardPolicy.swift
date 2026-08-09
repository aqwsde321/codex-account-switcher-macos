import Foundation

public let sleepGuardReevaluationNotification =
    "local.codex.account-switcher.sleep-guard.reevaluate"

public struct SleepGuardThreshold: RawRepresentable, Equatable, Sendable {
    public static let off = SleepGuardThreshold(validRawValue: 0)
    public static let defaultValue = SleepGuardThreshold(validRawValue: 30)

    public let rawValue: Int

    public init?(rawValue: Int) {
        guard (0...99).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init?(storedData: Data) {
        guard storedData.count <= 3,
              let text = String(data: storedData, encoding: .utf8),
              text.last == "\n",
              let value = Int(text.dropLast()),
              text == "\(value)\n",
              let threshold = Self(rawValue: value) else {
            return nil
        }
        self = threshold
    }

    public var storedData: Data {
        Data("\(rawValue)\n".utf8)
    }

    public var label: String {
        self == .off ? "끔" : "\(rawValue)%"
    }

    private init(validRawValue: Int) {
        rawValue = validRawValue
    }
}

public enum SleepGuardPolicy {
    public static func shouldDisableSleep(
        threshold: SleepGuardThreshold,
        batteryPercent: Int,
        isUsingBattery: Bool,
        sleepPreventionEnabled: Bool
    ) -> Bool {
        threshold != .off
            && (0...100).contains(batteryPercent)
            && isUsingBattery
            && sleepPreventionEnabled
            && batteryPercent <= threshold.rawValue
    }

    public static func parsePMSetOutput(_ output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  fields[0].lowercased() == "sleepdisabled" else {
                continue
            }
            if fields[1] == "1" { return true }
            if fields[1] == "0" { return false }
            return nil
        }
        return nil
    }
}
