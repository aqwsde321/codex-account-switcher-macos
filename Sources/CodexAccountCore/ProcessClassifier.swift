import Foundation

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public struct ProcessRecord: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let executablePath: String?
    public let nameHint: String?
    public let signingIdentifier: String?
    public let teamIdentifier: String?

    public init(
        identity: ProcessIdentity,
        parentPID: Int32,
        executablePath: String?,
        nameHint: String?,
        signingIdentifier: String? = nil,
        teamIdentifier: String? = nil
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.nameHint = nameHint
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public struct ApprovedResidentRule: Equatable, Sendable {
    public let executablePath: String
    public let name: String
    public let signingIdentifier: String
    public let teamIdentifier: String

    public init(
        executablePath: String,
        name: String,
        signingIdentifier: String,
        teamIdentifier: String
    ) {
        self.executablePath = executablePath
        self.name = name
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }

    package static func codexCrashpad(for descriptor: CodexAppDescriptor) -> ApprovedResidentRule? {
        guard descriptor.bundleIdentifier == CodexAppLocator.officialBundleIdentifier,
              descriptor.appSigningIdentifier == CodexAppLocator.officialBundleIdentifier,
              descriptor.bundledCodexSigningIdentifier == "codex",
              descriptor.crashpadSigningIdentifier == "browser_crashpad_handler",
              descriptor.teamIdentifier == CodexAppLocator.observedOfficialTeamIdentifier else {
            return nil
        }
        let bundleURL = descriptor.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let executableURL = descriptor.crashpadExecutableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let bundleComponents = bundleURL.pathComponents
        let executableComponents = executableURL.pathComponents
        let relativeComponents = Array(executableComponents.dropFirst(bundleComponents.count))
        guard relativeComponents.count == 7,
              Array(executableComponents.prefix(bundleComponents.count)) == bundleComponents,
              relativeComponents[0] == "Contents",
              relativeComponents[1] == "Frameworks",
              relativeComponents[2] == "Codex Framework.framework",
              relativeComponents[3] == "Versions",
              relativeComponents[5] == "Helpers",
              relativeComponents[6] == "browser_crashpad_handler" else {
            return nil
        }
        return ApprovedResidentRule(
            executablePath: executableURL.path,
            name: "browser_crashpad_handler",
            signingIdentifier: "browser_crashpad_handler",
            teamIdentifier: descriptor.teamIdentifier
        )
    }
}

public struct ProcessClassificationContext: Sendable {
    public let bundleRootPath: String
    public let mainExecutablePath: String
    public let bundledCodexPath: String
    public let appRootIdentities: Set<ProcessIdentity>
    public let helperOwnedIdentities: Set<ProcessIdentity>
    public let approvedResidents: [ApprovedResidentRule]

    public init(
        bundleRootPath: String,
        mainExecutablePath: String,
        bundledCodexPath: String,
        appRootIdentities: Set<ProcessIdentity>,
        helperOwnedIdentities: Set<ProcessIdentity>,
        approvedResidents: [ApprovedResidentRule]
    ) {
        self.bundleRootPath = bundleRootPath
        self.mainExecutablePath = mainExecutablePath
        self.bundledCodexPath = bundledCodexPath
        self.appRootIdentities = appRootIdentities
        self.helperOwnedIdentities = helperOwnedIdentities
        self.approvedResidents = approvedResidents
    }
}

public enum ProcessDisposition: Int, Equatable, Sendable {
    case approvedNonAuthResident
    case helperOwnedProbe
    case appOwnedBlocker
    case independentCodexBlocker
    case unclassifiedRelevant
    case irrelevant

    var blocksAuthMutation: Bool {
        switch self {
        case .approvedNonAuthResident, .irrelevant:
            false
        case .helperOwnedProbe, .appOwnedBlocker, .independentCodexBlocker, .unclassifiedRelevant:
            true
        }
    }
}

public struct ClassifiedProcess: Equatable, Sendable {
    public let record: ProcessRecord
    public let disposition: ProcessDisposition
}

public struct ProcessInventory: Equatable, Sendable {
    public let processes: [ClassifiedProcess]

    public var authMutationAllowed: Bool {
        !processes.contains(where: { $0.disposition.blocksAuthMutation })
    }

    public func disposition(forPID pid: Int32) -> ProcessDisposition? {
        processes.first(where: { $0.record.identity.pid == pid })?.disposition
    }
}

public enum ProcessClassifier {
    public static func classify(
        _ records: [ProcessRecord],
        context: ProcessClassificationContext
    ) -> ProcessInventory {
        var byPID = [Int32: ProcessRecord]()
        var duplicatePIDs = Set<Int32>()
        for record in records {
            if byPID.updateValue(record, forKey: record.identity.pid) != nil {
                duplicatePIDs.insert(record.identity.pid)
            }
        }
        let classified = records.map { record in
            ClassifiedProcess(
                record: record,
                disposition: duplicatePIDs.contains(record.identity.pid)
                    ? .unclassifiedRelevant
                    : disposition(for: record, recordsByPID: byPID, context: context)
            )
        }.sorted {
            if $0.disposition.rawValue != $1.disposition.rawValue {
                return $0.disposition.rawValue < $1.disposition.rawValue
            }
            if $0.record.identity.pid != $1.record.identity.pid {
                return $0.record.identity.pid < $1.record.identity.pid
            }
            if $0.record.identity.startSeconds != $1.record.identity.startSeconds {
                return $0.record.identity.startSeconds < $1.record.identity.startSeconds
            }
            return $0.record.identity.startMicroseconds < $1.record.identity.startMicroseconds
        }
        return ProcessInventory(processes: classified)
    }
}

private extension ProcessClassifier {
    static func disposition(
        for record: ProcessRecord,
        recordsByPID: [Int32: ProcessRecord],
        context: ProcessClassificationContext
    ) -> ProcessDisposition {
        if context.approvedResidents.contains(where: { rule in
            record.executablePath == rule.executablePath
                && record.nameHint == rule.name
                && record.signingIdentifier == rule.signingIdentifier
                && record.teamIdentifier == rule.teamIdentifier
        }) {
            return .approvedNonAuthResident
        }
        if context.helperOwnedIdentities.contains(record.identity) {
            return .helperOwnedProbe
        }
        if context.appRootIdentities.contains(record.identity) {
            return .appOwnedBlocker
        }

        let appDescendant = reachesAppRoot(
            from: record,
            recordsByPID: recordsByPID,
            roots: context.appRootIdentities
        )
        if let path = record.executablePath {
            if path == context.bundledCodexPath {
                return appDescendant ? .appOwnedBlocker : .independentCodexBlocker
            }
            if path == context.mainExecutablePath || isInside(path, root: context.bundleRootPath) || appDescendant {
                return .appOwnedBlocker
            }
            if URL(fileURLWithPath: path).lastPathComponent == "codex" {
                return .independentCodexBlocker
            }
        } else if appDescendant {
            return .appOwnedBlocker
        }

        if record.nameHint == "codex"
            || record.nameHint == "ChatGPT"
            || record.nameHint == "browser_crashpad_handler"
            || record.nameHint?.hasPrefix("ChatGPT Helper") == true
        {
            return .unclassifiedRelevant
        }
        return .irrelevant
    }

    static func reachesAppRoot(
        from record: ProcessRecord,
        recordsByPID: [Int32: ProcessRecord],
        roots: Set<ProcessIdentity>
    ) -> Bool {
        var parentPID = record.parentPID
        var visited: Set<Int32> = [record.identity.pid]
        while let parent = recordsByPID[parentPID], visited.insert(parentPID).inserted {
            if roots.contains(parent.identity) {
                return true
            }
            parentPID = parent.parentPID
        }
        return false
    }

    static func isInside(_ path: String, root: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path).standardized.pathComponents
        let rootComponents = URL(fileURLWithPath: root).standardized.pathComponents
        guard pathComponents.count >= rootComponents.count else { return false }
        return Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }
}
