import Foundation

public enum AppServerAccountRead: Equatable, Sendable {
    case signedOut(requiresOpenAIAuth: Bool)
    case chatGPT(email: String?, planType: String?, requiresOpenAIAuth: Bool)
}

public struct AppServerRateLimitWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMinutes: Int
    public let resetsAt: Date?

    public init(usedPercent: Double, windowDurationMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct AppServerRateLimitsRead: Equatable, Sendable {
    public let planType: String?
    public let windows: [AppServerRateLimitWindow]

    public init(planType: String?, windows: [AppServerRateLimitWindow]) {
        self.planType = planType
        self.windows = windows
    }
}

public struct AppServerAccountUsageRead: Equatable, Sendable {
    public let account: AppServerAccountRead
    public let rateLimits: AppServerRateLimitsRead

    public init(account: AppServerAccountRead, rateLimits: AppServerRateLimitsRead) {
        self.account = account
        self.rateLimits = rateLimits
    }
}

public enum AccountIdentityError: Error, Equatable, Sendable {
    case invalidExpectedEmail
    case signedOut
    case missingEmail
    case emailMismatch
}

public enum AccountIdentityValidator {
    public static func validate(
        expectedEmail: String,
        account: AppServerAccountRead
    ) throws {
        guard !expectedEmail.isEmpty else {
            throw AccountIdentityError.invalidExpectedEmail
        }
        switch account {
        case .signedOut:
            throw AccountIdentityError.signedOut
        case let .chatGPT(email, _, _):
            guard let email else {
                throw AccountIdentityError.missingEmail
            }
            guard email == expectedEmail else {
                throw AccountIdentityError.emailMismatch
            }
        }
    }
}

public enum AppServerProtocolFailureCode: Equatable, Sendable {
    case alreadyStarted
    case frameTooLarge
    case malformedFrame
    case protocolViolation
    case rpcError
    case unsupportedAccountType
    case unexpectedEOF
}

public struct AppServerProtocolFailure: Error, Equatable, Sendable {
    public let code: AppServerProtocolFailureCode
    public let rpcCode: Int?

    public init(code: AppServerProtocolFailureCode, rpcCode: Int? = nil) {
        self.code = code
        self.rpcCode = rpcCode
    }
}

public struct AppServerProtocolMachine {
    private enum State {
        case idle
        case awaitingInitialize
        case awaitingAccount
        case awaitingRateLimits
        case accountReceived
    }

    private static let initializeID = 1
    private static let accountID = 2
    private static let rateLimitsID = 3
    private static let maximumBufferedBytes = 1_048_576
    private static let maximumFrameBytes = 262_144

    private var state = State.idle
    private var buffer = Data()
    private var refreshToken = false
    private var readRateLimits = false

    public private(set) var account: AppServerAccountRead?
    public private(set) var rateLimits: AppServerRateLimitsRead?

    public init() {}

    public var readyToCloseStandardInput: Bool {
        state == .accountReceived
    }

    var awaitingRateLimitsResponse: Bool {
        state == .awaitingRateLimits
    }

    public mutating func start(refreshToken: Bool, readRateLimits: Bool = false) throws -> [Data] {
        guard state == .idle else {
            throw AppServerProtocolFailure(code: .alreadyStarted)
        }
        self.refreshToken = refreshToken
        self.readRateLimits = readRateLimits
        state = .awaitingInitialize
        return [
            try Self.line([
                "method": "initialize",
                "id": Self.initializeID,
                "params": [
                    "clientInfo": [
                        "name": "codex_account_switcher_spike",
                        "title": "Codex Account Switcher Spike",
                        "version": "0.1.0",
                    ],
                ],
            ]),
        ]
    }

    public mutating func receive(_ chunk: Data) throws -> [Data] {
        guard buffer.count + chunk.count <= Self.maximumBufferedBytes else {
            throw AppServerProtocolFailure(code: .frameTooLarge)
        }
        buffer.append(chunk)

        var outbound = [Data]()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !frame.isEmpty, frame.count <= Self.maximumFrameBytes else {
                throw AppServerProtocolFailure(code: frame.isEmpty ? .malformedFrame : .frameTooLarge)
            }
            outbound.append(contentsOf: try handle(frame))
        }
        return outbound
    }

    public func validateEndOfFile() throws {
        guard buffer.isEmpty, state == .accountReceived else {
            throw AppServerProtocolFailure(code: .unexpectedEOF)
        }
    }
}

private extension AppServerProtocolMachine {
    mutating func handle(_ frame: Data) throws -> [Data] {
        let value: Any
        do {
            try StrictJSONDocumentValidator.validate(frame, maximumBytes: Self.maximumFrameBytes)
            value = try JSONSerialization.jsonObject(with: frame)
        } catch {
            throw AppServerProtocolFailure(code: .malformedFrame)
        }
        guard let object = value as? [String: Any] else {
            throw AppServerProtocolFailure(code: .malformedFrame)
        }

        let hasID = object.keys.contains("id")
        let method = object["method"] as? String
        if !hasID {
            guard method != nil else {
                throw AppServerProtocolFailure(code: .protocolViolation)
            }
            return []
        }
        guard method == nil else {
            throw AppServerProtocolFailure(code: .protocolViolation)
        }
        guard let identifier = integerID(object["id"]) else {
            throw AppServerProtocolFailure(code: .protocolViolation)
        }

        switch state {
        case .idle, .accountReceived:
            throw AppServerProtocolFailure(code: .protocolViolation)
        case .awaitingInitialize:
            guard identifier == Self.initializeID else { return [] }
            try validateResponseEnvelope(object)
            guard object["result"] is [String: Any] else {
                throw AppServerProtocolFailure(code: .protocolViolation)
            }
            state = .awaitingAccount
            return [
                try Self.line(["method": "initialized", "params": [:]]),
                try Self.line([
                    "method": "account/read",
                    "id": Self.accountID,
                    "params": ["refreshToken": refreshToken],
                ]),
            ]
        case .awaitingAccount:
            guard identifier == Self.accountID else { return [] }
            try validateResponseEnvelope(object)
            guard let result = object["result"] as? [String: Any] else {
                throw AppServerProtocolFailure(code: .protocolViolation)
            }
            account = try decodeAccount(result)
            guard readRateLimits else {
                state = .accountReceived
                return []
            }
            state = .awaitingRateLimits
            return [
                try Self.line([
                    "method": "account/rateLimits/read",
                    "id": Self.rateLimitsID,
                ]),
            ]
        case .awaitingRateLimits:
            guard identifier == Self.rateLimitsID else { return [] }
            try validateResponseEnvelope(object)
            guard let result = object["result"] as? [String: Any] else {
                throw AppServerProtocolFailure(code: .protocolViolation)
            }
            rateLimits = try decodeRateLimits(result)
            state = .accountReceived
            return []
        }
    }

    func validateResponseEnvelope(_ object: [String: Any]) throws {
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            throw AppServerProtocolFailure(code: .protocolViolation)
        }
        if hasError {
            let error = object["error"] as? [String: Any]
            throw AppServerProtocolFailure(
                code: .rpcError,
                rpcCode: integerID(error?["code"])
            )
        }
    }

    func decodeAccount(_ result: [String: Any]) throws -> AppServerAccountRead {
        guard let requiresOpenAIAuth = result["requiresOpenaiAuth"] as? Bool else {
            throw AppServerProtocolFailure(code: .protocolViolation)
        }

        if result["account"] is NSNull {
            return .signedOut(requiresOpenAIAuth: requiresOpenAIAuth)
        }
        guard let account = result["account"] as? [String: Any],
              let type = account["type"] as? String else {
            throw AppServerProtocolFailure(code: .protocolViolation)
        }
        guard type == "chatgpt" else {
            throw AppServerProtocolFailure(code: .unsupportedAccountType)
        }

        let email = try nullableString(account["email"])
        let planType = try nullableString(account["planType"])
        return .chatGPT(
            email: email,
            planType: planType,
            requiresOpenAIAuth: requiresOpenAIAuth
        )
    }

    func decodeRateLimits(_ result: [String: Any]) throws -> AppServerRateLimitsRead {
        let selected: Any?
        if let byLimitID = result["rateLimitsByLimitId"], !(byLimitID is NSNull) {
            guard let byLimitID = byLimitID as? [String: Any] else {
                throw AppServerProtocolFailure(code: .protocolViolation)
            }
            if let codex = byLimitID["codex"], !(codex is NSNull) {
                selected = codex
            } else {
                return AppServerRateLimitsRead(planType: nil, windows: [])
            }
        } else {
            selected = result["rateLimits"]
        }
        if selected == nil || selected is NSNull {
            return AppServerRateLimitsRead(planType: nil, windows: [])
        }
        guard let snapshot = selected as? [String: Any] else {
            throw AppServerProtocolFailure(code: .protocolViolation)
        }
        if let limitID = try nullableString(snapshot["limitId"]), limitID != "codex" {
            return AppServerRateLimitsRead(planType: nil, windows: [])
        }

        var windows = [AppServerRateLimitWindow]()
        for key in ["primary", "secondary"] {
            guard let value = snapshot[key], !(value is NSNull) else { continue }
            guard let window = value as? [String: Any],
                  let usedPercent = finiteNumber(window["usedPercent"]),
                  0 ... 100 ~= usedPercent else {
                throw AppServerProtocolFailure(code: .protocolViolation)
            }
            guard let durationValue = window["windowDurationMins"],
                  !(durationValue is NSNull) else {
                continue
            }
            guard let duration = positiveInteger(durationValue) else {
                throw AppServerProtocolFailure(code: .protocolViolation)
            }

            let resetsAt: Date?
            if let value = window["resetsAt"], !(value is NSNull) {
                guard let timestamp = finiteNumber(value) else {
                    throw AppServerProtocolFailure(code: .protocolViolation)
                }
                resetsAt = Date(timeIntervalSince1970: timestamp)
            } else {
                resetsAt = nil
            }
            windows.append(
                AppServerRateLimitWindow(
                    usedPercent: usedPercent,
                    windowDurationMinutes: duration,
                    resetsAt: resetsAt
                )
            )
        }
        return AppServerRateLimitsRead(
            planType: try nullableString(snapshot["planType"]),
            windows: windows
        )
    }

    func nullableString(_ value: Any?) throws -> String? {
        if value == nil || value is NSNull {
            return nil
        }
        guard let string = value as? String else {
            throw AppServerProtocolFailure(code: .protocolViolation)
        }
        return string
    }

    func integerID(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c" else {
            return nil
        }
        let candidate = number.doubleValue
        guard candidate.isFinite,
              candidate.rounded(.towardZero) == candidate,
              candidate >= Double(Int32.min),
              candidate <= Double(Int32.max) else {
            return nil
        }
        return Int(candidate)
    }

    func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue.isFinite else {
            return nil
        }
        return number.doubleValue
    }

    func positiveInteger(_ value: Any?) -> Int? {
        guard let candidate = finiteNumber(value),
              candidate.rounded(.towardZero) == candidate,
              candidate > 0,
              candidate < Double(Int.max) else {
            return nil
        }
        return Int(candidate)
    }

    static func line(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AppServerProtocolFailure(code: .protocolViolation)
        }
        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw AppServerProtocolFailure(code: .protocolViolation)
        }
        data.append(0x0A)
        return data
    }
}
