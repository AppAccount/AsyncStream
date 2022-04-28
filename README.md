# AsyncStream

Concurrency safe wrapper for (NS)Stream class cluster using Swift 5.5 Async/Await and Actors. `InputStreamActor` for reading from a stream oriented source and `OutputStreamActor` for writing to a stream oriented sink. 

Use `setWriteDataStream(_ writeDataStream: AsyncStream<Data>?) async` to provide an AsyncStream of bytes to be delivered to the underlying OutputStream. Repeated calls to this method will block until the prior stream (if any) has finished. 

Stream events are processed on `RunLoop.current`. As a client of this package, you are responsible for ensuring the RunLoop is actually running, whether using the main thread runloop or explicitly running a background thread runloop. 
