import CodexAccountCore

func safeRendererTests() -> [TestCase] {
    [
        TestCase("SafeEmailMasker reveals no local or domain text") {
            let email = "sensitive.person@private-company.example"
            let rendered = SafeEmailMasker.mask(email)

            try expect(rendered == "<email-redacted>", "unexpected masked representation")
            try expect(!rendered.contains("sensitive.person"), "local part leaked")
            try expect(!rendered.contains("private-company.example"), "domain leaked")
        },
    ]
}
