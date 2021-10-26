import XCTest
@testable import AsyncStream

final class AsyncStreamTests: XCTestCase {
    static var streamBufferSize = 4096
    var inputStream: InputStream!
    var outputStream: OutputStream!
    var runLoopTask: Task<(), Error>?

    override func setUp() {
        print(#function)
        var optionalInputStream: InputStream?
        var optionalOutputStream: OutputStream?
        Stream.getBoundStreams(withBufferSize: Self.streamBufferSize, inputStream: &optionalInputStream, outputStream: &optionalOutputStream)
        self.inputStream = optionalInputStream!
        self.outputStream = optionalOutputStream!
        runLoopTask = Task {
            while true {
                try Task.checkCancellation()
                RunLoop.current.run(until: Date())
                await Task.yield()
            }
        }
    }
    
    override func tearDown() {
        runLoopTask?.cancel()
    }
    
    func testSingleWrite() async throws {
        let expectation = self.expectation(description: "write succeeded")
        let outputActor = OutputStreamActor(outputStream)
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        Task {
            for try await writeReady in writeReadyStream {
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
            for try await writeReady in writeReadyStream {
                if writeReady {
                    let size = Self.streamBufferSize >> 2
                    let data = Data.init(count: size)
                    let bytesWritten = try await outputActor.write(data)
                    XCTAssert(bytesWritten == size)
                } else {
                    expectation.fulfill()
                }
            }
        }
        await waitForExpectations(timeout: 2.0) { error in
            if let error = error {
                XCTFail(error.localizedDescription)
            }
        }
    }
    
    func testWriteAndRead() async throws {
        let expectation = self.expectation(description: "write and read back")
        let inputActor = InputStreamActor(inputStream)
        let outputActor = OutputStreamActor(outputStream)
        let readStream = await inputActor.getReadDataStream()
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        let messageSize = Self.streamBufferSize >> 2
        Task {
            for try await writeReady in writeReadyStream {
                if writeReady {
                    let data = Data.init(count: messageSize)
                    let bytesWritten = try await outputActor.write(data)
                    XCTAssert(bytesWritten == messageSize)
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                }
            }
        }
        Task {
            var bytesRead = 0
            for try await message in readStream {
                XCTAssert(message.count % messageSize == 0)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                bytesRead += message.count
                if bytesRead >= Self.streamBufferSize << 2 {
                    expectation.fulfill()
                    break
                }
            }
        }
        await waitForExpectations(timeout: 2.0) { error in
            if let error = error {
                XCTFail(error.localizedDescription)
            }
        }
    }
}
