import AppKit
import Foundation

public enum CodexAppLifecycleFailure: Error, Equatable, Sendable {
    case applicationIdentityChanged
    case normalTerminationRequestRejected
    case launchFailed
}

@MainActor
public final class CodexAppLifecycle {
    public init() {}

    public func runningApplicationPIDs(for descriptor: CodexAppDescriptor) throws -> [Int32] {
        try runningApplications(for: descriptor)
            .map(\.processIdentifier)
            .sorted()
    }

    public func activateIfRunning(_ descriptor: CodexAppDescriptor) throws -> Bool {
        guard let application = try runningApplications(for: descriptor).first else {
            return false
        }
        return application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    public func requestNormalTermination(_ descriptor: CodexAppDescriptor) throws -> [Int32] {
        let applications = try runningApplications(for: descriptor)
        var requested = [Int32]()
        for application in applications {
            guard application.terminate() else {
                throw CodexAppLifecycleFailure.normalTerminationRequestRejected
            }
            requested.append(application.processIdentifier)
        }
        return requested.sorted()
    }

    public func launch(_ descriptor: CodexAppDescriptor) async throws -> Int32 {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false

        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: descriptor.bundleURL,
                configuration: configuration
            ) { application, error in
                guard error == nil, let application else {
                    continuation.resume(throwing: CodexAppLifecycleFailure.launchFailed)
                    return
                }
                continuation.resume(returning: application.processIdentifier)
            }
        }
    }
}

private extension CodexAppLifecycle {
    func runningApplications(for descriptor: CodexAppDescriptor) throws -> [NSRunningApplication] {
        let expectedBundle = descriptor.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: descriptor.bundleIdentifier
        )
        for application in applications {
            guard application.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == expectedBundle else {
                throw CodexAppLifecycleFailure.applicationIdentityChanged
            }
        }
        return applications
    }
}
