import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality", selection: $store.quality) {
                        ForEach(StreamQuality.allCases) { q in
                            VStack(alignment: .leading) {
                                Text(q.title)
                                Text(q.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(q)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Stream quality")
                } footer: {
                    Text("Lower quality needs less Wi-Fi and lags less. Start with Balanced; drop to Smooth if the picture stutters.")
                }

                Section {
                    Picker("Away quality", selection: $store.awayQuality) {
                        ForEach(StreamQuality.allCases) { q in Text(q.title).tag(q) }
                    }
                    Toggle("Hotspot / cellular mode", isOn: $store.portGuessing)
                } header: {
                    Text("Playing away from home")
                } footer: {
                    Text(store.psnTokens == nil
                         ? "To play away from home, sign in to PlayStation below. Your PS5 needs \"Stay Connected to the Internet\" turned on in rest mode."
                         : "Ready. Consoles on your PlayStation account can be played from anywhere. Turn on Hotspot mode if connecting fails on a phone hotspot or cellular.")
                }

                Section("Video") {
                    Picker("Frame rate", selection: $store.fps) {
                        Text("60 fps").tag(60)
                        Text("30 fps").tag(30)
                    }
                    Toggle("HEVC (PS5)", isOn: $store.useHEVC)
                }

                Section("Controls") {
                    Toggle("On-screen controls", isOn: $store.showTouchControls)
                    Toggle("Rumble", isOn: $store.hapticsEnabled)
                    Toggle("Show connection stats", isOn: $store.showStats)
                }

                Section("PlayStation account") {
                    if let id = store.accountIDBase64 {
                        LabeledContent("Online ID", value: store.onlineID ?? "—")
                        LabeledContent("Account ID", value: id).font(.caption.monospaced())
                        if store.psnTokens == nil {
                            Button("Sign In Again (for playing away)") { showSignIn = true }
                        }
                        Button("Sign Out", role: .destructive) {
                            store.accountID = nil
                            store.onlineID = nil
                            store.psnTokens = nil
                        }
                    } else {
                        Button("Sign In") { showSignIn = true }
                    }
                }

                Section {
                    Button("Show connection log") { showLog = true }
                } footer: {
                    Text("Ski Play uses chiaki-ng, the open-source Remote Play client (AGPL-3.0). Not affiliated with Sony.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showLog) { LogView() }
            .sheet(isPresented: $showSignIn) { SignInView().environmentObject(store) }
        }
    }
}

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = Log.shared.text

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "Nothing logged yet." : text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Connection log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: text) }
            }
        }
    }
}
