import Foundation
@testable import CodexAccountCore

func credentialBlobTests() -> [TestCase] {
    [
        TestCase("CredentialBlob accepts a managed ChatGPT fixture") {
        let data = Data(
            #"{"auth_mode":"chatgpt","tokens":{"id_token":"fake-id","access_token":"fake-access","refresh_token":"fake-refresh","account_id":"fake-account"},"last_refresh":"2026-07-28T00:00:00Z"}"#.utf8
        )

        let credential = try CredentialBlob(validating: data)

        try expect(credential.byteCount == data.count, "credential byte count changed")
        },
        TestCase("CredentialBlob creates a refresh-disabled probe copy") {
            let data = Data(
                #"{"auth_mode":"chatgpt","tokens":{"id_token":"fake-id","access_token":"fake-access","refresh_token":"fake-refresh","account_id":"fake-account"},"last_refresh":"2026-07-28T00:00:00Z"}"#.utf8
            )
            let credential = try CredentialBlob(validating: data)

            let probe = try JSONSerialization.jsonObject(
                with: CredentialBlob.usageProbeData(for: credential)
            ) as? [String: Any]
            let tokens = probe?["tokens"] as? [String: Any]

            try expect(
                probe?["auth_mode"] as? String == "chatgptAuthTokens",
                "probe mode can refresh"
            )
            try expect(tokens?["refresh_token"] as? String == "", "probe copy retained refresh token")
            try expect(tokens?["id_token"] as? String == "fake-id", "probe copy lost id token")
            try expect(
                tokens?["access_token"] as? String == "fake-access",
                "probe copy lost access token"
            )
            try expect(
                CredentialBlob.persistenceData(for: credential) == data,
                "probe copy changed stored credential"
            )
        },
        TestCase("CredentialBlob rejects duplicate JSON keys") {
            let data = Data(
                #"{"auth_mode":"chatgpt","auth_mode":"chatgpt","tokens":{"id_token":"id","access_token":"access","refresh_token":"refresh"}}"#.utf8
            )

            try expectError(CredentialBlobError.invalidJSON, "duplicate credential key was accepted") {
                _ = try CredentialBlob(validating: data)
            }
        },
        TestCase("CredentialBlob descriptions never expose bytes") {
            let canary = "credential-secret-canary"
            let payload =
                "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"id_token\":\"id\","
                    + "\"access_token\":\"\(canary)\",\"refresh_token\":\"refresh\"}}"
            let data = Data(payload.utf8)
            let credential = try CredentialBlob(validating: data)
            var dumpOutput = ""
            dump(credential, to: &dumpOutput)

            try expect(String(describing: credential) == "<redacted credential>", "description is not redacted")
            try expect(!String(reflecting: credential).contains(canary), "debug description exposed bytes")
            try expect(!dumpOutput.contains(canary), "dump exposed credential bytes")
            try expect(Mirror(reflecting: credential).children.isEmpty, "mirror exposed credential storage")
        },
    ]
}
