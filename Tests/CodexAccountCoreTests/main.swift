import Darwin

let tests = credentialBlobTests() + profileRegistryTests() + registryCodecTests()
    + sleepGuardPolicyTests()
    + credentialStoreTests()
    + journalCodecTests() + switchStateMachineTests() + durableFileTests()
    + spikeStoreTests() + appServerProtocolTests() + codexLoginSessionTests()
    + processClassifierTests()
    + targetCredentialValidatorTests() + recoveryPlannerTests()
    + recoveryCoordinatorTests() + switchCoordinatorTests()
    + profileCaptureCoordinatorTests() + profileRemovalTests()
    + cliApplicationTests() + menuBarViewModelTests()
    + safeRendererTests()
var failureCount = 0

for test in tests {
    do {
        try await test.body()
        print("PASS \(test.name)")
    } catch {
        failureCount += 1
        print("FAIL \(test.name): \(error)")
    }
}

guard failureCount == 0 else {
    exit(1)
}

print("PASS \(tests.count) tests")
