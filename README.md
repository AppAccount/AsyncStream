# AsyncStream

Concurrency safe wrapper for (NS)Stream class cluster using Swift 5.5 Async/Await and Actors. `InputStreamActor` for reading from a stream oriented source and `OutputStreamActor` for writing to a stream oriented sink. 

Stream events are processed on `RunLoop.current`. As a client of this package, you are responsible for ensuring the RunLoop is actually running, whether using the main thread runloop or explicitly running a background thread runloop. 
