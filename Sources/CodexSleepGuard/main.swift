import CodexSleepGuardCore
import Darwin
import Foundation
import IOKit.ps
import OSLog
import notify

private let logger = Logger(
    subsystem: "local.codex.account-switcher",
    category: "sleep-guard"
)

@main
private enum CodexSleepGuard {
    static func main() {
        guard geteuid() == 0 else {
            logger.fault("event=start_failed reason=not_root")
            exit(77)
        }
        guard CommandLine.arguments.count == 2,
              let rawUID = UInt32(CommandLine.arguments[1]),
              rawUID > 0,
              let user = getpwuid(uid_t(rawUID)),
              let homePointer = user.pointee.pw_dir else {
            logger.fault("event=start_failed reason=invalid_uid")
            exit(64)
        }

        let configURL = URL(fileURLWithPath: String(cString: homePointer), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("CodexAccountSwitcher", isDirectory: true)
            .appendingPathComponent("sleep-guard-threshold", isDirectory: false)
        let daemon = SleepGuardDaemon(configURL: configURL, expectedUID: uid_t(rawUID))
        daemon.run()
    }
}

private final class SleepGuardDaemon: @unchecked Sendable {
    private let configURL: URL
    private let expectedUID: uid_t
    private let evaluationQueue = DispatchQueue(
        label: "local.codex.account-switcher.sleep-guard.evaluation"
    )
    private var notificationToken: Int32 = 0

    init(configURL: URL, expectedUID: uid_t) {
        self.configURL = configURL
        self.expectedUID = expectedUID
    }

    func run() -> Never {
        scheduleEvaluation()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<SleepGuardDaemon>
                .fromOpaque(context)
                .takeUnretainedValue()
                .scheduleEvaluation()
        }, context) else {
            logger.fault("event=start_failed reason=notification_source")
            exit(1)
        }
        let registrationStatus = sleepGuardReevaluationNotification.withCString {
            notify_register_dispatch($0, &notificationToken, evaluationQueue) { [weak self] _ in
                self?.evaluate()
            }
        }
        if registrationStatus != NOTIFY_STATUS_OK {
            logger.error("event=notification_registration_failed")
        }
        let source = unmanagedSource.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        logger.notice("event=started")
        CFRunLoopRun()
        exit(0)
    }

    private func scheduleEvaluation() {
        evaluationQueue.async { [weak self] in
            self?.evaluate()
        }
    }

    private func evaluate() {
        guard let power = PowerSourceSnapshot.read(),
              let sleepPreventionEnabled = try? PMSet.readEnabled() else {
            logger.error("event=evaluation_failed reason=state_unavailable")
            return
        }
        let threshold = loadThreshold()
        guard SleepGuardPolicy.shouldDisableSleep(
            threshold: threshold,
            batteryPercent: power.percent,
            isUsingBattery: power.isUsingBattery,
            sleepPreventionEnabled: sleepPreventionEnabled
        ) else {
            return
        }

        do {
            try PMSet.disableSleepPrevention()
            guard try PMSet.readEnabled() == false else {
                throw SleepGuardError.verificationFailed
            }
            logger.notice(
                "event=auto_disabled battery_percent=\(power.percent) threshold=\(threshold.rawValue)"
            )
        } catch {
            logger.fault("event=auto_disable_failed")
        }
    }

    private func loadThreshold() -> SleepGuardThreshold {
        let fileDescriptor = configURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else {
            return .defaultValue
        }
        defer { Darwin.close(fileDescriptor) }

        var information = stat()
        guard Darwin.fstat(fileDescriptor, &information) == 0 else { return .defaultValue }
        let permissions = information.st_mode & mode_t(0o777)
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == expectedUID,
              permissions & mode_t(0o022) == 0,
              information.st_size >= 0,
              information.st_size <= 3 else {
            logger.error("event=config_rejected")
            return .defaultValue
        }
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 4),
              data.count <= 3,
              let threshold = SleepGuardThreshold(storedData: data) else {
            logger.error("event=config_rejected")
            return .defaultValue
        }
        return threshold
    }
}

private struct PowerSourceSnapshot {
    let percent: Int
    let isUsingBattery: Bool

    static func read() -> PowerSourceSnapshot? {
        guard let unmanagedInformation = IOPSCopyPowerSourcesInfo() else {
            return nil
        }
        let information = unmanagedInformation.takeRetainedValue()
        guard let unmanagedSources = IOPSCopyPowerSourcesList(information) else {
            return nil
        }
        let sources = unmanagedSources.takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(information, source),
                  let description = unmanagedDescription.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0,
                  current >= 0 else {
                continue
            }
            let isCharging = description[kIOPSIsChargingKey] as? Bool == true
            return PowerSourceSnapshot(
                percent: min(100, current * 100 / maximum),
                isUsingBattery: description[kIOPSPowerSourceStateKey] as? String
                    == kIOPSBatteryPowerValue && !isCharging
            )
        }
        return nil
    }
}

private enum PMSet {
    static func readEnabled() throws -> Bool {
        let output = try run(arguments: ["-g"])
        guard let enabled = SleepGuardPolicy.parsePMSetOutput(output) else {
            throw SleepGuardError.invalidPMSetOutput
        }
        return enabled
    }

    static func disableSleepPrevention() throws {
        _ = try run(arguments: ["-a", "disablesleep", "0"])
    }

    private static func run(arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            throw SleepGuardError.commandFailed
        }
        return text
    }
}

private enum SleepGuardError: Error {
    case commandFailed
    case invalidPMSetOutput
    case verificationFailed
}
