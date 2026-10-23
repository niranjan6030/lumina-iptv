import SwiftUI
import UniformTypeIdentifiers
import LuminaCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var addMode: AddSourceView.Mode?
    @State private var showPINSetup = false
    @State private var showLockedGroups = false
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var message: String?
    @State private var confirmRemove: Source?

    var body: some View {
        NavigationStack {
            Form {
                sourcesSection
                playbackSection
                guideSection
                carPlaySection
                parentalSection
                toolsSection
                backupSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .sheet(item: $addMode) { AddSourceView(mode: $0) }
            .sheet(isPresented: $showPINSetup) { PINSetupView() }
            .sheet(isPresented: $showLockedGroups) { LockedGroupsView() }
            .sheet(item: Binding(get: { exportURL.map(ShareItem.init) }, set: { _ in exportURL = nil })) { ShareSheet(url: $0.url) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
                guard case .success(let url) = r else { return }
                Task {
                    do { try await model.importBackup(url); message = "Backup restored." }
                    catch { message = "That file isn't a Lumina backup." }
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
                Button("Remove source", role: .destructive) { if let s = confirmRemove { model.removeSource(s.id) } }
            } message: { Text("Your favorites stay saved if you add it back.") }
            .miniPlayerInset()
        }
    }

    // MARK: Sections

    private var sourcesSection: some View {
        Section("Sources") {
            ForEach(model.sources) { s in
                NavigationLink { SourceDetailView(source: s) } label: {
                    HStack {
                        Image(systemName: icon(s)).frame(width: 26).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name)
                            Text(summary(s)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions { Button("Remove", role: .destructive) { confirmRemove = s } }
            }
            Menu {
                Button { addMode = .xtream } label: { Label("Xtream login", systemImage: "person.badge.key") }
                Button { addMode = .m3u } label: { Label("M3U link", systemImage: "link") }
                Button { addMode = .file } label: { Label("Playlist file", systemImage: "doc") }
            } label: { Label("Add source", systemImage: "plus.circle.fill") }
        }
    }

    private var playbackSection: some View {
        Section {
            Toggle("Auto-switch to backup stream", isOn: model.binding(\.settings.autoFailover))
            Toggle("Merge duplicate channels", isOn: model.binding(\.settings.mergeDuplicates))
            Toggle("Prefer HLS for .ts links", isOn: model.binding(\.settings.rewriteTSToHLS))
            Toggle("Resume last channel shortcut", isOn: model.binding(\.settings.resumeLastChannel))
            Stepper(value: model.binding(\.settings.forwardBufferSeconds), in: 1...20, step: 1) {
                HStack { Text("Buffer"); Spacer(); Text("\(Int(model.user.settings.forwardBufferSeconds)) s").foregroundStyle(.secondary) }
            }
        } header: { Text("Playback") } footer: {
            Text("Lower buffer = faster channel changes. Raise it on weak connections. Merging combines ‘ESPN’, ‘ESPN HD’ and ‘ESPN FHD’ into one channel with fallbacks.")
        }
    }

    private var guideSection: some View {
        Section("TV guide") {
            Stepper(value: model.binding(\.settings.guideRefreshHours), in: 1...48) {
                HStack { Text("Refresh every"); Spacer(); Text("\(model.user.settings.guideRefreshHours) h").foregroundStyle(.secondary) }
            }
            Button("Refresh guide now") { Task { await model.refreshGuide(force: true) } }
            if let t = model.guideUpdatedAt {
                LabeledContent("Last updated", value: t.formatted(.relative(presentation: .named)))
            }
        }
    }

    private var carPlaySection: some View {
        Section {
            Toggle("Audio only in the car", isOn: model.binding(\.settings.carPlayAudioOnly))
            Stepper(value: model.binding(\.settings.carPlayMaxItems), in: 20...200, step: 20) {
                HStack { Text("List length"); Spacer(); Text("\(model.user.settings.carPlayMaxItems)").foregroundStyle(.secondary) }
            }
        } header: { Text("CarPlay") } footer: {
            Text("Audio only keeps playback smooth and uses far less data. Shorter lists load faster on the car display.")
        }
    }

    private var parentalSection: some View {
        Section {
            Toggle("Hide adult-looking groups", isOn: model.binding(\.settings.hideAdultByDefault))
            Button(model.user.hasPIN ? "Change or remove PIN" : "Set a PIN") { showPINSetup = true }
            if model.user.hasPIN {
                Button("Choose locked groups (\(model.user.lockedGroups.count))") { showLockedGroups = true }
                Button("Lock everything again") { model.lockAll() }
            }
        } header: { Text("Parental control") } footer: {
            Text("Locked groups ask for the PIN before they open or play, including on CarPlay.")
        }
    }

    private var toolsSection: some View {
        Section("Library tools") {
            if let p = model.scanProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Text("Checking channels… \(p.done) of \(p.total)").font(.caption).foregroundStyle(.secondary)
                    Button("Stop", role: .destructive) { model.cancelScan() }
                }
            } else {
                Button("Find dead channels") { model.scanForDeadChannels() }
                if !model.deadChannels.isEmpty {
                    Text("\(model.deadChannels.count) channels didn't respond.").font(.footnote).foregroundStyle(.secondary)
                    Button("Hide dead channels") { model.applyDeadChannelHiding() }
                }
            }
            if !model.user.hiddenChannels.isEmpty || !model.user.hiddenGroups.isEmpty {
                Button("Show \(model.user.hiddenChannels.count) hidden channels again") { model.unhideAll() }
            }
        }
    }

    private var backupSection: some View {
        Section {
            Button("Export backup") {
                exportURL = try? model.exportBackup()
            }
            Button("Restore from backup") { importing = true }
        } header: { Text("Backup") } footer: {
            Text("Includes sources (with logins), favorites and settings. Keep the file private.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            Text("Lumina is a player. It does not provide or endorse any content.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func icon(_ s: Source) -> String {
        switch s.kind {
        case .demo: "sparkles"
        case .m3u(let u): u.isFileURL ? "doc.text" : "link"
        case .xtream: "person.badge.key"
        }
    }

    private func summary(_ s: Source) -> String {
        var parts: [String] = []
        if let a = model.accounts[s.id], let d = a.daysRemaining { parts.append(d >= 0 ? "\(d) days left" : "expired") }
        if let t = s.lastRefreshed { parts.append("updated \(t.formatted(.relative(presentation: .named)))") }
        return parts.isEmpty ? "Not loaded yet" : parts.joined(separator: " · ")
    }
}

struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Source detail

struct SourceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var source: Source
    @State private var extraEPG = ""

    var body: some View {
        Form {
            Section("Name") { TextField("Name", text: $source.name) }
            if let a = model.accounts[source.id] {
                Section("Account") {
                    LabeledContent("Status", value: a.status)
                    if let e = a.expiry { LabeledContent("Expires", value: e.formatted(date: .abbreviated, time: .omitted)) }
                    if let m = a.maxConnections { LabeledContent("Connections", value: "\(a.activeConnections ?? 0) of \(m)") }
                    if a.isTrial { Text("Trial account").foregroundStyle(.secondary) }
                }
            }
            Section {
                TextField("Custom User-Agent (optional)", text: Binding(get: { source.userAgent ?? "" }, set: { source.userAgent = $0.isEmpty ? nil : $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper(value: $source.epgOffsetMinutes, in: -720...720, step: 15) {
                    HStack { Text("Guide time shift"); Spacer(); Text("\(source.epgOffsetMinutes) min").foregroundStyle(.secondary) }
                }
                TextField("Extra guide URL (XMLTV)", text: $extraEPG)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Toggle("Enabled", isOn: $source.enabled)
            } header: { Text("Advanced") } footer: {
                Text("Shift the guide if programmes show up an hour early or late.")
            }
            Section {
                Button("Save changes") {
                    if let u = URL(string: extraEPG.trimmingCharacters(in: .whitespaces)), u.scheme != nil, !source.extraEPG.contains(u) {
                        source.extraEPG.append(u)
                    }
                    model.updateSource(source)
                    dismiss()
                }
                Button("Refresh now") { Task { await model.refresh(source.id) } }
                ForEach(source.extraEPG, id: \.self) { u in
                    Text(u.absoluteString).font(.caption).lineLimit(1)
                        .swipeActions { Button("Remove", role: .destructive) { source.extraEPG.removeAll { $0 == u } } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Add source

struct AddSourceView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case xtream = "Xtream login", m3u = "M3U link", file = "File"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var mode: Mode
    @State private var name = ""
    @State private var url = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    @State private var importing = false

    init(mode: Mode) { _mode = State(initialValue: mode) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    TextField("Name (optional)", text: $name)
                    switch mode {
                    case .xtream:
                        TextField("Server, e.g. http://host:8080", text: $server)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    case .m3u:
                        TextField("https://…/playlist.m3u", text: $url)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        PasteButton(payloadType: String.self) { items in if let s = items.first { url = s } }
                    case .file:
                        Button { importing = true } label: { Label("Choose a .m3u or .m3u8 file", systemImage: "doc.badge.plus") }
                    }
                } footer: {
                    if let note { Text(note).foregroundStyle(Theme.accent) }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.callout) }
                }

                if mode != .file {
                    Section {
                        Button {
                            Task { await submit() }
                        } label: {
                            HStack {
                                if busy { ProgressView() }
                                Text(busy ? "Connecting…" : "Connect").frame(maxWidth: .infinity)
                            }
                        }
                        .glassButtonStyle(prominent: true)
                        .disabled(busy || !canSubmit)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Add source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { r in
                guard case .success(let u) = r else { return }
                Task { await importFile(u) }
            }
            .interactiveDismissDisabled(busy)
        }
        .presentationBackground(.ultraThinMaterial)
    }

    private var canSubmit: Bool {
        switch mode {
        case .xtream: !server.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty
        case .m3u: !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .file: false
        }
    }

    private func submit() async {
        error = nil
        note = nil
        busy = true
        defer { busy = false }
        do {
            switch mode {
            case .xtream:
                guard let s = XtreamClient.normalizeServer(server) else { throw LuminaError.invalidURL }
                let src = Source(name: name.isEmpty ? (s.host ?? "Xtream") : name, kind: .xtream(server: s, username: username.trimmingCharacters(in: .whitespaces), password: password))
                try await model.addSource(src)
            case .m3u:
                var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.lowercased().hasPrefix("http") { text = "http://" + text }
                guard let u = URL(string: text) else { throw LuminaError.invalidURL }
                // A provider's get.php link is really an Xtream login: use the richer API (movies, series, short guide).
                if let c = XtreamClient.credentials(fromPlaylistURL: u) {
                    note = "Detected an Xtream login — using it for movies, series and guide too."
                    try await model.addSource(Source(name: name.isEmpty ? (c.server.host ?? "Xtream") : name, kind: .xtream(server: c.server, username: c.username, password: c.password)))
                } else {
                    try await model.addSource(Source(name: name.isEmpty ? (u.host ?? "Playlist") : name, kind: .m3u(u)))
                }
            case .file: return
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func importFile(_ u: URL) async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            var src = try model.importPlaylistFile(u)
            if !name.isEmpty { src.name = name }
            try await model.addSource(src)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Parental control

struct PINSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if model.user.hasPIN {
                    Section("Current PIN") { SecureField("Current PIN", text: $current).keyboardType(.numberPad) }
                }
                Section("New PIN") {
                    SecureField("4–8 digits", text: $pin).keyboardType(.numberPad)
                    SecureField("Repeat PIN", text: $confirm).keyboardType(.numberPad)
                }
                if let error { Text(error).foregroundStyle(.yellow) }
                Section {
                    Button("Save PIN") { save() }.disabled(pin.count < 4)
                    if model.user.hasPIN { Button("Remove PIN", role: .destructive) { remove() } }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationBackground(.ultraThinMaterial)
    }

    private func save() {
        if model.user.hasPIN, !model.user.verifyPIN(current) { error = "Current PIN is wrong."; return }
        guard pin == confirm else { error = "PINs don't match."; return }
        guard pin.count >= 4, pin.count <= 8, pin.allSatisfy(\.isNumber) else { error = "Use 4 to 8 digits."; return }
        model.updateUser { $0.setPIN(pin) }
        dismiss()
    }

    private func remove() {
        guard model.user.verifyPIN(current) else { error = "Enter the current PIN first."; return }
        model.updateUser { $0.setPIN(nil); $0.lockedGroups.removeAll() }
        dismiss()
    }
}

struct LockedGroupsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(model.allGroups.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }) { g in
                Toggle(isOn: Binding(
                    get: { model.user.lockedGroups.contains(g.id) },
                    set: { on in model.updateUser { if on { $0.lockedGroups.insert(g.id) } else { $0.lockedGroups.remove(g.id) } } }
                )) {
                    VStack(alignment: .leading) {
                        Text(g.label.title)
                        Text("\(g.count) channels").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .searchable(text: $query)
            .navigationTitle("Locked groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationBackground(.ultraThinMaterial)
    }
}

struct PINPromptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PINRequest
    @State private var pin = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Theme.gradient)
            Text("Enter PIN").font(.title3.weight(.semibold))
            Text(GroupLabel.parse(request.group).title).font(.subheadline).foregroundStyle(.secondary)
            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad).multilineTextAlignment(.center).font(.title2)
                .padding().glass(16)
                .onChange(of: pin) { _, v in
                    wrong = false
                    if model.user.verifyPIN(v), v.count >= 4 { succeed() } // auto-unlock the moment it's right
                }
            if wrong { Text("Wrong PIN").foregroundStyle(.yellow).font(.footnote) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.glassButtonStyle()
                Button("Unlock") { if !tryUnlock() { wrong = true; pin = "" } }.glassButtonStyle(prominent: true)
            }
        }
        .padding(28)
        .presentationDetents([.height(360)])
        .presentationBackground(.ultraThinMaterial)
    }

    private func tryUnlock() -> Bool { model.unlock(group: request.group, pin: pin) }

    private func succeed() {
        guard tryUnlock() else { return }
        dismiss()
        // Let the sheet finish dismissing before the player cover presents.
        let action = request.onSuccess
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
    }
}
