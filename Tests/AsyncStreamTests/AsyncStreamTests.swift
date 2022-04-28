import XCTest
@testable import AsyncStream

extension XCTestCase {
    func testDealloc(_ object: AnyObject) {
        addTeardownBlock { [weak object] in
            XCTAssertNil(object)
        }
    }
}
    
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
    
    func testDealloc() async throws {
        var outputActor: OutputStreamActor? = OutputStreamActor(outputStream)
        testDealloc(outputActor!)
        let writeReadyStream = await outputActor!.getSpaceAvailableStream()
        for try await writeReady in writeReadyStream {
            if writeReady {
                if let outputActor = outputActor {
                    let size = Self.streamBufferSize >> 2
                    let data = Data.init(count: size)
                    let bytesWritten = try await outputActor.write(data)
                    XCTAssert(bytesWritten == size)
                }
                outputActor = nil
            }
        }
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
        var outputActor: OutputStreamActor? = OutputStreamActor(outputStream)
        testDealloc(outputActor!)
        let writeReadyStream = await outputActor!.getSpaceAvailableStream()
        var totalBytesWritten = 0
        for try await writeReady in writeReadyStream {
            if writeReady {
                let size = Self.streamBufferSize >> 2
                let data = Data.init(count: size)
                let bytesWritten = try await outputActor!.write(data)
                XCTAssert(bytesWritten == size)
                totalBytesWritten += bytesWritten
            } else {
                XCTAssert(totalBytesWritten == Self.streamBufferSize)
                outputActor = nil
            }
        }
    }
    
    func testSingleWriteAndRead() async throws {
        let inputActor = InputStreamActor(inputStream)
        var outputActor: OutputStreamActor? = OutputStreamActor(outputStream)
        testDealloc(inputActor)
        testDealloc(outputActor!)
        let readStream = await inputActor.getReadDataStream()
        let writeReadyStream = await outputActor!.getSpaceAvailableStream()
        let messageSize = Self.streamBufferSize >> 2
        let messageData = Data.init(repeating: 0x55, count: messageSize)
        Task {
            for try await receivedMessage in readStream {
                XCTAssert(receivedMessage == messageData)
                break
            }
        }
        for try await writeReady in writeReadyStream {
            if writeReady {
                if let outputActor = outputActor {
                    let bytesWritten = try await outputActor.write(messageData)
                    XCTAssert(bytesWritten == messageSize)
                }
                outputActor = nil
            }
        }
    }
    
    func testMultipleWriteAndRead() async throws {
        let inputActor = InputStreamActor(inputStream)
        var outputActor: OutputStreamActor? = OutputStreamActor(outputStream)
        testDealloc(inputActor)
        testDealloc(outputActor!)
        let readStream = await inputActor.getReadDataStream()
        let writeReadyStream = await outputActor!.getSpaceAvailableStream()
        let writeSize = Self.streamBufferSize
        let writeMessageSize = writeSize >> 2
        let writeData = Data.init(repeating: 0x55, count: writeSize)
        Task {
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
        var totalBytesWritten = 0
        for try await writeReady in writeReadyStream {
            if writeReady {
                if let outputActor = outputActor {
                    let range = Range(NSMakeRange(totalBytesWritten, writeMessageSize))!
                    let bytesWritten = try await outputActor.write(writeData[range])
                    XCTAssert(bytesWritten == writeMessageSize)
                    totalBytesWritten += bytesWritten
                }
                if totalBytesWritten >= Self.streamBufferSize {
                    outputActor = nil
                }
            }
        }
    }
    
    func testWriteToClosedStream() async throws {
        var outputActor: OutputStreamActor? = OutputStreamActor(outputStream)
        testDealloc(outputActor!)
        let writeReadyStream = await outputActor!.getSpaceAvailableStream()
        for try await writeReady in writeReadyStream {
            if writeReady {
                if let outputActor = outputActor {
                    let size = Self.streamBufferSize >> 2
                    let data = Data.init(count: size)
                    let bytesWritten = try await outputActor.write(data)
                    XCTAssert(bytesWritten == size)
                    outputStream.close()
                    do {
                        let _ = try await outputActor.write(data)
                        XCTFail("write to closed stream should have taken an exception") // expect exception above
                    } catch (let error) {
                        XCTAssert(error as? StreamActorError == .NotOpen)
                    }
                }
                outputActor = nil
            }
        }
    }
    
    func testReadStreamFinish() async throws {
        var outputActor: OutputStreamActor? = OutputStreamActor(outputStream)
        let inputActor = InputStreamActor(inputStream)
        testDealloc(inputActor)
        testDealloc(outputActor!)
        let writeReadyStream = await outputActor!.getSpaceAvailableStream()
        let readStream = await inputActor.getReadDataStream()
        Task {
            var closed = false
            for try await _ in readStream {
                if !closed {
                    closed = true
                    self.outputStream.close()
                }
            }
        }
        for try await writeReady in writeReadyStream {
            if writeReady {
                if let outputActor = outputActor {
                    let size = Self.streamBufferSize >> 2
                    let data = Data.init(count: size)
                    let _ = try await outputActor.write(data)
                }
                outputActor = nil
            }
        }
    }
    
    func testStreamWrite() async throws {
        var outputActor: OutputStreamActor? = OutputStreamActor(outputStream)
        let inputActor = InputStreamActor(inputStream)
        testDealloc(inputActor)
        testDealloc(outputActor!)
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
        await outputActor!.setWriteDataStream(writeDataStream)
        var readSize = 0
        for try await receivedMessage in readStream {
            readSize += receivedMessage.count
            print("read \(readSize)")
            if readSize >= size {
                break
            }
        }
        await outputActor!.setWriteDataStream(nil)
        let writeReadyStream = await outputActor!.getSpaceAvailableStream()
        for try await _ in writeReadyStream {
            outputActor = nil
        }
    }
    
    func testStreamWriteFinish() async throws {
        let outputActor = OutputStreamActor(outputStream)
        let inputActor = InputStreamActor(inputStream)
        testDealloc(inputActor)
        testDealloc(outputActor)
        let readStream = await inputActor.getReadDataStream()
        let writeDataStream = AsyncStream<Data> { continuation in
            let size = Self.streamBufferSize << 2
            let data = Data.init(count: size)
            continuation.yield(data)
        }
        await outputActor.setWriteDataStream(writeDataStream)
        for try await _ in readStream {
            self.inputStream.close()
            break
        }
        await outputActor.setWriteDataStream(nil)
        let writeReadyStream = await outputActor.getSpaceAvailableStream()
        for try await _ in writeReadyStream {}
    }
    
    func testMultiStreamWrite() async throws {
        var outputActor: OutputStreamActor? = OutputStreamActor(outputStream)
        let inputActor = InputStreamActor(inputStream)
        testDealloc(inputActor)
        testDealloc(outputActor!)
        let readStream = await inputActor.getReadDataStream()
        let size = Self.streamBufferSize << 2
        let data = Data.init(count: size)
        let firstWriteDataStream = AsyncStream<Data> { continuation in
            let yieldResult = continuation.yield(data)
            guard case AsyncStream<Data>.Continuation.YieldResult.enqueued = yieldResult else {
                XCTFail()
                return
            }
            continuation.finish()
        }
        let secondWriteDataStream = AsyncStream<Data> { continuation in
            let yieldResult = continuation.yield(data)
            guard case AsyncStream<Data>.Continuation.YieldResult.enqueued = yieldResult else {
                XCTFail()
                return
            }
            continuation.finish()
        }
        let _ = await outputActor!.setWriteDataStream(firstWriteDataStream)
        let _ = await outputActor!.setWriteDataStream(secondWriteDataStream)
        var readSize = 0
        for try await receivedMessage in readStream {
            readSize += receivedMessage.count
            print("read \(readSize)")
            if readSize >= size*2 {
                break
            }
        }
        await outputActor!.setWriteDataStream(nil)
        let writeReadyStream = await outputActor!.getSpaceAvailableStream()
        for try await _ in writeReadyStream {
            outputActor = nil
        }
    }
}
