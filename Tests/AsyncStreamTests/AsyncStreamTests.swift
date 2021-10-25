import XCTest
@testable import AsyncStream

final class AsyncStreamTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(AsyncStream().text, "Hello, World!")
    }
}
