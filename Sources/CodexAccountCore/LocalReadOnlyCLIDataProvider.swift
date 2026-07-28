import Foundation

public actor LocalReadOnlyCLIDataProvider: ReadOnlyCLIDataProviding {
    private let storeURL: URL
    private let activeAuthURL: URL
    private let processProvider: any ProcessSnapshotProviding
    private let files = DarwinDurableFileOperations()

    public init(
        storeURL: URL,
        activeAuthURL: URL,
        processProvider: any ProcessSnapshotProviding = LibprocSnapshotProvider()
    ) {
        self.storeURL = storeURL
        self.activeAuthURL = activeAuthURL
        self.processProvider = processProvider
    }

    public func inspect() async throws -> InspectionReport {
        let descriptor: CodexAppDescriptor?
        let applicationStatus: ApplicationInspectionStatus
        do {
            descriptor = try await MainActor.run {
                try CodexAppLocator().locate()
            }
            applicationStatus = .ready
        } catch CodexAppLocatorFailure.notFound {
            descriptor = nil
            applicationStatus = .notFound
        } catch {
            descriptor = nil
            applicationStatus = .incompatible
        }

        let records = try processProvider.snapshot()
        let runningPIDs: Set<Int32>
        if let descriptor {
            runningPIDs = try await MainActor.run {
                Set(try CodexAppLifecycle().runningApplicationPIDs(for: descriptor))
            }
        } else {
            runningPIDs = []
        }
        let roots = Set(records.filter { runningPIDs.contains($0.identity.pid) }.map(\.identity))
        let context = ProcessClassificationContext(
            bundleRootPath: descriptor?.bundleURL.path ?? "/__codex_app_not_found__",
            mainExecutablePath: descriptor?.mainExecutableURL.path ?? "/__codex_main_not_found__",
            bundledCodexPath: descriptor?.bundledCodexURL.path ?? "/__codex_cli_not_found__",
            appRootIdentities: roots,
            helperOwnedIdentities: [],
            approvedResidents: []
        )
        let inventory = ProcessClassifier.classify(records, context: context)

        return InspectionReport(
            applicationStatus: applicationStatus,
            version: descriptor?.version,
            build: descriptor?.build,
            authStatus: inspectAuthStatus(),
            appOwnedProcessCount: count(.appOwnedBlocker, in: inventory),
            independentCodexProcessCount: count(.independentCodexBlocker, in: inventory),
            unclassifiedRelevantProcessCount: count(.unclassifiedRelevant, in: inventory)
        )
    }

    public func profiles() async throws -> [ProfileListItem] {
        guard let store = try openStoreIfPresent(),
              let registry = try store.loadRegistryIfPresent() else {
            return []
        }
        return registry.profiles.map { profile in
            ProfileListItem(
                id: profile.id,
                label: profile.label,
                email: profile.email,
                active: registry.activeProfileID == profile.id,
                needsRelogin: profile.needsRelogin
            )
        }
    }

    public func recoveryStatus() async throws -> RecoveryCLIStatus {
        do {
            guard let store = try openStoreIfPresent(),
                  let journal = try store.loadJournalIfPresent() else {
                return .none
            }
            return .pending(
                transactionID: journal.transactionID.uuidString,
                phase: journal.phase
            )
        } catch {
            return .blocked
        }
    }
}

private extension LocalReadOnlyCLIDataProvider {
    func inspectAuthStatus() -> AuthInspectionStatus {
        let parent = activeAuthURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            return .absent
        }
        do {
            switch try files.snapshot(at: activeAuthURL) {
            case .absent:
                return .absent
            case .exact:
                return .privateRegularFile
            }
        } catch {
            return .unsafe
        }
    }

    func openStoreIfPresent() throws -> SpikeStore? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }
        return try SpikeStore.openExisting(at: storeURL)
    }

    func count(_ disposition: ProcessDisposition, in inventory: ProcessInventory) -> Int {
        inventory.processes.lazy.filter { $0.disposition == disposition }.count
    }
}
