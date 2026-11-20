import SwiftUI

/// On-screen DualSense layout for when no controller is connected.
struct TouchControlsView: View {
    let input: ControllerInput
    typealias B = ControllerInput.Button

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let unit = min(64, h / 6.2)
            ZStack {
                // Shoulders
                VStack {
                    HStack {
                        VStack(spacing: 8) {
                            TriggerButton(label: "L2", unit: unit) { input.setVirtualTrigger(left: true, pressed: $0) }
                            PadButton(label: "L1", unit: unit, wide: true) { input.setVirtual(button: B.l1, pressed: $0) }
                        }
                        Spacer()
                        VStack(spacing: 8) {
                            TriggerButton(label: "R2", unit: unit) { input.setVirtualTrigger(left: false, pressed: $0) }
                            PadButton(label: "R1", unit: unit, wide: true) { input.setVirtual(button: B.r1, pressed: $0) }
                        }
                    }
                    Spacer()
                }
                .padding(.top, 8)

                // Center: touchpad, Create, Options, PS
                VStack(spacing: 10) {
                    TouchpadArea(input: input)
                        .frame(width: geo.size.width * 0.3, height: unit * 1.3)
                    HStack(spacing: geo.size.width * 0.12) {
                        PadButton(label: "Create", unit: unit * 0.7, wide: true) { input.setVirtual(button: B.share, pressed: $0) }
                        PadButton(label: "Options", unit: unit * 0.7, wide: true) { input.setVirtual(button: B.options, pressed: $0) }
                    }
                    Spacer()
                    PadButton(systemImage: "playstation.logo", unit: unit * 0.75) { input.setVirtual(button: B.ps, pressed: $0) }
                        .padding(.bottom, 6)
                }
                .padding(.top, 6)

                // Left: d-pad and stick
                HStack {
                    VStack(spacing: 0) {
                        Spacer().frame(height: unit * 1.9)
                        DPad(input: input, unit: unit)
                        Spacer()
                        Stick(left: true, input: input, size: unit * 2.1)
                            .padding(.leading, unit * 1.4)
                    }
                    Spacer()
                    VStack(spacing: 0) {
                        Spacer().frame(height: unit * 1.9)
                        FaceButtons(input: input, unit: unit)
                        Spacer()
                        Stick(left: false, input: input, size: unit * 2.1)
                            .padding(.trailing, unit * 1.4)
                    }
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 20)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct PressArea<Content: View>: View {
    let onChange: (Bool) -> Void
    @ViewBuilder var content: (Bool) -> Content
    @State private var pressed = false

    var body: some View {
        content(pressed)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed { pressed = true; onChange(true); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
                .onEnded { _ in pressed = false; onChange(false) })
    }
}

private struct PadButton: View {
    var label: String? = nil
    var systemImage: String? = nil
    let unit: CGFloat
    var wide = false
    let onChange: (Bool) -> Void

    init(label: String, unit: CGFloat, wide: Bool = false, onChange: @escaping (Bool) -> Void) {
        self.label = label; self.unit = unit; self.wide = wide; self.onChange = onChange
    }
    init(systemImage: String, unit: CGFloat, onChange: @escaping (Bool) -> Void) {
        self.systemImage = systemImage; self.unit = unit; self.onChange = onChange
    }

    var body: some View {
        PressArea(onChange: onChange) { pressed in
            Group {
                if let systemImage { Image(systemName: systemImage) } else { Text(label ?? "").font(.system(size: unit * 0.28, weight: .semibold)) }
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: wide ? unit * 1.5 : unit, height: wide ? unit * 0.62 : unit)
            .background(Capsule().fill(.white.opacity(pressed ? 0.35 : 0.12)))
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
        }
    }
}

private struct TriggerButton: View {
    let label: String
    let unit: CGFloat
    let onChange: (Bool) -> Void
    var body: some View {
        PressArea(onChange: onChange) { pressed in
            Text(label).font(.system(size: unit * 0.28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: unit * 1.5, height: unit * 0.62)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(pressed ? 0.35 : 0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.25), lineWidth: 1))
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    let color: Color
    let unit: CGFloat
    let onChange: (Bool) -> Void
    var body: some View {
        PressArea(onChange: onChange) { pressed in
            Image(systemName: symbol)
                .font(.system(size: unit * 0.38, weight: .bold))
                .foregroundStyle(color)
                .frame(width: unit, height: unit)
                .background(Circle().fill(.white.opacity(pressed ? 0.35 : 0.1)))
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
    }
}

private struct FaceButtons: View {
    let input: ControllerInput
    let unit: CGFloat
    typealias B = ControllerInput.Button
    var body: some View {
        VStack(spacing: 0) {
            RoundButton(symbol: "triangle", color: .green, unit: unit) { input.setVirtual(button: B.triangle, pressed: $0) }
            HStack(spacing: unit) {
                RoundButton(symbol: "square", color: .pink, unit: unit) { input.setVirtual(button: B.square, pressed: $0) }
                RoundButton(symbol: "circle", color: .red, unit: unit) { input.setVirtual(button: B.circle, pressed: $0) }
            }
            RoundButton(symbol: "xmark", color: .cyan, unit: unit) { input.setVirtual(button: B.cross, pressed: $0) }
        }
    }
}

private struct DPad: View {
    let input: ControllerInput
    let unit: CGFloat
    typealias B = ControllerInput.Button
    var body: some View {
        VStack(spacing: 0) {
            RoundButton(symbol: "arrowtriangle.up.fill", color: .white, unit: unit) { input.setVirtual(button: B.up, pressed: $0) }
            HStack(spacing: unit) {
                RoundButton(symbol: "arrowtriangle.left.fill", color: .white, unit: unit) { input.setVirtual(button: B.left, pressed: $0) }
                RoundButton(symbol: "arrowtriangle.right.fill", color: .white, unit: unit) { input.setVirtual(button: B.right, pressed: $0) }
            }
            RoundButton(symbol: "arrowtriangle.down.fill", color: .white, unit: unit) { input.setVirtual(button: B.down, pressed: $0) }
        }
    }
}

private struct Stick: View {
    let left: Bool
    let input: ControllerInput
    let size: CGFloat
    @State private var offset: CGSize = .zero
    @State private var lastTap = Date.distantPast

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08)).overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            Circle().fill(.white.opacity(0.3)).frame(width: size * 0.45, height: size * 0.45)
                .offset(offset)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if offset == .zero && v.translation == .zero {
                    // Double-tap the stick to click it (L3 / R3).
                    if Date().timeIntervalSince(lastTap) < 0.3 {
                        input.tap(button: left ? ControllerInput.Button.l3 : ControllerInput.Button.r3)
                    }
                    lastTap = Date()
                }
                let radius = size / 2
                var dx = v.translation.width, dy = v.translation.height
                let len = sqrt(dx * dx + dy * dy)
                if len > radius { dx = dx / len * radius; dy = dy / len * radius }
                offset = CGSize(width: dx, height: dy)
                input.setVirtualStick(left: left, SIMD2(Float(dx / radius), Float(dy / radius)))
            }
            .onEnded { _ in
                offset = .zero
                input.setVirtualStick(left: left, .zero)
            })
    }
}

private struct TouchpadArea: View {
    let input: ControllerInput
    @State private var touching = false

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(touching ? 0.18 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2), lineWidth: 1))
                .overlay(Text("Touchpad").font(.caption2).foregroundStyle(.white.opacity(0.4)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !touching {
                            touching = true
                            input.setVirtual(button: ControllerInput.Button.touchpad, pressed: true)
                        }
                        let x = Float(max(0, min(1, v.location.x / geo.size.width)))
                        let y = Float(max(0, min(1, v.location.y / geo.size.height)))
                        input.setVirtualTouch(SIMD2(x, y))
                    }
                    .onEnded { _ in
                        touching = false
                        input.setVirtual(button: ControllerInput.Button.touchpad, pressed: false)
                        input.setVirtualTouch(nil)
                    })
        }
    }
}
