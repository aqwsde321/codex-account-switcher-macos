import Darwin
import Foundation
import CodexAccountCore

func durableFileTests() -> [TestCase] {
    [
        TestCase("SensitiveBytes dump never exposes bytes") {
            let canary = "sensitive-bytes-canary"
            let bytes = SensitiveBytes(Data(canary.utf8))
            var dumpOutput = ""

            dump(bytes, to: &dumpOutput)

            try expect(!dumpOutput.contains(canary), "dump exposed sensitive bytes")
            try expect(String(reflecting: bytes) == "<redacted bytes>", "reflection was not redacted")
            try expect(Mirror(reflecting: bytes).children.isEmpty, "mirror exposed sensitive storage")
        },
        TestCase("DarwinDurableFileOperations atomically replaces a private file") {
            try withTemporaryDirectory { directory in
                let destination = directory.appendingPathComponent("state.json")
                let operations = DarwinDurableFileOperations()
                let initial = try operations.snapshot(at: destination)

                try expect(initial == .absent, "new destination was not absent")

                let firstIdentity = try operations.replace(
                    contents: SensitiveBytes(Data("first".utf8)),
                    at: destination,
                    expecting: initial
                )
                let firstMode = try fileMode(at: destination)
                let firstData = try Data(contentsOf: destination)

                try expect(firstData == Data("first".utf8), "first bytes differ")
                try expect(firstMode == 0o600, "destination mode is not 0600")

                let secondIdentity = try operations.replace(
                    contents: SensitiveBytes(Data("second".utf8)),
                    at: destination,
                    expecting: .exact(firstIdentity)
                )
                let secondData = try Data(contentsOf: destination)
                let finalSnapshot = try operations.snapshot(at: destination)

                try expect(secondData == Data("second".utf8), "second bytes differ")
                try expect(secondIdentity != firstIdentity, "file identity did not change")
                try expect(finalSnapshot == .exact(secondIdentity), "snapshot differs")
            }
        },
        TestCase("DarwinDurableFileOperations durably removes and confirms absence") {
            try withTemporaryDirectory { directory in
                let destination = directory.appendingPathComponent("journal.json")
                let operations = DarwinDurableFileOperations()
                let identity = try operations.replace(
                    contents: SensitiveBytes(Data("journal".utf8)),
                    at: destination,
                    expecting: .absent
                )

                let removed = try operations.remove(at: destination, expecting: .exact(identity))
                let absent = try operations.remove(at: destination, expecting: .absent)

                try expect(removed == .removed, "existing file was not removed")
                try expect(absent == .alreadyAbsent, "absence was not confirmed")
                try expect(!FileManager.default.fileExists(atPath: destination.path), "file remains after removal")
            }
        },
        TestCase("DarwinDurableFileOperations rejects oversized reads before allocation") {
            try withTemporaryDirectory { directory in
                let destination = directory.appendingPathComponent("oversized.json")
                try Data(repeating: 0x41, count: 33).write(to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

                do {
                    _ = try DarwinDurableFileOperations().read(at: destination, maximumBytes: 32)
                    throw TestFailure(description: "oversized file was read")
                } catch let failure as DurableFileFailure {
                    try expect(failure.errno == EFBIG, "oversized read returned the wrong errno")
                    try expect(failure.certainty == .destinationUnchanged, "oversized read changed certainty")
                }
            }
        },
        TestCase("ExclusiveFileLock allows only one owner and uses close-on-exec") {
            try withTemporaryDirectory { directory in
                let lockURL = directory.appendingPathComponent("switch.lock")
                let first = try ExclusiveFileLock.tryAcquire(at: lockURL)
                let competing = try ExclusiveFileLock.tryAcquire(at: lockURL)

                try expect(first != nil, "first lock acquisition failed")
                try expect(first?.closeOnExecConfigured == true, "lock FD lacks close-on-exec")
                try expect(competing == nil, "competing lock acquisition succeeded")

                first?.release()
                let afterRelease = try ExclusiveFileLock.tryAcquire(at: lockURL)
                try expect(afterRelease != nil, "lock stayed busy after release")
                afterRelease?.release()
            }
        },
        TestCase("Durable files allow an owner-controlled non-writable 0755 parent") {
            try withTemporaryDirectory { directory in
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
                let destination = directory.appendingPathComponent("auth.json")
                let operations = DarwinDurableFileOperations()

                _ = try operations.replace(
                    contents: SensitiveBytes(Data("fixture".utf8)),
                    at: destination,
                    expecting: .absent
                )
                let mode = try fileMode(at: destination)

                try expect(mode == 0o600, "file mode changed under 0755 parent")
            }
        },
        TestCase("Durable files reject symbolic-link destinations") {
            try withTemporaryDirectory { directory in
                let real = directory.appendingPathComponent("real.json")
                let link = directory.appendingPathComponent("auth.json")
                try Data("fixture".utf8).write(to: real)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

                do {
                    _ = try DarwinDurableFileOperations().snapshot(at: link)
                    throw TestFailure(description: "symbolic-link destination was accepted")
                } catch let failure as DurableFileFailure {
                    try expect(failure.stage == .inspect, "symbolic-link rejection occurred at the wrong stage")
                }
            }
        },
        TestCase("Durable files reject group-writable parent directories") {
            try withTemporaryDirectory { directory in
                try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: directory.path)
                let destination = directory.appendingPathComponent("auth.json")

                do {
                    _ = try DarwinDurableFileOperations().snapshot(at: destination)
                    throw TestFailure(description: "group-writable parent was accepted")
                } catch let failure as DurableFileFailure {
                    try expect(failure.stage == .openParent, "unsafe parent rejection occurred at the wrong stage")
                }
            }
        },
        TestCase("File fsync failure preserves the previous destination") {
            try withTemporaryDirectory { directory in
                let destination = directory.appendingPathComponent("auth.json")
                let normal = DarwinDurableFileOperations()
                let original = try normal.replace(
                    contents: SensitiveBytes(Data("previous".utf8)),
                    at: destination,
                    expecting: .absent
                )
                let failing = DarwinDurableFileOperations(
                    fault: DurableFaultInjection(mutation: .replace, stage: .syncFile)
                )

                do {
                    _ = try failing.replace(
                        contents: SensitiveBytes(Data("target".utf8)),
                        at: destination,
                        expecting: .exact(original)
                    )
                    throw TestFailure(description: "file fsync fault returned success")
                } catch let failure as DurableFileFailure {
                    try expect(failure.certainty == .destinationUnchanged, "fsync failure certainty changed")
                }

                let data = try Data(contentsOf: destination)
                try expect(data == Data("previous".utf8), "previous destination was damaged")
            }
        },
        TestCase("Parent fsync failure reports durability unknown after visible replace") {
            try withTemporaryDirectory { directory in
                let destination = directory.appendingPathComponent("auth.json")
                let failing = DarwinDurableFileOperations(
                    fault: DurableFaultInjection(mutation: .replace, stage: .syncParent)
                )

                do {
                    _ = try failing.replace(
                        contents: SensitiveBytes(Data("target".utf8)),
                        at: destination,
                        expecting: .absent
                    )
                    throw TestFailure(description: "parent fsync fault returned success")
                } catch let failure as DurableFileFailure {
                    try expect(failure.certainty == .durabilityUnknown, "parent fsync was not unknown")
                }

                let data = try Data(contentsOf: destination)
                try expect(data == Data("target".utf8), "renamed destination is not visible")
            }
        },
        TestCase("Journal unlink parent fsync failure never reports completion") {
            try withTemporaryDirectory { directory in
                let destination = directory.appendingPathComponent("journal.json")
                let normal = DarwinDurableFileOperations()
                let identity = try normal.replace(
                    contents: SensitiveBytes(Data("journal".utf8)),
                    at: destination,
                    expecting: .absent
                )
                let failing = DarwinDurableFileOperations(
                    fault: DurableFaultInjection(mutation: .remove, stage: .syncParent)
                )

                do {
                    _ = try failing.remove(at: destination, expecting: .exact(identity))
                    throw TestFailure(description: "unlink parent fsync fault returned completion")
                } catch let failure as DurableFileFailure {
                    try expect(failure.certainty == .durabilityUnknown, "unlink durability was guessed")
                }
                try expect(!FileManager.default.fileExists(atPath: destination.path), "unlink was not visible")
            }
        },
    ]
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-account-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func fileMode(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
