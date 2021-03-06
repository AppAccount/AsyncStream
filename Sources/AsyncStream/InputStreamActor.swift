//  InputStreamActor.swift
//
//  Created by Yuval Koren on 10/26/21.
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

public actor InputStreamActor: NSObject {
    static var singleReadBufferSize = 4096

    private let input: InputStream
    private var yield: ((Data)->())?
    private var finish:(()->())?
    
    public init(_ input: InputStream) {
        self.input = input
        super.init()
        self.input.delegate = self
        self.input.schedule(in: RunLoop.current, forMode: RunLoop.Mode.default)
        self.input.open()
    }
    
    public func getReadDataStream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            yield = { data in
                continuation.yield(data)
            }
            finish = { [weak self] in
                continuation.finish(throwing: self?.input.streamError)
            }
        }
    }
    
    private func read() {
        var readData = Data()
        let bufferSize = Self.singleReadBufferSize
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        guard input.hasBytesAvailable else {
            return // nothing to read
        }
        
        while input.hasBytesAvailable == true {
            let bytesRead = input.read(&buffer, maxLength: bufferSize)
            /// avoid looping when stream reports `hasBytesAvailable` but returns none 
            guard bytesRead > 0 else {
                return
            }
            readData.append(buffer, count: bytesRead)
        }
        
        yield?(readData)
    }
    
    deinit {
        input.close()
        input.remove(from: RunLoop.current, forMode: RunLoop.Mode.default)
        input.delegate = nil
        finish?()
    }
}

extension InputStreamActor: StreamDelegate {
    nonisolated public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream is InputStream else {
            fatalError("\(#function) Expected InputStream")
        }
        Task { [weak self] in
            guard let strongSelf = self else {
                return
            }
            var handledEventCodeName: String?
            if eventCode.contains(.openCompleted) {
                handledEventCodeName = "openCompleted"
            }
            if eventCode.contains(.hasBytesAvailable) {
                handledEventCodeName = "hasBytesAvailable"
                await strongSelf.read()
            }
            if eventCode.contains(.errorOccurred) {
                handledEventCodeName = "errorOccurred"
                await strongSelf.finish?()
            }
            if eventCode.contains(.endEncountered) {
                handledEventCodeName = "endEncountered"
                await strongSelf.finish?()
            }
    #if DEBUG
            if let handledEventCodeName = handledEventCodeName {
                print(type(of: strongSelf), #function, handledEventCodeName, eventCode)
            }
    #endif
        }
    }
}
