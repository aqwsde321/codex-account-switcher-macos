struct TestCase {
    let name: String
    let body: () async throws -> Void

    init(_ name: String, body: @escaping () async throws -> Void) {
        self.name = name
        self.body = body
    }
}

func expectAsyncError<E: Error & Equatable>(
    _ expected: E,
    _ message: String,
    performing body: () async throws -> Void
) async throws {
    do {
        try await body()
        throw TestFailure(description: message)
    } catch let error as E {
        try expect(error == expected, message)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(description: message)
    }
}

func expectError<E: Error & Equatable>(
    _ expected: E,
    _ message: String,
    performing body: () throws -> Void
) throws {
    do {
        try body()
        throw TestFailure(description: message)
    } catch let error as E {
        try expect(error == expected, message)
    }
}
