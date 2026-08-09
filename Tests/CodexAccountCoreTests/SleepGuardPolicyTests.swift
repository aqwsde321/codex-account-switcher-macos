import CodexSleepGuardCore
import Foundation

func sleepGuardPolicyTests() -> [TestCase] {
    [
        TestCase("SleepGuardThreshold accepts canonical values from zero through 99") {
            guard let seventeen = SleepGuardThreshold(rawValue: 17),
                  let ninetyNine = SleepGuardThreshold(rawValue: 99) else {
                throw TestFailure(description: "valid sleep guard threshold was rejected")
            }
            try expect(
                SleepGuardThreshold(storedData: Data("0\n".utf8)) == .off
                    && SleepGuardThreshold.defaultValue.rawValue == 30
                    && SleepGuardThreshold(storedData: Data("17\n".utf8)) == seventeen
                    && SleepGuardThreshold(storedData: Data("99\n".utf8)) == ninetyNine
                    && ninetyNine.storedData == Data("99\n".utf8)
                    && SleepGuardThreshold(storedData: Data("01\n".utf8)) == nil
                    && SleepGuardThreshold(storedData: Data("100\n".utf8)) == nil
                    && SleepGuardThreshold(rawValue: -1) == nil
                    && SleepGuardThreshold(rawValue: 100) == nil
                    && SleepGuardThreshold(storedData: Data("20".utf8)) == nil,
                "sleep guard threshold accepted an out-of-range or malformed value"
            )
        },
        TestCase("SleepGuardPolicy disables only enabled sleep prevention on low battery") {
            guard let threshold = SleepGuardThreshold(rawValue: 20) else {
                throw TestFailure(description: "valid sleep guard threshold was rejected")
            }
            try expect(
                SleepGuardPolicy.shouldDisableSleep(
                    threshold: threshold,
                    batteryPercent: 20,
                    isUsingBattery: true,
                    sleepPreventionEnabled: true
                )
                    && !SleepGuardPolicy.shouldDisableSleep(
                        threshold: threshold,
                        batteryPercent: 21,
                        isUsingBattery: true,
                        sleepPreventionEnabled: true
                    )
                    && !SleepGuardPolicy.shouldDisableSleep(
                        threshold: threshold,
                        batteryPercent: 10,
                        isUsingBattery: false,
                        sleepPreventionEnabled: true
                    )
                    && !SleepGuardPolicy.shouldDisableSleep(
                        threshold: .off,
                        batteryPercent: 1,
                        isUsingBattery: true,
                        sleepPreventionEnabled: true
                    )
                    && !SleepGuardPolicy.shouldDisableSleep(
                        threshold: threshold,
                        batteryPercent: -1,
                        isUsingBattery: true,
                        sleepPreventionEnabled: true
                    ),
                "sleep guard policy ignored a safety condition"
            )
        },
        TestCase("SleepGuardPolicy parses only SleepDisabled pmset output") {
            try expect(
                SleepGuardPolicy.parsePMSetOutput("SleepDisabled 1") == true
                    && SleepGuardPolicy.parsePMSetOutput("SleepDisabled 0") == false
                    && SleepGuardPolicy.parsePMSetOutput("SleepDisabled unknown") == nil
                    && SleepGuardPolicy.parsePMSetOutput("sleep 1") == nil,
                "sleep guard parsed an invalid pmset state"
            )
        },
    ]
}
