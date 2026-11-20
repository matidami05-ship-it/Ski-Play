import Foundation
import Combine
import UIKit

/// One Remote Play stream: connects to the console, feeds video/audio to the decoders and sends
/// controller input back.
final class StreamSession: ObservableObject {
    enum Phase: Equatable {
        case waking, connecting, reachingRemote, streaming, needsPIN(incorrect: Bool), ended(String?)
    }

    @Published var phase: Phase = .connecting
    @Published var stats = "" // shown when the stats overlay is on

    let console: Console
    let decoder: VideoDecoder
    let audio = AudioPlayer()
    let input = ControllerInput()

    private var handle: OpaquePointer?
    private var statsTimer: Timer?
    private var lastFrames = 0
    private var lostFrames: Int32 = 0
    private let hevc: Bool
    private(set) var remote = false
    private var canceled = false

    init(console: Console) {
        self.console = console
        let store = AppStore.shared
        hevc = console.ps5 && store.useHEVC
        decoder = VideoDecoder(hevc: hevc)
    }

    deinit {
        statsTimer?.invalidate()
    }

    /// Frees the native session off the main thread, then drops the reference that kept this
    /// object alive while chiaki could still call back into it.
    private func teardown() {
        guard let h = handle else { return }
        handle = nil
        let me = Unmanaged.passUnretained(self)
        DispatchQueue.global(qos: .userInitiated).async {
            sp_session_free(h)
            DispatchQueue.main.async { me.release() }
        }
    }

    func start() {
        let found = Discovery.shared.status(for: console)
        let host = found?.address ?? console.host
        if found == nil && console.canPlayRemotely {
            startRemote()
            return
        }
        if found == nil && !console.isLinkedLocally {
            phase = .ended("This console can only be reached over the internet, but it isn't set up for that yet. Sign in to PlayStation again in Settings.")
            return
        }
        if found?.state == .rest {
            phase = .waking
            wake(host: host)
            // Give the console time to boot from rest mode before connecting.
            waitUntilOn(host: host, deadline: Date().addingTimeInterval(45))
        } else {
            connect(host: host)
        }
    }

    private func wake(host: String) {
        let key = [UInt8](console.registKey.prefix(16)) + [UInt8](repeating: 0, count: max(0, 16 - console.registKey.count))
        key.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: 16) { ptr in
                _ = sp_wakeup(host, ptr, console.ps5)
            }
        }
    }

    private func waitUntilOn(host: String, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.phase == .waking else { return }
            let state = Discovery.shared.status(for: self.console)?.state
            if state == .on {
                // The console answers discovery a little before Remote Play is ready.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.connect(host: host) }
            } else if Date() > deadline {
                self.connect(host: host) // try anyway
            } else {
                if Int(Date().timeIntervalSince1970) % 6 == 0 { self.wake(host: host) }
                self.waitUntilOn(host: host, deadline: deadline)
            }
        }
    }

    /// Away from home: reach the console through PlayStation Network.
    private func startRemote() {
        remote = true
        phase = .reachingRemote
        Task { @MainActor in
            do {
                let token = try await PSNAuth.validAccessToken()
                guard !canceled else { return }
                connect(host: "", remoteToken: token)
            } catch {
                phase = .ended(error.localizedDescription)
            }
        }
    }

    private func connect(host: String, remoteToken: String? = nil) {
        guard handle == nil, !canceled else { return }
        phase = remoteToken == nil ? .connecting : .reachingRemote
        let store = AppStore.shared
        let quality = remoteToken == nil ? store.quality : store.awayQuality
        var config = SPSessionConfig()
        config.ps5 = console.ps5
        config.width = Int32(quality.width)
        config.height = Int32(quality.height)
        config.fps = Int32(store.fps)
        config.bitrate = Int32(quality.bitrate)
        config.port_guessing = store.portGuessing
        config.codec = hevc ? Int32(SP_CODEC_H265) : Int32(SP_CODEC_H264)
        config.dualsense = true
        config.packet_loss_max = 0.05
        withUnsafeMutableBytes(of: &config.regist_key) { dst in
            console.registKey.prefix(16).withUnsafeBytes { dst.copyMemory(from: $0) }
        }
        withUnsafeMutableBytes(of: &config.morning) { dst in
            console.morning.prefix(16).withUnsafeBytes { dst.copyMemory(from: $0) }
        }
        if let account = store.accountID {
            withUnsafeMutableBytes(of: &config.psn_account_id) { dst in
                account.prefix(8).withUnsafeBytes { dst.copyMemory(from: $0) }
            }
        }

        var cb = SPCallbacks()
        cb.user = Unmanaged.passRetained(self).toOpaque() // released in teardown()
        cb.connected = { user in
            let me = StreamSession.from(user)
            DispatchQueue.main.async { me.phase = .streaming; me.startStats() }
        }
        cb.quit = { user, _, reasonStr, isError in
            let me = StreamSession.from(user)
            let text = reasonStr.map { String(cString: $0) }
            DispatchQueue.main.async {
                me.input.stop()
                me.audio.stop()
                me.statsTimer?.invalidate()
                UIApplication.shared.isIdleTimerDisabled = false
                if isError {
                    let detail = Log.shared.recentErrors(3)
                    me.phase = .ended(StreamSession.friendly(text) + (detail.isEmpty ? "" : "\n\n" + detail))
                } else {
                    me.phase = .ended(nil)
                }
                me.teardown()
            }
        }
        cb.login_pin = { user, incorrect in
            let me = StreamSession.from(user)
            DispatchQueue.main.async { me.phase = .needsPIN(incorrect: incorrect) }
        }
        cb.rumble = { user, left, right in
            StreamSession.from(user).input.rumble(left: left, right: right)
        }
        cb.video = { user, buf, size, framesLost, _ in
            guard let buf else { return true }
            let me = StreamSession.from(user)
            if framesLost > 0 { me.lostFrames += framesLost }
            return me.decoder.decode(buf, count: size)
        }
        cb.audio_settings = { user, channels, rate in
            StreamSession.from(user).audio.configure(channels: Int(channels), rate: Int(rate))
        }
        cb.audio_frame = { user, pcm, samples in
            guard let pcm else { return }
            StreamSession.from(user).audio.push(pcm, frames: Int(samples))
        }
        cb.holepunch = { user, finished in
            let me = StreamSession.from(user)
            if !finished { DispatchQueue.main.async { if me.phase != .streaming { me.phase = .reachingRemote } } }
        }

        var err: Int32 = 0
        let duid = console.psnDUID ?? ""
        let newHandle: OpaquePointer? = host.withCString { cHost in
            (remoteToken ?? "").withCString { cToken in
                duid.withCString { cDuid in
                    config.host = cHost
                    if remoteToken != nil {
                        config.psn_token = cToken
                        config.remote_duid = cDuid
                    }
                    return sp_session_new(&config, cb, &err)
                }
            }
        }
        guard let newHandle else {
            Unmanaged.passUnretained(self).release()
            phase = .ended("Couldn't start the stream: \(Chiaki.errorString(err))")
            return
        }
        handle = newHandle
        if remoteToken != nil {
            // Reaching the console through PSN takes a few seconds and blocks, so do it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let r = sp_session_connect_remote(newHandle)
                DispatchQueue.main.async {
                    if self.canceled {
                        self.teardown()
                    } else if r != 0 {
                        let detail = Log.shared.recentErrors(3)
                        self.phase = .ended("Couldn't reach your console over the internet (\(Chiaki.errorString(r))). Make sure it's on or in rest mode with \"Stay Connected to the Internet\" turned on. If you're on a phone hotspot, turn on Hotspot mode in Settings." + (detail.isEmpty ? "" : "\n\n" + detail))
                        self.teardown()
                    } else {
                        self.beginStreaming(newHandle)
                    }
                }
            }
        } else {
            beginStreaming(newHandle)
        }
    }

    private func beginStreaming(_ newHandle: OpaquePointer) {
        let startErr = sp_session_start(newHandle)
        if startErr != 0 {
            phase = .ended("Couldn't connect: \(Chiaki.errorString(startErr))")
            teardown()
            return
        }
        input.start { [weak self] state in
            guard let self, let h = self.handle else { return }
            var s = state
            sp_session_set_controller(h, &s)
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func enterPIN(_ pin: String) {
        guard let handle else { return }
        sp_session_set_login_pin(handle, pin)
        phase = .connecting
    }

    func stop() {
        canceled = true
        UIApplication.shared.isIdleTimerDisabled = false
        input.stop()
        audio.stop()
        statsTimer?.invalidate()
        if let handle {
            if phase == .reachingRemote && remote {
                sp_session_cancel_remote(handle) // the connect thread finishes and tears down
            }
            sp_session_stop(handle) // chiaki answers with a quit event, which tears down
        } else if case .ended = phase {} else {
            phase = .ended(nil)
        }
    }

    func sleepConsole() {
        if let handle { sp_session_sleep_console(handle) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.stop() }
    }

    func pressPS() {
        input.tap(button: ControllerInput.Button.ps)
    }

    private func startStats() {
        statsTimer?.invalidate()
        lastFrames = decoder.framesDecoded
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let h = self.handle else { return }
            let frames = self.decoder.framesDecoded
            let fps = frames - self.lastFrames
            self.lastFrames = frames
            let rtt = Double(sp_session_rtt_us(h)) / 1000
            let loss = sp_session_packet_loss(h) * 100
            let mbps = sp_session_measured_bitrate(h)
            self.stats = String(format: "%ld fps · %.0f ms · %.1f Mbps · loss %.1f%% · dropped %ld",
                                fps, rtt, mbps, loss, Int(self.lostFrames))
        }
    }

    private static func from(_ user: UnsafeMutableRawPointer?) -> StreamSession {
        Unmanaged<StreamSession>.fromOpaque(user!).takeUnretainedValue()
    }

    private static func friendly(_ reason: String?) -> String {
        let r = reason ?? ""
        let lower = r.lowercased()
        if lower.contains("in use") {
            return "Remote Play is already in use on the console. Close it on the other device and try again."
        }
        if lower.contains("crash") {
            return "Remote Play crashed on the console. Restart the PS5 and try again."
        }
        if lower.contains("refused") || lower.contains("connect") {
            return "The console refused the connection. Make sure Remote Play is turned on (Settings › System › Remote Play) and the console is on the same Wi-Fi."
        }
        if lower.contains("regist") {
            return "The console doesn't recognize this phone anymore. Remove it and link again."
        }
        return r.isEmpty ? "The stream ended unexpectedly." : r
    }
}
