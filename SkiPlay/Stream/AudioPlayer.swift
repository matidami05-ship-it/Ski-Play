import AVFoundation
import os

/// Plays the console's decoded audio with a small jitter buffer (~40 ms) to keep delay low.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var lock = os_unfair_lock()
    private var ring: [Float] = []
    private var readIndex = 0
    private var writeIndex = 0
    private var filled = 0
    private var channels = 2
    private var rate = 48000.0
    private var started = false
    private var primed = false

    var muted = false

    func configure(channels: Int, rate: Int) {
        os_unfair_lock_lock(&lock)
        self.channels = max(1, channels)
        self.rate = Double(rate)
        ring = [Float](repeating: 0, count: Int(self.rate) * self.channels) // 1 s capacity
        readIndex = 0; writeIndex = 0; filled = 0; primed = false
        os_unfair_lock_unlock(&lock)
        DispatchQueue.main.async { self.start() }
    }

    private var targetSamples: Int { Int(rate * 0.04) * channels }
    private var maxSamples: Int { Int(rate * 0.12) * channels }

    /// Interleaved 16-bit PCM from the decoder thread.
    func push(_ pcm: UnsafePointer<Int16>, frames: Int) {
        let count = frames * channels
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !ring.isEmpty else { return }
        let cap = ring.count
        for i in 0..<count {
            ring[writeIndex] = Float(pcm[i]) / 32768.0
            writeIndex = (writeIndex + 1) % cap
        }
        filled += count
        if filled > maxSamples {
            // Too far behind (e.g. after a hiccup): drop the oldest audio to catch up.
            let drop = filled - targetSamples
            readIndex = (readIndex + drop) % cap
            filled -= drop
        }
        if !primed && filled >= targetSamples { primed = true }
    }

    private func start() {
        if started { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setPreferredSampleRate(rate)
        try? session.setActive(true)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: AVAudioChannelCount(channels), interleaved: false) else { return }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            self.render(into: abl, frames: Int(frameCount))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            started = true
        } catch {
            Log.shared.add("Audio failed to start: \(error.localizedDescription)")
        }
    }

    private func render(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let ch = channels
        let cap = ring.count
        let available = primed ? filled / ch : 0
        let n = min(frames, available)
        for c in 0..<min(ch, abl.count) {
            guard let out = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            var idx = readIndex + c
            for f in 0..<frames {
                if f < n && !muted && cap > 0 {
                    out[f] = ring[idx % cap]
                    idx += ch
                } else {
                    out[f] = 0
                }
            }
        }
        if cap > 0 {
            readIndex = (readIndex + n * ch) % cap
            filled -= n * ch
        }
        if n < frames { primed = filled >= targetSamples }
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        started = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
