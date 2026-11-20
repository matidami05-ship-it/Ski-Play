import Foundation
import GameController
import CoreHaptics
import os

/// Reads a connected controller (DualSense, DualShock 4, Xbox, MFi) and the on-screen controls,
/// merges them and sends the result to the console ~250 times a second.
final class ControllerInput: ObservableObject {
    enum Button {
        static let cross: UInt32 = 1 << 0
        static let circle: UInt32 = 1 << 1
        static let square: UInt32 = 1 << 2
        static let triangle: UInt32 = 1 << 3
        static let left: UInt32 = 1 << 4
        static let right: UInt32 = 1 << 5
        static let up: UInt32 = 1 << 6
        static let down: UInt32 = 1 << 7
        static let l1: UInt32 = 1 << 8
        static let r1: UInt32 = 1 << 9
        static let l3: UInt32 = 1 << 10
        static let r3: UInt32 = 1 << 11
        static let options: UInt32 = 1 << 12
        static let share: UInt32 = 1 << 13
        static let touchpad: UInt32 = 1 << 14
        static let ps: UInt32 = 1 << 15
    }

    static let touchpadWidth: Float = 1920
    static let touchpadHeight: Float = 1080

    @Published private(set) var controllerName: String?

    // On-screen controls write here (main thread); the send loop reads under the lock.
    private var lock = os_unfair_lock()
    private var virtualButtons: UInt32 = 0
    private var virtualL2: UInt8 = 0
    private var virtualR2: UInt8 = 0
    private var virtualLeft = SIMD2<Float>(0, 0)
    private var virtualRight = SIMD2<Float>(0, 0)
    private var virtualTouch: SIMD2<Float>?
    private var tapButtons: UInt32 = 0
    private var tapUntil = Date.distantPast

    private var timer: DispatchSourceTimer?
    private var send: ((SPController) -> Void)?
    private var last = SPController()
    private var lastSent = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var hapticEngine: CHHapticEngine?
    private var rumblePlayer: CHHapticAdvancedPatternPlayer?
    private let hapticQueue = DispatchQueue(label: "rumble")

    init() {
        sp_controller_idle(&last)
    }

    func start(send: @escaping (SPController) -> Void) {
        self.send = send
        GCController.shouldMonitorBackgroundEvents = false
        refreshController()
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refreshController() })
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refreshController() })

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "controller", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        send = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        hapticQueue.async { [weak self] in
            try? self?.rumblePlayer?.stop(atTime: CHHapticTimeImmediate)
            self?.hapticEngine?.stop()
            self?.hapticEngine = nil
        }
    }

    private func refreshController() {
        let pad = GCController.controllers().first { $0.extendedGamepad != nil }
        controllerName = pad?.vendorName
        if let gp = pad?.extendedGamepad {
            // Keep the PS / Create / Options buttons for the game instead of iOS shortcuts.
            gp.buttonHome?.preferredSystemGestureState = .disabled
            gp.buttonOptions?.preferredSystemGestureState = .disabled
            gp.buttonMenu.preferredSystemGestureState = .disabled
        }
        hapticQueue.async { [weak self] in self?.setupHaptics(pad) }
    }

    // MARK: - On-screen controls

    func setVirtual(button: UInt32, pressed: Bool) {
        os_unfair_lock_lock(&lock)
        if pressed { virtualButtons |= button } else { virtualButtons &= ~button }
        os_unfair_lock_unlock(&lock)
    }

    func setVirtualTrigger(left: Bool, pressed: Bool) {
        os_unfair_lock_lock(&lock)
        if left { virtualL2 = pressed ? 255 : 0 } else { virtualR2 = pressed ? 255 : 0 }
        os_unfair_lock_unlock(&lock)
    }

    /// x/y in -1...1, y up = negative (like the console expects).
    func setVirtualStick(left: Bool, _ value: SIMD2<Float>) {
        os_unfair_lock_lock(&lock)
        if left { virtualLeft = value } else { virtualRight = value }
        os_unfair_lock_unlock(&lock)
    }

    /// Normalized 0...1 position on the touchpad, or nil when lifted.
    func setVirtualTouch(_ point: SIMD2<Float>?) {
        os_unfair_lock_lock(&lock)
        virtualTouch = point
        os_unfair_lock_unlock(&lock)
    }

    /// Presses a button for 120 ms (used for menu actions like the PS button).
    func tap(button: UInt32) {
        os_unfair_lock_lock(&lock)
        tapButtons |= button
        tapUntil = Date().addingTimeInterval(0.12)
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Polling

    private static func axis(_ v: Float) -> Int16 {
        Int16(max(-1, min(1, v)) * 32767)
    }

    private static func trigger(_ v: Float) -> UInt8 {
        UInt8(max(0, min(1, v)) * 255)
    }

    private func poll() {
        var s = SPController()
        sp_controller_idle(&s)

        os_unfair_lock_lock(&lock)
        var buttons = virtualButtons
        var l2 = virtualL2, r2 = virtualR2
        var left = virtualLeft, right = virtualRight
        let vTouch = virtualTouch
        if Date() < tapUntil { buttons |= tapButtons } else { tapButtons = 0 }
        os_unfair_lock_unlock(&lock)

        var touch: SIMD2<Float>? = vTouch
        if let gp = GCController.controllers().first(where: { $0.extendedGamepad != nil })?.extendedGamepad {
            func on(_ b: GCControllerButtonInput?, _ bit: UInt32) { if b?.isPressed == true { buttons |= bit } }
            on(gp.buttonA, Button.cross)
            on(gp.buttonB, Button.circle)
            on(gp.buttonX, Button.square)
            on(gp.buttonY, Button.triangle)
            on(gp.dpad.left, Button.left)
            on(gp.dpad.right, Button.right)
            on(gp.dpad.up, Button.up)
            on(gp.dpad.down, Button.down)
            on(gp.leftShoulder, Button.l1)
            on(gp.rightShoulder, Button.r1)
            on(gp.leftThumbstickButton, Button.l3)
            on(gp.rightThumbstickButton, Button.r3)
            on(gp.buttonMenu, Button.options)
            on(gp.buttonOptions, Button.share)
            on(gp.buttonHome, Button.ps)
            l2 = max(l2, Self.trigger(gp.leftTrigger.value))
            r2 = max(r2, Self.trigger(gp.rightTrigger.value))
            let ls = SIMD2<Float>(gp.leftThumbstick.xAxis.value, -gp.leftThumbstick.yAxis.value)
            let rs = SIMD2<Float>(gp.rightThumbstick.xAxis.value, -gp.rightThumbstick.yAxis.value)
            if abs(ls.x) + abs(ls.y) > abs(left.x) + abs(left.y) { left = ls }
            if abs(rs.x) + abs(rs.y) > abs(right.x) + abs(right.y) { right = rs }

            if let ds = gp as? GCDualSenseGamepad {
                on(ds.touchpadButton, Button.touchpad)
                let p = ds.touchpadPrimary
                if p.xAxis.value != 0 || p.yAxis.value != 0 {
                    touch = SIMD2((p.xAxis.value + 1) / 2, (1 - p.yAxis.value) / 2)
                }
            } else if let ds4 = gp as? GCDualShockGamepad {
                on(ds4.touchpadButton, Button.touchpad)
                let p = ds4.touchpadPrimary
                if p.xAxis.value != 0 || p.yAxis.value != 0 {
                    touch = SIMD2((p.xAxis.value + 1) / 2, (1 - p.yAxis.value) / 2)
                }
            }
        }

        s.buttons = buttons
        s.l2 = l2
        s.r2 = r2
        s.left_x = Self.axis(left.x)
        s.left_y = Self.axis(left.y)
        s.right_x = Self.axis(right.x)
        s.right_y = Self.axis(right.y)
        if let touch {
            s.touches.0 = SPTouch(x: UInt16(max(0, min(1, touch.x)) * (Self.touchpadWidth - 1)),
                                  y: UInt16(max(0, min(1, touch.y)) * (Self.touchpadHeight - 1)),
                                  id: 0)
        }

        // Send on change, and at least every 50 ms as a keep-alive.
        let now = Date()
        if !Self.equal(s, last) || now.timeIntervalSince(lastSent) > 0.05 {
            last = s
            lastSent = now
            send?(s)
        }
    }

    private static func equal(_ a: SPController, _ b: SPController) -> Bool {
        a.buttons == b.buttons && a.l2 == b.l2 && a.r2 == b.r2 &&
        a.left_x == b.left_x && a.left_y == b.left_y && a.right_x == b.right_x && a.right_y == b.right_y &&
        a.touches.0.id == b.touches.0.id && a.touches.0.x == b.touches.0.x && a.touches.0.y == b.touches.0.y
    }

    // MARK: - Rumble

    private func setupHaptics(_ controller: GCController?) {
        rumblePlayer = nil
        hapticEngine?.stop()
        hapticEngine = nil
        guard AppStore.shared.hapticsEnabled else { return }
        let engine: CHHapticEngine?
        if let controller {
            engine = controller.haptics?.createEngine(withLocality: .default)
        } else if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            engine = try? CHHapticEngine()
        } else {
            engine = nil
        }
        guard let engine else { return }
        engine.isAutoShutdownEnabled = true
        try? engine.start()
        hapticEngine = engine
    }

    func rumble(left: UInt8, right: UInt8) {
        hapticQueue.async { [weak self] in
            guard let self, let engine = self.hapticEngine else { return }
            let strength = Float(max(left, right)) / 255
            do {
                if strength <= 0.02 {
                    try self.rumblePlayer?.stop(atTime: CHHapticTimeImmediate)
                    return
                }
                if self.rumblePlayer == nil {
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
                    ], relativeTime: 0, duration: 30)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    self.rumblePlayer = try engine.makeAdvancedPlayer(with: pattern)
                }
                try engine.start()
                let param = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: strength, relativeTime: 0)
                try self.rumblePlayer?.sendParameters([param], atTime: CHHapticTimeImmediate)
                try self.rumblePlayer?.start(atTime: CHHapticTimeImmediate)
            } catch {
                self.rumblePlayer = nil
            }
        }
    }
}
