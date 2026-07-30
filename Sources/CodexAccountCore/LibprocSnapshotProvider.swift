import Darwin
import Foundation
import Security

public protocol ProcessSnapshotProviding: Sendable {
    func snapshot() throws -> [ProcessRecord]
}

public enum ProcessSnapshotFailure: Error, Equatable, Sendable {
    case listFailed(errno: Int32)
    case capacityExceeded
}

public struct LibprocSnapshotProvider: ProcessSnapshotProviding {
    public init() {}

    public func snapshot() throws -> [ProcessRecord] {
        let processIDs = try listProcessIDs()
        return processIDs.compactMap(readRecord).sorted {
            if $0.identity.pid != $1.identity.pid {
                return $0.identity.pid < $1.identity.pid
            }
            if $0.identity.startSeconds != $1.identity.startSeconds {
                return $0.identity.startSeconds < $1.identity.startSeconds
            }
            return $0.identity.startMicroseconds < $1.identity.startMicroseconds
        }
    }
}

private extension LibprocSnapshotProvider {
    func listProcessIDs() throws -> [pid_t] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated >= 0 else {
            throw ProcessSnapshotFailure.listFailed(errno: errno)
        }
        var capacity = max(Int(estimated) + 64, 128)

        for _ in 0..<4 {
            guard capacity <= Int(Int32.max) / MemoryLayout<pid_t>.stride else {
                throw ProcessSnapshotFailure.capacityExceeded
            }
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let count = processIDs.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else {
                throw ProcessSnapshotFailure.listFailed(errno: errno)
            }
            if Int(count) < capacity {
                return Array(processIDs.prefix(Int(count))).filter { $0 > 0 }
            }
            capacity *= 2
        }
        throw ProcessSnapshotFailure.capacityExceeded
    }

    func readRecord(pid: pid_t) -> ProcessRecord? {
        var information = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let readSize = withUnsafeMutablePointer(to: &information) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard readSize == Int32(expectedSize) else {
            return nil
        }

        let executablePath = processPath(pid: pid)
        let name = processName(pid: pid)
        let signature = name == "browser_crashpad_handler" ? processSignature(pid: pid) : nil

        return ProcessRecord(
            identity: ProcessIdentity(
                pid: pid,
                startSeconds: information.pbi_start_tvsec,
                startMicroseconds: information.pbi_start_tvusec
            ),
            parentPID: pid_t(bitPattern: information.pbi_ppid),
            executablePath: executablePath,
            nameHint: name,
            signingIdentifier: signature?.identifier,
            teamIdentifier: signature?.teamIdentifier
        )
    }

    func processSignature(pid: pid_t) -> (identifier: String, teamIdentifier: String)? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        var requirement: SecRequirement?
        let requirementText = """
        identifier "browser_crashpad_handler" and anchor apple generic and \
        certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
        certificate leaf[subject.OU] = "2DC432GLL2"
        """
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            return nil
        }
        return ("browser_crashpad_handler", "2DC432GLL2")
    }

    func processPath(pid: pid_t) -> String? {
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard count > 0 else { return nil }
        return decodeCString(bytes)
    }

    func processName(pid: pid_t) -> String? {
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBytes { buffer in
            proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard count > 0 else { return nil }
        return decodeCString(bytes)
    }

    func decodeCString(_ bytes: [UInt8]) -> String? {
        let content = bytes.prefix { $0 != 0 }
        guard !content.isEmpty else { return nil }
        return String(bytes: content, encoding: .utf8)
    }
}
