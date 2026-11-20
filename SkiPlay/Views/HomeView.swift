import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var discovery: Discovery
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSignIn = false
    @State private var showSettings = false
    @State private var linkTarget: LinkTarget?
    @State private var streaming: StreamSession?
    @State private var renaming: Console?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.accountID == nil || store.psnTokens == nil {
                        signInCard
                    }
                    consolesSection
                    foundSection
                    tipsCard
                }
                .padding()
            }
            .navigationTitle("Ski Play")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if discovery.scanning {
                        ProgressView()
                    } else {
                        Button { discovery.scan(full: true) } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
        }
        .onAppear {
            discovery.start()
            Task { await PSNDevices.sync() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                discovery.start(); discovery.scan(full: true)
                Task { await PSNDevices.sync() }
            }
            if phase == .background && streaming == nil { discovery.stop() }
        }
        .sheet(isPresented: $showSignIn) { SignInView().environmentObject(store) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .sheet(item: $linkTarget) { target in
            LinkView(target: target) { linkTarget = nil }.environmentObject(store)
        }
        .fullScreenCover(item: $streaming) { session in
            StreamView(session: session) { streaming = nil }.environmentObject(store)
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if var c = renaming { c.nickname = newName; store.upsert(c) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: - Sections

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(store.accountID == nil ? "Sign in to PlayStation" : "Sign in again to play away from home",
                  systemImage: store.accountID == nil ? "person.crop.circle.badge.checkmark" : "globe")
                .font(.headline)
            Text(store.accountID == nil
                 ? "Your console needs your PlayStation account to link with this phone, and to play from anywhere. You only do this once."
                 : "One more sign-in lets you play your PS5 from anywhere — like at your parents' house.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showSignIn = true } label: {
                Text("Sign In").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var consolesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My Consoles").font(.title3.bold())
            if store.consoles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "playstation.logo").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No linked consoles yet").font(.headline)
                    Text("Turn on your PS5 and make sure it's on the same Wi-Fi. It will show up below — tap Link.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(store.consoles) { console in
                ConsoleCard(console: console,
                            status: discovery.status(for: console),
                            play: { play(console) },
                            wake: { wake(console) })
                .contextMenu {
                    Button { newName = console.nickname; renaming = console } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) {
                        store.consoles.removeAll { $0.id == console.id }
                    } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
    }

    private var unlinked: [FoundConsole] {
        discovery.found.values
            .filter { f in !store.consoles.contains { $0.id.caseInsensitiveCompare(f.hostID) == .orderedSame } }
            .sorted { $0.name < $1.name }
    }

    private var foundSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("On Your Network").font(.title3.bold())
                Spacer()
                Button("Add by IP") { linkTarget = LinkTarget(found: nil) }
                    .font(.subheadline)
            }
            if unlinked.isEmpty {
                Text(discovery.scanning ? "Looking for consoles…" : "No other consoles found. If yours is on, make sure Remote Play is turned on and the phone is on the same Wi-Fi.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(unlinked) { f in
                HStack {
                    Image(systemName: "playstation.logo").font(.title2)
                    VStack(alignment: .leading) {
                        Text(f.name).font(.headline)
                        Text("\(f.ps5 ? "PS5" : "PS4") · \(f.address) · \(f.state == .on ? "On" : "Rest mode")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Link") {
                        if store.accountID == nil { showSignIn = true } else { linkTarget = LinkTarget(found: f) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var tipsCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Tip("cable.connector", "Plug the PS5 into the router with an Ethernet cable — the biggest fix for lag.")
                Tip("wifi", "Keep the phone on 5 GHz Wi-Fi (not 2.4 GHz), close to the router.")
                Tip("slider.horizontal.3", "Still choppy? Settings › Quality › Smooth.")
                Tip("globe", "Away from home, your home internet's upload speed matters most. If it stutters, set Away quality to Smooth.")
                Tip("moon.zzz", "PS5 › Settings › System › Power Saving › Features in Rest Mode › turn on \"Stay Connected to the Internet\" and \"Enable Turning On PS5 from Network\" so the app can wake it.")
            }
            .padding(.top, 8)
        } label: {
            Label("Tips for a smooth stream", systemImage: "bolt.horizontal.circle").font(.headline)
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Actions

    private func play(_ console: Console) {
        let session = StreamSession(console: console)
        streaming = session
    }

    private func wake(_ console: Console) {
        let host = discovery.status(for: console)?.address ?? console.host
        let key = [UInt8](console.registKey.prefix(16)) + [UInt8](repeating: 0, count: max(0, 16 - console.registKey.count))
        key.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: 16) { _ = sp_wakeup(host, $0, console.ps5) }
        }
    }
}

struct LinkTarget: Identifiable {
    let id = UUID()
    var found: FoundConsole?
}

extension StreamSession: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

private struct Tip: View {
    let icon: String
    let text: String
    init(_ icon: String, _ text: String) { self.icon = icon; self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Theme.accent)
            Text(text).font(.subheadline)
        }
    }
}

struct ConsoleCard: View {
    let console: Console
    let status: FoundConsole?
    let play: () -> Void
    let wake: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.25)).frame(width: 54, height: 54)
                    Image(systemName: "playstation.logo").font(.title)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(console.displayName).font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    if let app = status?.runningApp, status?.state == .on {
                        Text(app).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            HStack {
                Button(action: play) {
                    Label(playTitle, systemImage: status == nil && console.canPlayRemotely ? "globe" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(status == nil && !console.canPlayRemotely && !console.isLinkedLocally)
                if status?.state == .rest {
                    Button(action: wake) { Image(systemName: "power") }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var playTitle: String {
        if status == nil && console.canPlayRemotely { return "Play over Internet" }
        return status?.state == .rest ? "Wake & Play" : "Play"
    }

    private var color: Color {
        if status == nil && console.canPlayRemotely { return Theme.accent }
        switch status?.state {
        case .on: return Theme.on
        case .rest: return Theme.rest
        default: return .gray
        }
    }

    private var statusText: String {
        switch status?.state {
        case .on: return "On · \(status?.address ?? console.host)"
        case .rest: return "Rest mode · \(status?.address ?? console.host)"
        default:
            if console.canPlayRemotely { return "Away from home · plays through PlayStation Network" }
            return "Not found on this Wi-Fi · \(console.host)"
        }
    }
}
