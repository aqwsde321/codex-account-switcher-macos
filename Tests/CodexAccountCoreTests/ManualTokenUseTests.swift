import CodexAccountCore
import Foundation

func manualTokenUseTests() -> [TestCase] {
    [
        TestCase("manual token use isolates auth and requires an OK response") {
            try await withTokenUseTemporaryDirectory { directory in
                let fixture = try makeTokenUseFixture(in: directory)
                let provider = LocalCLIDataProvider(
                    storeURL: fixture.storeURL,
                    activeAuthURL: fixture.activeAuthURL,
                    processProvider: EmptyProcessSnapshotProvider(),
                    locateApp: { fixture.descriptor },
                    runningApplicationPIDs: { _ in [] }
                )

                try await provider.useToken(profileID: fixture.target.id)

                let tokenHome = fixture.storeURL.appendingPathComponent(
                    "token-use-home",
                    isDirectory: true
                )
                let isolatedAuth = try String(
                    contentsOf: tokenHome.appendingPathComponent("auth.json"),
                    encoding: .utf8
                )
                let invocation = try String(contentsOf: fixture.invocationURL, encoding: .utf8)
                let activeAuthAfterSuccess = try Data(contentsOf: fixture.activeAuthURL)
                let storedTargetAfterSuccess = try SpikeStore.openExisting(at: fixture.storeURL)
                    .loadCredential(for: fixture.target.id)
                try expect(
                    activeAuthAfterSuccess == fixture.activeAuthData,
                    "manual token use changed shared active auth"
                )
                try expect(
                    storedTargetAfterSuccess == fixture.targetCredential,
                    "manual token use changed the stored account credential"
                )
                try expect(
                    isolatedAuth.contains(#""test_account":"b""#)
                        && isolatedAuth.contains(#""auth_mode":"chatgptAuthTokens""#)
                        && isolatedAuth.contains(#""refresh_token":"""#),
                    "manual token use exposed the refresh token or selected the wrong account"
                )
                try expect(
                    invocation.contains("CODEX_HOME=\(tokenHome.path)")
                        && invocation.contains("--ephemeral")
                        && invocation.contains("--output-last-message"),
                    "manual token use did not invoke isolated ephemeral exec"
                )

                try Data("NO\n".utf8).write(to: fixture.responseURL, options: .atomic)
                do {
                    try await provider.useToken(profileID: fixture.target.id)
                    throw TestFailure(description: "manual token use accepted a non-OK response")
                } catch let failure as LocalCLIDataProviderFailure {
                    try expect(
                        failure == .unexpectedTokenUseResponse,
                        "manual token use returned the wrong non-OK failure: \(failure)"
                    )
                }
                let activeAuthAfterFailure = try Data(contentsOf: fixture.activeAuthURL)
                try expect(
                    activeAuthAfterFailure == fixture.activeAuthData,
                    "failed manual token use changed shared active auth"
                )
            }
        },
    ]
}

private struct EmptyProcessSnapshotProvider: ProcessSnapshotProviding {
    func snapshot() throws -> [ProcessRecord] { [] }
}

private struct TokenUseFixture {
    let storeURL: URL
    let activeAuthURL: URL
    let activeAuthData: Data
    let target: ProfileMetadata
    let targetCredential: CredentialBlob
    let responseURL: URL
    let invocationURL: URL
    let descriptor: CodexAppDescriptor
}

private func makeTokenUseFixture(in directory: URL) throws -> TokenUseFixture {
    let activeHome = directory.appendingPathComponent("active-home", isDirectory: true)
    try FileManager.default.createDirectory(at: activeHome, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: activeHome.path)
    let activeAuthURL = activeHome.appendingPathComponent("auth.json")
    let activeAuthData = Data(
        #"{"auth_mode":"chatgpt","test_account":"a","tokens":{"id_token":"a-id","access_token":"a-access","refresh_token":"a-refresh"}}"#.utf8
    )
    try activeAuthData.write(to: activeAuthURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeAuthURL.path)

    let storeURL = directory.appendingPathComponent("store", isDirectory: true)
    let store = try SpikeStore.create(at: storeURL)
    let source = ProfileMetadata(
        id: ProfileID(UUID()),
        label: "A",
        email: "a@example.invalid",
        planType: "plus",
        needsRelogin: false,
        createdAt: .now,
        updatedAt: .now
    )
    let target = ProfileMetadata(
        id: ProfileID(UUID()),
        label: "B",
        email: "b@example.invalid",
        planType: "plus",
        needsRelogin: false,
        createdAt: .now,
        updatedAt: .now
    )
    let sourceCredential = try CredentialBlob(validating: activeAuthData)
    let targetCredential = try CredentialBlob(validating: Data(
        #"{"auth_mode":"chatgpt","test_account":"b","tokens":{"id_token":"b-id","access_token":"b-access","refresh_token":"b-refresh"}}"#.utf8
    ))
    _ = try store.saveCredential(sourceCredential, for: source.id)
    _ = try store.saveCredential(targetCredential, for: target.id)
    _ = try store.saveRegistry(ProfileRegistry(activeProfileID: source.id, profiles: [source, target]))

    let responseURL = directory.appendingPathComponent("response.txt")
    let invocationURL = directory.appendingPathComponent("invocation.txt")
    try Data("OK\n".utf8).write(to: responseURL, options: .withoutOverwriting)
    let executableURL = directory.appendingPathComponent("fake-codex")
    let script = #"""
    #!/bin/zsh
    print -r -- "CODEX_HOME=$CODEX_HOME ARGS=$*" > "\#(invocationURL.path)"
    output=''
    previous=''
    for argument in "$@"; do
      if [[ "$previous" == '--output-last-message' ]]; then
        output="$argument"
        break
      fi
      previous="$argument"
    done
    [[ -n "$output" ]] || exit 20
    cp "\#(responseURL.path)" "$output"
    """#
    try Data(script.utf8).write(to: executableURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

    let bundleURL = directory.appendingPathComponent("Codex.app", isDirectory: true)
    let descriptor = CodexAppDescriptor(
        bundleURL: bundleURL,
        mainExecutableURL: bundleURL.appendingPathComponent("Contents/MacOS/Codex"),
        bundledCodexURL: executableURL,
        bundleIdentifier: "com.openai.codex",
        version: "1",
        build: "1",
        appSigningIdentifier: "com.openai.codex",
        bundledCodexSigningIdentifier: "codex",
        teamIdentifier: "2DC432GLL2"
    )
    return TokenUseFixture(
        storeURL: storeURL,
        activeAuthURL: activeAuthURL,
        activeAuthData: activeAuthData,
        target: target,
        targetCredential: targetCredential,
        responseURL: responseURL,
        invocationURL: invocationURL,
        descriptor: descriptor
    )
}

private func withTokenUseTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-token-use-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}
