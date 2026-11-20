import SwiftUI
import AVFoundation

struct StreamView: View {
    @ObservedObject var session: StreamSession
    @ObservedObject private var input: ControllerInput
    @EnvironmentObject var store: AppStore
    let close: () -> Void

    @State private var showMenu = false
    @State private var pin = ""

    init(session: StreamSession, close: @escaping () -> Void) {
        self.session = session
        self._input = ObservedObject(wrappedValue: session.input)
        self.close = close
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoLayerView(layer: session.decoder.displayLayer)
                .ignoresSafeArea()

            if session.phase == .streaming && store.showTouchControls && input.controllerName == nil {
                TouchControlsView(input: session.input)
            }

            VStack {
                HStack {
                    if store.showStats && session.phase == .streaming {
                        Text(session.stats)
                            .font(.caption2.monospacedDigit())
                            .padding(6)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Spacer()
                    Button { showMenu = true } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(10)
                    }
                }
                Spacer()
            }
            .padding(.horizontal)

            statusOverlay
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            AppDelegate.lock(.landscape)
            session.start()
        }
        .onDisappear {
            session.stop()
            AppDelegate.lock(.portrait)
        }
        .confirmationDialog("Stream", isPresented: $showMenu) {
            Button("PS Button") { session.pressPS() }
            Button(store.showTouchControls ? "Hide On-Screen Controls" : "Show On-Screen Controls") { store.showTouchControls.toggle() }
            Button(store.showStats ? "Hide Stats" : "Show Stats") { store.showStats.toggle() }
            Button("Put Console in Rest Mode") { session.sleepConsole() }
            Button("Disconnect", role: .destructive) { session.stop(); close() }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.phase {
        case .waking:
            StatusCard(title: "Waking up \(session.console.displayName)…", detail: "This can take up to 30 seconds.", spinner: true, close: cancel)
        case .connecting:
            StatusCard(title: "Connecting to \(session.console.displayName)…", detail: nil, spinner: true, close: cancel)
        case .reachingRemote:
            StatusCard(title: "Reaching \(session.console.displayName) over the internet…",
                       detail: "This takes 5–20 seconds. A console in rest mode wakes up on its own.",
                       spinner: true, close: cancel)
        case .needsPIN(let incorrect):
            VStack(spacing: 12) {
                Text(incorrect ? "Wrong PIN — try again" : "Enter your console's Remote Play PIN").font(.headline)
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                HStack {
                    Button("Cancel", action: cancel)
                    Button("OK") { session.enterPIN(pin); pin = "" }.buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .ended(let message):
            if let message {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text("Disconnected").font(.headline)
                    ScrollView {
                        Text(message).font(.subheadline).multilineTextAlignment(.center)
                    }
                    .frame(maxHeight: 160)
                    Button("Close", action: close).buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: 460)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else {
                Color.clear.onAppear { close() }
            }
        case .streaming:
            EmptyView()
        }
    }

    private func cancel() {
        session.stop()
        close()
    }
}

private struct StatusCard: View {
    let title: String
    let detail: String?
    let spinner: Bool
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if spinner { ProgressView().controlSize(.large) }
            Text(title).font(.headline)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            Button("Cancel", action: close).buttonStyle(.bordered)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Hosts the decoder's display layer.
struct VideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        v.backgroundColor = .black
        v.videoLayer = layer
        return v
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}

    final class LayerHostView: UIView {
        var videoLayer: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let videoLayer { layer.addSublayer(videoLayer) }
                setNeedsLayout()
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
