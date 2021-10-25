import XCTest
@testable import AsyncStream

final class AsyncStreamTests: XCTestCase {
    static var streamBufferSize = 4096
    var inputStream: InputStream!
    var outputStream: OutputStream!

    override func setUp() {
        var optionalInputStream: InputStream?
        var optionalOutputStream: OutputStream?
        Stream.getBoundStreams(withBufferSize: Self.streamBufferSize, inputStream: &optionalInputStream, outputStream: &optionalOutputStream)
        self.inputStream = optionalInputStream!
        self.outputStream = optionalOutputStream!
    }
    
    func testSingleWrite() async throws {
        let expectation = self.expectation(description: "write succeeded")
        let outputActor = OutputStreamActor(outputStream)
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        Task {
            for await writeReady in writeReadyStream {
                if writeReady {
                    let size = Self.streamBufferSize >> 2
                    let data = Data.init(count: size)
                    let bytesWritten = try await outputActor.write(data)
                    XCTAssert(bytesWritten == size)
                    expectation.fulfill()
                    break
                }
            }
        }
        RunLoop.current.run(until: Date())
        await waitForExpectations(timeout: 2.0) { error in
            if let error = error {
                XCTFail(error.localizedDescription)
            }
        }
    }
    
    func testWriteUntilFull() async throws {
        let expectation = self.expectation(description: "stream buffer full")
        let outputActor = OutputStreamActor(outputStream)
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        Task {
            for await writeReady in writeReadyStream {
                if writeReady {
                    let size = Self.streamBufferSize >> 2
                    let data = Data.init(count: size)
                    let bytesWritten = try await outputActor.write(data)
                    XCTAssert(bytesWritten == size)
                    RunLoop.current.run(until: Date())
                } else {
                    expectation.fulfill()
                }
            }
        }
        RunLoop.current.run(until: Date())
        await waitForExpectations(timeout: 2.0) { error in
            if let error = error {
                XCTFail(error.localizedDescription)
            }
        }
    }
}
