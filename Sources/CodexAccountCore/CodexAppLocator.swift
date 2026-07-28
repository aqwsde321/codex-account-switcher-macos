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
    public static let officialBundleIdentifier = "com.openai.codex"
    public static let observedOfficialTeamIdentifier = "2DC432GLL2"

    public init() {}

    public func locate() throws -> CodexAppDescriptor {
        var candidates = NSWorkspace.shared.urlsForApplications(
            withBundleIdentifier: Self.officialBundleIdentifier
        )
        let fallback = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: fallback.path) {
            candidates.append(fallback)
        }

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
        guard isExecutableRegularFile(mainExecutableURL),
              isExecutableRegularFile(bundledCodexURL),
              isInside(mainExecutableURL, root: bundleURL),
              isInside(bundledCodexURL, root: bundleURL) else {
            throw CodexAppLocatorFailure.invalidExecutable
        }

        let appSignature = try signature(of: bundleURL)
        let codexSignature = try signature(of: bundledCodexURL)
        guard appSignature.identifier == Self.officialBundleIdentifier,
              codexSignature.identifier == "codex" else {
            throw CodexAppLocatorFailure.invalidSignature
        }
        guard appSignature.teamIdentifier == Self.observedOfficialTeamIdentifier,
              codexSignature.teamIdentifier == appSignature.teamIdentifier else {
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
