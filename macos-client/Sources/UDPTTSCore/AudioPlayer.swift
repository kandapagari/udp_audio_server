import AVFoundation
import Foundation

/// Thread-safe playback level (0...1), written by the audio render thread and
/// read by the UI. Applies peak-with-decay smoothing for a natural VU motion.
public final class LevelMeter {
    private let lock = NSLock()
    private var value: Float = 0

    /// Feed the block peak; the meter falls back gradually between louder blocks.
    func update(peak: Float) {
        lock.lock(); defer { lock.unlock() }
        value = max(min(peak, 1), value * 0.82)
    }

    public var level: Float {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Real-time playback of the jitter-buffered PCM stream via AVAudioEngine.
///
/// An `AVAudioSourceNode` render callback pulls little-endian int16 PCM from the
/// `JitterBuffer`, converts to float32, and feeds the output. Underflow plays
/// silence rather than blocking, mirroring the Python `sounddevice` callback.
public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let channels: Int
    private let buffer: JitterBuffer

    /// Live output level for a VU meter. Updated from the render thread.
    public let meter = LevelMeter()

    public init(sampleRate: Double, channels: Int, buffer: JitterBuffer) {
        self.channels = max(1, channels)
        self.buffer = buffer

        // Output format the render block produces: float32, non-interleaved.
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: AVAudioChannelCount(self.channels))!
        let chCount = self.channels
        let jb = buffer
        let meter = self.meter

        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let bytesPerFrame = 2 * chCount               // int16 * channels
            let needed = Int(frameCount) * bytesPerFrame
            let pcm = jb.read(count: needed)              // zero-padded on underflow

            var peak: Float = 0
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let src = raw.bindMemory(to: Int16.self)  // little-endian on Apple platforms
                for ch in 0..<min(chCount, abl.count) {
                    guard let dst = abl[ch].mData?.assumingMemoryBound(to: Float.self)
                    else { continue }
                    for frame in 0..<Int(frameCount) {
                        let sample = Float(src[frame * chCount + ch]) / 32768.0
                        dst[frame] = sample
                        if ch == 0 {
                            let mag = abs(sample)
                            if mag > peak { peak = mag }
                        }
                    }
                }
            }
            meter.update(peak: peak)
            return noErr
        }

        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }
}
