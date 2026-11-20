import SwiftUI

struct SignInView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?
    @State private var manual = false
    @State private var manualID = ""

    var body: some View {
        NavigationStack {
            Group {
                if manual {
                    Form {
                        Section {
                            TextField("Account ID (base64)", text: $manualID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body.monospaced())
                        } footer: {
                            Text("If you already have your PSN account ID from another Remote Play app (like chiaki-ng), paste it here.")
                        }
                        Button("Save") {
                            if store.setAccountID(base64: manualID) { dismiss() } else { error = "That doesn't look like an account ID (it should be 12 characters ending in =)." }
                        }
                    }
                } else if working {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Getting your account ID…").foregroundStyle(.secondary)
                    }
                } else {
                    PSNLoginView { code in
                        working = true
                        Task {
                            do {
                                let result = try await PSNAuth.accountID(fromCode: code)
                                await MainActor.run {
                                    store.accountID = result.id
                                    store.onlineID = result.onlineID
                                    store.psnTokens = result.tokens
                                    Task { await PSNDevices.sync() }
                                    dismiss()
                                }
                            } catch {
                                await MainActor.run {
                                    self.error = error.localizedDescription
                                    working = false
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("PlayStation Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(manual ? "Sign In" : "Enter ID") { manual.toggle() }
                }
            }
            .alert("Sign-in problem", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }
}

struct LinkView: View {
    @EnvironmentObject var store: AppStore
    let target: LinkTarget
    let done: () -> Void

    @State private var host = ""
    @State private var ps5 = true
    @State private var pin = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Step(n: 1, "On the PS5: Settings › System › Remote Play › turn on Enable Remote Play.")
                        Step(n: 2, "Choose Link Device. An 8-digit code appears on the TV.")
                        Step(n: 3, "Type the code below within 5 minutes.")
                    }
                    .padding(.vertical, 4)
                }
                Section("Console") {
                    if let f = target.found {
                        LabeledContent("Name", value: f.name)
                        LabeledContent("Address", value: f.address)
                    } else {
                        TextField("IP address (e.g. 192.168.1.50)", text: $host)
                            .keyboardType(.decimalPad)
                        Picker("Type", selection: $ps5) {
                            Text("PS5").tag(true)
                            Text("PS4").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Code from the TV") {
                    TextField("12345678", text: $pin)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                        .onChange(of: pin) { _, v in pin = String(v.filter(\.isNumber).prefix(8)) }
                }
                Section {
                    Button {
                        link()
                    } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text("Link").bold() }
                            Spacer()
                        }
                    }
                    .disabled(working || pin.count != 8 || (target.found == nil && host.isEmpty) || store.accountID == nil)
                } footer: {
                    if store.accountID == nil {
                        Text("Sign in to PlayStation first (on the home screen).")
                    }
                }
            }
            .navigationTitle("Link Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) } }
            .alert("Couldn't link", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func link() {
        guard let account = store.accountID, let code = UInt32(pin) else { return }
        let address = target.found?.address ?? host.trimmingCharacters(in: .whitespaces)
        let isPS5 = target.found?.ps5 ?? ps5
        working = true
        Task {
            do {
                var console = try await Registration.link(host: address, ps5: isPS5, accountID: account, pin: code)
                if console.nickname.isEmpty, let name = target.found?.name { console.nickname = name }
                let linked = console
                await MainActor.run {
                    if !store.manualHosts.contains(address) && target.found == nil { store.manualHosts.append(address) }
                    store.upsert(linked)
                    working = false
                    done()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    working = false
                }
            }
        }
    }
}

private struct Step: View {
    let n: Int
    let text: String
    init(n: Int, _ text: String) { self.n = n; self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.bold()).frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}
