import Darwin
import Foundation
import Security

@_silgen_name("csops")
private func codexCSOps(
    _ pid: pid_t,
    _ operation: UInt32,
    _ address: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int32

public protocol ProcessSnapshotProviding: Sendable {
    func snapshot() throws -> [ProcessRecord]
}

public enum ProcessSnapshotFailure: Error, Equatable, Sendable {
    case listFailed(errno: Int32)
    case capacityExceeded
    case processChanged
}

public struct LibprocSnapshotProvider: ProcessSnapshotProviding {
    public init() {}

    package static func isTrustedKernelCrashpadSignature(
        flags: UInt32,
        validationCategory: UInt32,
        identity: String?,
        teamIdentifier: String?
    ) -> Bool {
        let requiredFlags: UInt32 = 0x20010001 // CS_SIGNED | CS_RUNTIME | CS_VALID
        let rejectedFlags: UInt32 = 0x10000002 // CS_DEBUGGED | CS_ADHOC
        return flags & requiredFlags == requiredFlags
            && flags & rejectedFlags == 0
            && validationCategory == 6 // CS_VALIDATION_CATEGORY_DEVELOPER_ID
            && identity == "browser_crashpad_handler"
            && teamIdentifier == "2DC432GLL2"
    }

    package static func decodeCodeSigningText(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 9 else { return nil }
        let totalLength = bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard totalLength > 8, totalLength <= bytes.count else { return nil }
        let payload = bytes[8..<Int(totalLength)]
        guard payload.last == 0,
              !payload.dropLast().isEmpty,
              !payload.dropLast().contains(0) else {
            return nil
        }
        return String(bytes: payload.dropLast(), encoding: .utf8)
    }

    public func snapshot() throws -> [ProcessRecord] {
        let processIDs = try listProcessIDs()
        return try processIDs.compactMap { try readRecord(pid: $0) }.sorted {
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

    func readRecord(pid: pid_t) throws -> ProcessRecord? {
        guard let information = processInformation(pid: pid) else { return nil }
        let executablePath = processPath(pid: pid)
        let name = processName(pid: pid)
        let signature = name == "browser_crashpad_handler" ? processSignature(pid: pid) : nil
        guard let confirmed = processInformation(pid: pid) else { return nil }
        guard confirmed.pbi_start_tvsec == information.pbi_start_tvsec,
              confirmed.pbi_start_tvusec == information.pbi_start_tvusec,
              confirmed.pbi_ppid == information.pbi_ppid,
              processName(pid: pid) == name else {
            throw ProcessSnapshotFailure.processChanged
        }

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

    func processInformation(pid: pid_t) -> proc_bsdinfo? {
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
        return information
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
        if SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
           let requirement,
           SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
           let code,
           SecCodeCheckValidity(code, [], requirement) == errSecSuccess {
            return ("browser_crashpad_handler", "2DC432GLL2")
        }
        return kernelProcessSignature(pid: pid)
    }

    func kernelProcessSignature(pid: pid_t) -> (identifier: String, teamIdentifier: String)? {
        var flags: UInt32 = 0
        var validationCategory: UInt32 = 0
        guard withUnsafeMutableBytes(of: &flags, {
            codexCSOps(pid, 0, $0.baseAddress, $0.count) // CS_OPS_STATUS
        }) == 0,
        withUnsafeMutableBytes(of: &validationCategory, {
            codexCSOps(pid, 17, $0.baseAddress, $0.count) // CS_OPS_VALIDATION_CATEGORY
        }) == 0 else {
            return nil
        }
        let identity = codeSigningText(pid: pid, operation: 11) // CS_OPS_IDENTITY
        let teamIdentifier = codeSigningText(pid: pid, operation: 14) // CS_OPS_TEAMID
        guard Self.isTrustedKernelCrashpadSignature(
            flags: flags,
            validationCategory: validationCategory,
            identity: identity,
            teamIdentifier: teamIdentifier
        ) else {
            return nil
        }
        return ("browser_crashpad_handler", "2DC432GLL2")
    }

    func codeSigningText(pid: pid_t, operation: UInt32) -> String? {
        var bytes = [UInt8](repeating: 0, count: 256)
        guard bytes.withUnsafeMutableBytes({
            codexCSOps(pid, operation, $0.baseAddress, $0.count)
        }) == 0 else {
            return nil
        }
        return Self.decodeCodeSigningText(bytes)
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
