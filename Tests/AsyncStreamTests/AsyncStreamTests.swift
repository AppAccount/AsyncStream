import XCTest
@testable import AsyncStream

final class AsyncStreamTests: XCTestCase {
    #if os(macOS)
    /// on macOS Monterey, `getBoundStreams` derived streams sometimes incur a 5s-15s startup delay
    static let testTimeout: UInt64 = 30_000_000_000
    #else
    static let testTimeout: UInt64 = 3_000_000_000
    #endif
    static var streamBufferSize = 4096
    var inputStream: InputStream!
    var outputStream: OutputStream!
    var runLoopTask: Task<(), Error>!
    var timeoutTask: Task<(), Never>!

    override func setUp() {
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
        timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.testTimeout)
            } catch(let error) {
                if !(error is CancellationError) {
                    XCTFail("can't start timer")
                }
                return
            }
            XCTFail("timed out")
        }
    }
    
    override func tearDown() {
        timeoutTask.cancel()
        runLoopTask.cancel()
    }
    
    func testSingleWrite() async throws {
        let outputActor = OutputStreamActor(outputStream)
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        for try await writeReady in writeReadyStream {
            if writeReady {
                let size = Self.streamBufferSize >> 2
                let data = Data.init(count: size)
                let bytesWritten = try await outputActor.write(data)
                XCTAssert(bytesWritten == size)
                break
            }
        }
    }
    
    func testWriteUntilFull() async throws {
        let outputActor = OutputStreamActor(outputStream)
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        var totalBytesWritten = 0
        for try await writeReady in writeReadyStream {
            if writeReady {
                let size = Self.streamBufferSize >> 2
                let data = Data.init(count: size)
                let bytesWritten = try await outputActor.write(data)
                XCTAssert(bytesWritten == size)
                totalBytesWritten += bytesWritten
            } else {
                XCTAssert(totalBytesWritten == Self.streamBufferSize)
                break
            }
        }
    }
    
    func testSingleWriteAndRead() async throws {
        let inputActor = InputStreamActor(inputStream)
        let outputActor = OutputStreamActor(outputStream)
        let readStream = await inputActor.getReadDataStream()
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        let messageSize = Self.streamBufferSize >> 2
        let messageData = Data.init(repeating: 0x55, count: messageSize)
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                for try await writeReady in writeReadyStream {
                    if writeReady {
                        let bytesWritten = try await outputActor.write(messageData)
                        XCTAssert(bytesWritten == messageSize)
                        break
                    }
                }
            }
            taskGroup.addTask {
                for try await receivedMessage in readStream {
                    XCTAssert(receivedMessage == messageData)
                    break
                }
            }
            try await taskGroup.waitForAll()
        }
    }
    
    func testMultipleWriteAndRead() async throws {
        let inputActor = InputStreamActor(inputStream)
        let outputActor = OutputStreamActor(outputStream)
        let readStream = await inputActor.getReadDataStream()
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        let writeSize = Self.streamBufferSize
        let writeMessageSize = writeSize >> 2
        let writeData = Data.init(repeating: 0x55, count: writeSize)
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                var totalBytesWritten = 0
                for try await writeReady in writeReadyStream {
                    if writeReady {
                        let range = Range(NSMakeRange(totalBytesWritten, writeMessageSize))!
                        let bytesWritten = try await outputActor.write(writeData[range])
                        XCTAssert(bytesWritten == writeMessageSize)
                        totalBytesWritten += bytesWritten
                        if totalBytesWritten >= Self.streamBufferSize {
                            break
                        }
                    }
                }
            }
            taskGroup.addTask {
                var bytesRead = 0
                for try await readMessage in readStream {
                    let range = Range(NSMakeRange(bytesRead, readMessage.count))!
                    if readMessage != writeData[range] {
                        XCTFail("read mismatch")
                        break
                    }
                    bytesRead += readMessage.count
                    if bytesRead >= Self.streamBufferSize {
                        break
                    }
                }
            }
            try await taskGroup.waitForAll()
        }
    }
    
    func testWriteToClosedStream() async throws {
        let outputActor = OutputStreamActor(outputStream)
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        for try await _ in writeReadyStream {
            outputStream.close()
            let size = Self.streamBufferSize >> 2
            let data = Data.init(count: size)
            do {
                let _ = try await outputActor.write(data)
            } catch (let error) {
                guard let error = error as? StreamActorError, error == .NotOpen else {
                    XCTFail()
                    return
                }
                break
            }
        }
    }
    
    func testReadStreamFinish() async throws {
        let outputActor = OutputStreamActor(outputStream)
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        let inputActor = InputStreamActor(inputStream)
        let readStream = await inputActor.getReadDataStream()
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                var closed = false
                for try await _ in readStream {
                    if !closed {
                        closed = true
                        self.outputStream.close()
                    }
                }
            }
            taskGroup.addTask {
                for try await writeReady in writeReadyStream {
                    if writeReady {
                        let size = Self.streamBufferSize >> 2
                        let data = Data.init(count: size)
                        let _ = try await outputActor.write(data)
                        break
                    }
                }
            }
            try await taskGroup.waitForAll()
        }
    }
    
    func testStreamWrite() async throws {
        let outputActor = OutputStreamActor(outputStream)
        let inputActor = InputStreamActor(inputStream)
        let readStream = await inputActor.getReadDataStream()
        let size = Self.streamBufferSize << 2
        let data = Data.init(count: size)
        let writeDataStream = AsyncStream<Data> { continuation in
            let yieldResult = continuation.yield(data)
            guard case AsyncStream<Data>.Continuation.YieldResult.enqueued = yieldResult else {
                XCTFail()
                return
            }
            continuation.finish()
        }
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                await outputActor.setWriteDataStream(writeDataStream)
            }
            taskGroup.addTask {
                var readSize = 0
                for try await receivedMessage in readStream {
                    readSize += receivedMessage.count
                    if readSize >= size {
                        break
                    }
                }
            }
            try await taskGroup.waitForAll()
        }
    }
    
    func testStreamWriteFinish() async throws {
        let outputActor = OutputStreamActor(outputStream)
        let inputActor = InputStreamActor(inputStream)
        let readStream = await inputActor.getReadDataStream()
        let writeDataStream = AsyncStream<Data> { continuation in
            let size = Self.streamBufferSize << 2
            let data = Data.init(count: size)
            continuation.yield(data)
        }
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                await outputActor.setWriteDataStream(writeDataStream)
            }
            taskGroup.addTask {
                for try await _ in readStream {
                    self.inputStream.close()
                    break
                }
            }
            try await taskGroup.waitForAll()
        }
    }
}
