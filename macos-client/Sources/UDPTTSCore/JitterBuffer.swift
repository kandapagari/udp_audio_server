import Foundation

/// Reorders PCM frames by sequence number and conceals losses with silence.
/// Swift port of the Python client's `JitterBuffer` with identical semantics.
///
/// Thread-safe: the network thread calls `push`, the audio render thread calls
/// `read`. A single lock guards all mutable state. The lock is held only for
/// byte copies, never across I/O, so the audio thread is not meaningfully blocked.
public final class JitterBuffer {
    private let frameBytes: Int
    private let reorderWindow: UInt32
    private let lock = NSLock()

    private var fifo = Data()
    private var pending: [UInt32: Data] = [:]
    private var expected: UInt32 = 0
    private var complete = false

    public private(set) var received = 0
    public private(set) var concealed = 0

    public init(frameBytes: Int, reorderWindow: UInt32 = 8) {
        self.frameBytes = frameBytes
        self.reorderWindow = reorderWindow
    }

    public func push(seq: UInt32, pcm: Data) {
        lock.lock(); defer { lock.unlock() }
        if seq < expected { return }  // already played past this point
        received += 1
        pending[seq] = pcm
        drainPendingLocked()
        // If we've received packets well beyond the expected one, the missing
        // head is almost certainly lost: conceal with silence and advance.
        while let maxSeq = pending.keys.max(), maxSeq &- expected > reorderWindow {
            fifo.append(Data(count: frameBytes))
            concealed += 1
            expected &+= 1
            drainPendingLocked()
        }
    }

    private func drainPendingLocked() {
        while let next = pending[expected] {
            fifo.append(next)
            pending.removeValue(forKey: expected)
            expected &+= 1
        }
    }

    /// At end-of-stream, emit remaining parked packets in order (silence-filling
    /// any interior gaps), then mark the stream complete.
    public func flushAndComplete() {
        lock.lock(); defer { lock.unlock() }
        for seq in pending.keys.sorted() {
            if seq < expected { continue }
            while expected < seq {
                fifo.append(Data(count: frameBytes))
                concealed += 1
                expected &+= 1
            }
            if let d = pending.removeValue(forKey: seq) {
                fifo.append(d)
                expected &+= 1
            }
        }
        complete = true
    }

    /// Pop exactly `count` bytes for the audio callback, zero-padded on underflow.
    public func read(count: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        let take = min(count, fifo.count)
        var result = Data(fifo.prefix(take))   // copy before mutating fifo
        if take > 0 { fifo.removeFirst(take) }
        if take < count { result.append(Data(count: count - take)) }
        return result
    }

    /// Pop up to `maxBytes` of real data, never padded. May be empty.
    /// Used by headless consumers (e.g. the probe) that must not record silence.
    public func readAvailable(maxBytes: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        let take = min(maxBytes, fifo.count)
        let result = Data(fifo.prefix(take))
        if take > 0 { fifo.removeFirst(take) }
        return result
    }

    public var available: Int {
        lock.lock(); defer { lock.unlock() }
        return fifo.count
    }

    public var isDrained: Bool {
        lock.lock(); defer { lock.unlock() }
        return complete && fifo.isEmpty
    }

    public var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return complete
    }
}
