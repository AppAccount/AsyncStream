//  OutputStreamActor.swift
//
//  Created by Yuval Koren on 10/25/21.
//  Copyright © 2021 Appcessori Corporation.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

public enum StreamActorError: Error {
    case NotOpen
    case WriteError
}

public actor OutputStreamActor: NSObject {
    let output: OutputStream
    private var yield: ((Bool)->())?
    private var finish:(()->())?
    
    init(_ output: OutputStream) {
        self.output = output
        super.init()
        output.delegate = self
        output.schedule(in: RunLoop.current, forMode: RunLoop.Mode.default)
        output.open()
    }
    
    func getSpaceAvailableStream()-> AsyncThrowingStream<Bool, Error> {
        AsyncThrowingStream<Bool, Error> { continuation in
            yield = { spaceAvailable in
                continuation.yield(spaceAvailable)
            }
            finish = {
                continuation.finish(throwing: self.output.streamError)
            }
        }
    }
    
    func write(_ data: Data) throws -> Int {
        guard output.streamStatus == Stream.Status.open else {
            throw StreamActorError.NotOpen
        }
        var totalBytesWritten = 0
        try data.withUnsafeBytes { unsafeRawBufferPointer in
            while output.hasSpaceAvailable == true && totalBytesWritten < data.count {
                guard let unsafeBasePointer = unsafeRawBufferPointer.bindMemory(to: UInt8.self).baseAddress else {
                    fatalError()
                }
                let unsafePointer = unsafeBasePointer + totalBytesWritten
                let bytesWritten = output.write(unsafePointer, maxLength: data.count - totalBytesWritten)
                if bytesWritten == -1 {
                    throw output.streamError ?? StreamActorError.WriteError
                }
                if bytesWritten > 0 {
                    totalBytesWritten += bytesWritten
                }
            }
            if !output.hasSpaceAvailable {
                hasSpaceAvailable(false)
            }
        }
        return totalBytesWritten
    }
    
    private func hasSpaceAvailable(_ value: Bool) {
        yield?(value)
    }
    
    deinit {
        print(#function)
        output.close()
        output.remove(from: RunLoop.current, forMode: RunLoop.Mode.default)
        output.delegate = nil
    }
}

extension OutputStreamActor: StreamDelegate {
    nonisolated public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream is OutputStream else {
            fatalError("\(#function) Expected OutputStream")
        }
#if DEBUG
        print(#function, "OutputStream" , eventCode)
#endif
        switch eventCode {
        case Stream.Event.hasSpaceAvailable:
            Task.detached { [weak self] in
                await self?.hasSpaceAvailable(true)
            }
        case Stream.Event.errorOccurred:
            Task.detached { [weak self] in
                await self?.finish?()
            }
        case Stream.Event.endEncountered:
            Task.detached { [weak self] in
                await self?.finish?()
            }
        default:
            break
        }
    }
}
