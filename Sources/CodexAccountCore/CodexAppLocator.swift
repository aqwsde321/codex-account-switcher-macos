import AppKit
import Foundation
import Security

public struct CodexAppDescriptor: Equatable, Sendable {
    public let bundleURL: URL
    public let mainExecutableURL: URL
    public let bundledCodexURL: URL
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let appSigningIdentifier: String
    public let bundledCodexSigningIdentifier: String
    public let crashpadExecutableURL: URL
    public let crashpadSigningIdentifier: String
    public let teamIdentifier: String

    public init(
        bundleURL: URL,
        mainExecutableURL: URL,
        bundledCodexURL: URL,
        bundleIdentifier: String,
        version: String,
        build: String,
        appSigningIdentifier: String,
        bundledCodexSigningIdentifier: String,
        crashpadExecutableURL: URL? = nil,
        crashpadSigningIdentifier: String = "browser_crashpad_handler",
        teamIdentifier: String
    ) {
        self.bundleURL = bundleURL
        self.mainExecutableURL = mainExecutableURL
        self.bundledCodexURL = bundledCodexURL
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.appSigningIdentifier = appSigningIdentifier
        self.bundledCodexSigningIdentifier = bundledCodexSigningIdentifier
        self.crashpadExecutableURL = crashpadExecutableURL ?? bundleURL
            .appendingPathComponent(
                "Contents/Frameworks/Codex Framework.framework/Versions/Current/Helpers/browser_crashpad_handler"
            )
            .resolvingSymlinksInPath()
            .standardizedFileURL
        self.crashpadSigningIdentifier = crashpadSigningIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public enum CodexAppLocatorFailure: Error, Equatable, Sendable {
    case notFound
    case ambiguousInstallations
    case invalidBundle
    case invalidExecutable
    case invalidSignature
    case unexpectedSigner
}

@MainActor
public struct CodexAppLocator {
    nonisolated public static let officialBundleIdentifier = "com.openai.codex"
    nonisolated public static let observedOfficialTeamIdentifier = "2DC432GLL2"

    public init() {}

    public func locate() throws -> CodexAppDescriptor {
        let candidates = Self.candidateURLs(
            discovered: NSWorkspace.shared.urlsForApplications(
                withBundleIdentifier: Self.officialBundleIdentifier
            ),
            fileExists: FileManager.default.fileExists(atPath:)
        )

        let unique = Dictionary(grouping: candidates.map(canonicalURL), by: \.path)
            .compactMap(\.value.first)
        guard !unique.isEmpty else {
            throw CodexAppLocatorFailure.notFound
        }

        let descriptors = unique.compactMap { try? inspect($0) }
        guard !descriptors.isEmpty else {
            throw CodexAppLocatorFailure.invalidBundle
        }
        guard descriptors.count == 1 else {
            throw CodexAppLocatorFailure.ambiguousInstallations
        }
        return descriptors[0]
    }

    nonisolated package static func candidateURLs(
        discovered: [URL],
        fileExists: (String) -> Bool
    ) -> [URL] {
        discovered + ["/Applications/ChatGPT.app", "/Applications/Codex.app"].compactMap { path in
            fileExists(path) ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
    }
}

private extension CodexAppLocator {
    func inspect(_ bundleURL: URL) throws -> CodexAppDescriptor {
        guard let bundle = Bundle(url: bundleURL),
              bundle.bundleIdentifier == Self.officialBundleIdentifier,
              let mainExecutableURL = bundle.executableURL,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw CodexAppLocatorFailure.invalidBundle
        }
        let bundledCodexURL = bundleURL
            .appendingPathComponent("Contents/Resources/codex", isDirectory: false)
        let crashpadExecutableURL = canonicalURL(
            bundleURL.appendingPathComponent(
                "Contents/Frameworks/Codex Framework.framework/Versions/Current/Helpers/browser_crashpad_handler"
            )
        )
        guard isExecutableRegularFile(mainExecutableURL),
              isExecutableRegularFile(bundledCodexURL),
              isExecutableRegularFile(crashpadExecutableURL),
              isInside(mainExecutableURL, root: bundleURL),
              isInside(bundledCodexURL, root: bundleURL),
              isInside(crashpadExecutableURL, root: bundleURL) else {
            throw CodexAppLocatorFailure.invalidExecutable
        }

        let appSignature = try signature(of: bundleURL)
        let codexSignature = try signature(of: bundledCodexURL)
        let crashpadSignature = try signature(of: crashpadExecutableURL)
        guard appSignature.identifier == Self.officialBundleIdentifier,
              codexSignature.identifier == "codex",
              crashpadSignature.identifier == "browser_crashpad_handler" else {
            throw CodexAppLocatorFailure.invalidSignature
        }
        guard appSignature.teamIdentifier == Self.observedOfficialTeamIdentifier,
              codexSignature.teamIdentifier == appSignature.teamIdentifier,
              crashpadSignature.teamIdentifier == appSignature.teamIdentifier else {
            throw CodexAppLocatorFailure.unexpectedSigner
        }

        return CodexAppDescriptor(
            bundleURL: canonicalURL(bundleURL),
            mainExecutableURL: canonicalURL(mainExecutableURL),
            bundledCodexURL: canonicalURL(bundledCodexURL),
            bundleIdentifier: Self.officialBundleIdentifier,
            version: version,
            build: build,
            appSigningIdentifier: appSignature.identifier,
            bundledCodexSigningIdentifier: codexSignature.identifier,
            crashpadExecutableURL: crashpadExecutableURL,
            crashpadSigningIdentifier: crashpadSignature.identifier,
            teamIdentifier: appSignature.teamIdentifier
        )
    }

    func signature(of url: URL) throws -> (identifier: String, teamIdentifier: String) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else {
            throw CodexAppLocatorFailure.invalidSignature
        }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            throw CodexAppLocatorFailure.invalidSignature
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw CodexAppLocatorFailure.invalidSignature
        }
        return (identifier, teamIdentifier)
    }

    func isExecutableRegularFile(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func isInside(_ url: URL, root: URL) -> Bool {
        let components = canonicalURL(url).pathComponents
        let rootComponents = canonicalURL(root).pathComponents
        guard components.count >= rootComponents.count else { return false }
        return Array(components.prefix(rootComponents.count)) == rootComponents
    }

    func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
