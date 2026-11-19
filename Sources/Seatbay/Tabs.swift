import AppKit
import SeatbayCore
import SwiftUI

// MARK: Shared pieces

struct ActivityBanner: View {
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var updates: UpdateCoordinator


    var body: some View {
        if let text = updates.phase.isWorking ? workingText : store.backupStatus {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10)))
        }
    }

    private var workingText: String? {
        if case .working(let text) = updates.phase { return text }
        return nil
    }
}

struct NoticeList: View {
    @EnvironmentObject private var store: InstanceStore

    var body: some View {
        ForEach(store.notices.prefix(3)) { notice in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(notice.kind == .warning ? Color.orange : Color.accentColor)
                Text(notice.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(notice.date, style: .time).font(.caption).foregroundStyle(.secondary)
                Button { store.dismissNotice(notice) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill((notice.kind == .warning ? Color.orange : Color.accentColor).opacity(0.10)))
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

struct SleepCard: View {
    @EnvironmentObject private var store: InstanceStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 22))
                .foregroundStyle(store.settings.sleepEnabled ? Color.indigo : Color.secondary)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sleep idle instances").font(.headline)
                Text("Quits an instance after it has been in the background with nothing running for a while, to free memory. Never while it is working (a Code session running), and never the main Claude. Open it to wake it; its sessions are still there.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.settings.sleepEnabled {
                    Picker("After", selection: Binding(get: { store.settings.sleepAfterMinutes },
                                                       set: { value in store.updateSettings { $0.sleepAfterMinutes = value } })) {
                        ForEach([15, 30, 60, 120, 240], id: \.self) { Text(minutes($0)).tag($0) }
                    }
                    .frame(maxWidth: 220)
                }
            }
            Spacer(minLength: 12)
            Toggle("Sleep idle instances", isOn: Binding(get: { store.settings.sleepEnabled },
                                                         set: { value in store.updateSettings { $0.sleepEnabled = value } }))
                .toggleStyle(.switch).labelsHidden()
        }
        .padding(14)
        .cardBackground()
    }

    private func minutes(_ value: Int) -> String { value < 60 ? "\(value) minutes" : "\(value / 60) hour\(value >= 120 ? "s" : "")" }
}

// MARK: Health

struct HealthTab: View {
    @EnvironmentObject private var store: InstanceStore
    @State private var confirmRestartAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary
                ForEach(store.allTargets) { target in HealthRow(target: target) }
                HStack {
                    Button("Measure Disk Use Now") { store.refreshDiskSizes() }
                    Button("Restart All Claudes…") { confirmRestartAll = true }
                        .help("Closes every open Claude, backs each up, and reopens them (applies a downloaded update too)")
                    Spacer()
                }
                Text("Signed in is read from each Claude's config.json (key names only, never the tokens). Memory and CPU include each Claude's helpers, Claude Code and MCP servers. “Working” means Claude is holding the Mac awake for a running session.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .confirmationDialog("Restart every open Claude?", isPresented: $confirmRestartAll, titleVisibility: .visible) {
            Button("Restart All") { Task { await store.updates.updateAll(trigger: "Restart All", requireUpdate: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running Code sessions stop and resume when Claude reopens. Each Claude is backed up while it's closed.")
        }
    }

    private var summary: some View {
        let open = store.allTargets.compactMap { store.health[$0.id] }.filter { $0.pid != nil }
        let memory = open.reduce(UInt64(0)) { $0 + $1.memory }
        let measured = store.allTargets.contains { store.health[$0.id]?.dataBytes != nil }
        let disk = store.allTargets.compactMap { store.health[$0.id]?.dataBytes }.reduce(0, +)
        let caches = store.allTargets.compactMap { store.health[$0.id]?.cacheBytes }.reduce(0, +)
        let signedOut = store.allTargets.filter { store.health[$0.id]?.signedIn == false }.count
        return HStack(spacing: 12) {
            stat("\(open.count) of \(store.allTargets.count)", "open")
            stat(ByteFormat.string(memory), "memory in use")
            stat(measured ? ByteFormat.file(disk) : "…", measured ? "on disk (\(ByteFormat.file(caches)) caches)" : "on disk")
            stat("\(signedOut)", signedOut == 1 ? "signed out" : "signed out", warn: signedOut > 0)
        }
    }

    private func stat(_ value: String, _ label: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(warn ? Color.orange : Color.primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

struct HealthRow: View {
    let target: ClaudeTarget
    @EnvironmentObject private var store: InstanceStore

    var body: some View {
        let h = store.health[target.id] ?? TargetHealth()
        HStack(alignment: .center, spacing: 12) {
            icon.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(target.name).font(.headline)
                    StatusPill(running: h.pid != nil, sleeping: target.instance.map { store.sleeping.contains($0.id) } ?? false,
                               working: h.working)
                    if h.signedIn == false { badge("Signed out", .orange) }
                    if h.outdated { badge("Restart to update", .blue) }
                    if h.sharesClaudeApp {
                        badge("Restart once", .orange)
                            .help("Opened by an earlier Seatbay, so macOS still mixes it up with the regular Claude. Quit and reopen it once.")
                    }
                    if target.usesAPI { badge("API key", .secondary) }
                }
                Text(detail(h)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if h.pid == nil, (h.cacheBytes ?? 0) > 50_000_000 {
                Button("Clear \(ByteFormat.file(h.cacheBytes ?? 0)) Caches") { store.clearCaches(target) }
                    .help("Deletes caches Claude rebuilds by itself. Only while it's closed.")
            }
        }
        .padding(12)
        .cardBackground()
    }

    @ViewBuilder private var icon: some View {
        if let instance = target.instance, let image = store.icons[instance.id] {
            Image(nsImage: image).resizable()
        } else {
            Image(nsImage: store.mainClaudeIcon).resizable()
        }
    }

    private func detail(_ h: TargetHealth) -> String {
        var parts: [String] = []
        if h.pid != nil {
            parts.append("\(ByteFormat.string(h.memory)) memory")
            parts.append(String(format: "%.0f%% CPU", h.cpuPercent))
            parts.append("\(h.processCount) processes")
            if !h.working, let idle = h.idleMinutes, idle > 0 { parts.append("idle \(idle) min") }
        }
        if let data = h.dataBytes, data > 0 { parts.append("\(ByteFormat.file(data)) on disk") }
        if let last = store.lastBackup(of: target) {
            parts.append("backed up \(last.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("never backed up")
        }
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}


struct NightlyCard: View {
    @EnvironmentObject private var store: InstanceStore

    var body: some View {
        let s = store.settings
        let state = store.nightly
        let cloud = s.s3.enabled && s.s3.isConfigured
        return SectionCard(title: "Nightly backup",
                           subtitle: "Every night, each Claude that changed is backed up\(cloud ? " and uploaded to \(s.s3.bucket)" : "") — open ones too, from an instant copy of their folder, so nothing is closed. If the Mac was asleep or off, or the round failed, it runs as soon as the Mac is awake and retries every 30 minutes until it succeeds.") {
            HStack(spacing: 16) {
                Toggle("Back up every Claude each night", isOn: Binding(get: { s.nightlyBackup },
                                                                        set: { v in store.updateSettings { $0.nightlyBackup = v } }))
                Picker("between", selection: Binding(get: { s.nightlyHour }, set: { v in store.updateSettings { $0.nightlyHour = v } })) {
                    ForEach(0..<24, id: \.self) { hour in Text(String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)).tag(hour) }
                }
                .frame(maxWidth: 210)
                .disabled(!s.nightlyBackup)
                Spacer()
                Button("Back Up Everything Now") { Task { await store.backUpEverythingNow() } }
                    .help("Backs up every Claude now (open ones without closing them) and uploads what isn't in S3 yet")
                    .disabled(store.backupStatus != nil || store.updates.phase.isWorking)
            }
            if s.nightlyBackup {
                VStack(alignment: .leading, spacing: 3) {
                    if let done = state.lastSuccess {
                        Label("Last complete round \(done.formatted(.relative(presentation: .named)))\(state.lastSummary.map { ": \($0)" } ?? "")",
                              systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        Label("No complete round yet.", systemImage: "clock").foregroundStyle(.secondary)
                    }
                    if let problem = state.lastError, state.failuresInARow > 0 {
                        Label("Last try \(state.lastAttempt?.formatted(date: .omitted, time: .shortened) ?? "") didn't finish: \(problem)",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if let next = NightlyBackup.nextRun(settings: s, state: state) {
                        Text(next <= Date().addingTimeInterval(60) ? "Next round: now (runs within 30 minutes)" : "Next round: \(next.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.tertiary)
                    }
                    if !cloud {
                        Text("S3 is off, so these backups stay on this Mac. Set up S3 below to keep a copy off it.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
        }
    }

}

// MARK: Backups

struct BackupsTab: View {
    @EnvironmentObject private var store: InstanceStore
    @State private var pendingRestore: (SnapshotInfo, ClaudeTarget)?
    @State private var remote: [S3Backup.Remote] = []
    @State private var remoteError: String?
    @State private var loadingRemote = false
    @State private var newInstanceFrom: S3Backup.Remote?
    @State private var newInstanceName = ""
    @State private var pendingDeleteBackup: SnapshotInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                NightlyCard()
                settingsCard
                ForEach(store.allTargets) { target in targetCard(target) }
                S3Card(remote: $remote, remoteError: $remoteError, loading: $loadingRemote,
                       onRestoreAsNew: { item in newInstanceFrom = item; newInstanceName = "" })
            }
            .padding(16)
        }
        .confirmationDialog(restoreTitle, isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Restore") {
                if let (info, target) = pendingRestore { Task { await store.restore(info, into: target) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If it's open, it closes first. Its current state is backed up before anything is replaced, and the replaced folder goes to the Trash.")
        }
        .confirmationDialog("Delete the backup of \(pendingDeleteBackup?.targetName ?? "") from \(pendingDeleteBackup?.createdAt.formatted(date: .abbreviated, time: .shortened) ?? "")?",
                            isPresented: Binding(get: { pendingDeleteBackup != nil }, set: { if !$0 { pendingDeleteBackup = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let info = pendingDeleteBackup { store.deleteSnapshot(info) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingDeleteBackup?.uploadedAt == nil
                 ? "It's deleted from this Mac for good; it isn't in S3."
                 : "It's deleted from this Mac for good. The copy in S3 stays.")
        }
        .sheet(item: $newInstanceFrom) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("Restore as a New Instance").font(.title3.weight(.bold))
                Text("Creates a new instance from \(item.snapshotID) (backed up on \(item.machine)). Sessions, settings and MCP config come back; the sign-in only carries over on the Mac that made the backup.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Name for the new instance", text: $newInstanceName).textFieldStyle(.roundedBorder)
                let problem = newInstanceName.isEmpty ? "Enter a name" : store.nameProblem(newInstanceName, excluding: nil)
                if let problem, !newInstanceName.isEmpty { Text(problem).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel") { newInstanceFrom = nil }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        let name = newInstanceName
                        newInstanceFrom = nil
                        Task { await store.restoreRemoteAsNewInstance(item, name: name) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
                }
            }
            .padding(22)
            .frame(width: 480)
        }
    }

    private var restoreTitle: String {
        guard let (info, target) = pendingRestore else { return "Restore?" }
        return "Restore \(target.name) to \(info.createdAt.formatted(date: .abbreviated, time: .shortened))?"
    }

    private var settingsCard: some View {
        SectionCard(title: "Backups on quit",
                    subtitle: "A backup holds a Claude's sign-in, settings, MCP config and session history, without caches or downloaded runtimes (usually a few MB). The cleanest backup is the one taken right after a Claude quits.") {
            Toggle("Back up each Claude when it quits", isOn: Binding(get: { store.settings.backupOnQuit },
                                                                     set: { v in store.updateSettings { $0.backupOnQuit = v } }))
            HStack(spacing: 16) {
                Picker("At most every", selection: Binding(get: { store.settings.backupMinIntervalHours },
                                                           set: { v in store.updateSettings { $0.backupMinIntervalHours = v } })) {
                    Text("time it quits").tag(0)
                    ForEach([1, 6, 12, 24], id: \.self) { Text("\($0) hour\($0 == 1 ? "" : "s")").tag($0) }
                }
                .frame(maxWidth: 260)
                Stepper("Keep \(store.settings.keepLocalSnapshots) per Claude",
                        value: Binding(get: { store.settings.keepLocalSnapshots },
                                       set: { v in store.updateSettings { $0.keepLocalSnapshots = v } }), in: 1...100)
            }
            Text("Saved in ~/Library/Application Support/Seatbay/Snapshots. Safe updates also back up every Claude right before installing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func targetCard(_ target: ClaudeTarget) -> some View {
        let list = store.snapshots[target.id] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(target.name).font(.headline)
                Text("\(list.count) backup\(list.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Back Up Now") { Task { await store.backupNow(target) } }
                    .help(store.runningPID(of: target) != nil ? "Closes it for a few seconds, backs it up, and reopens it" : "Backs it up now")
                    .disabled(store.backupStatus != nil || store.updates.phase.isWorking)
            }
            ForEach(list.prefix(5)) { info in
                HStack(spacing: 8) {
                    Image(systemName: info.uploadedAt == nil ? "internaldrive" : "icloud.and.arrow.up")
                        .foregroundStyle(.secondary).help(info.uploadedAt == nil ? "On this Mac" : "On this Mac and in S3")
                    Text(info.createdAt.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                    Text(info.reason + (info.whileOpen == true ? " (while open)" : "")).foregroundStyle(.secondary)
                    Text("Claude \(info.claudeVersion) · \(ByteFormat.file(UInt64(info.bytes)))").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Restore…") { pendingRestore = (info, target) }
                        .disabled(store.backupStatus != nil || store.updates.phase.isWorking)
                    Menu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Snapshots.archiveURL(info)]) }
                        Button("Delete Backup…", role: .destructive) { pendingDeleteBackup = info }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .font(.callout)
            }
            if list.count > 5 {
                Text("+ \(list.count - 5) older").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .cardBackground()
    }
}

struct S3Card: View {
    @EnvironmentObject private var store: InstanceStore
    @Binding var remote: [S3Backup.Remote]
    @Binding var remoteError: String?
    @Binding var loading: Bool
    let onRestoreAsNew: (S3Backup.Remote) -> Void

    @State private var s3 = SettingsFile.load().s3
    @State private var secrets = SettingsFile.loadSecrets()
    /// The passphrase on disk. A new one is only saved once it has been typed twice the same way.
    @State private var savedPassphrase = SettingsFile.loadSecrets().passphrase
    @State private var confirmPassphrase = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var pendingRestore: (item: S3Backup.Remote, target: ClaudeTarget)?

    private var passphraseChanged: Bool { secrets.passphrase != savedPassphrase }
    private var passphraseConfirmed: Bool { !passphraseChanged || secrets.passphrase == confirmPassphrase }
    private var busy: Bool { store.backupStatus != nil || store.updates.phase.isWorking }

    var body: some View {
        SectionCard(title: "Copy backups to S3-compatible storage",
                    subtitle: "Works with AWS S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO and others. Each backup is encrypted on this Mac with your passphrase before upload, so the storage provider can't read it. Keep the passphrase somewhere safe: without it the backups can't be restored.") {
            Toggle("Upload each new backup", isOn: $s3.enabled)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                row("Endpoint") { TextField("https://<account id>.r2.cloudflarestorage.com or https://s3.us-east-1.amazonaws.com", text: $s3.endpoint) }
                row("Region") { TextField("us-east-1 (R2: auto)", text: $s3.region) }
                row("Bucket") { TextField("my-claude-backups", text: $s3.bucket) }
                row("Folder") { TextField("seatbay", text: $s3.prefix) }
                row("Access key") { TextField("Access key ID", text: $secrets.accessKeyID) }
                row("Secret") { SecureField("Secret access key", text: $secrets.secretAccessKey) }
                row("Passphrase") { SecureField("Encryption passphrase", text: $secrets.passphrase) }
                if passphraseChanged {
                    row("Confirm") {
                        VStack(alignment: .leading, spacing: 4) {
                            SecureField("Type the passphrase again", text: $confirmPassphrase)
                            Text(passphraseConfirmed ? "Saved." : savedPassphrase.isEmpty
                                 ? "Type it again to save it."
                                 : "Type it again to save it. Backups already in S3 stay encrypted with the old passphrase: keep it to restore them.")
                                .font(.caption).foregroundStyle(passphraseConfirmed ? Color.secondary : Color.orange)
                        }
                    }
                }
                row("") {
                    HStack(spacing: 16) {
                        Toggle("Path-style URLs", isOn: $s3.pathStyle).help("Needed by MinIO and many S3-compatible services")
                        Stepper("Keep \(s3.keepRemote) per Claude", value: $s3.keepRemote, in: 1...365)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Test Connection") { save(); test() }.disabled(testing)
                Button("Upload Backups Not Yet in S3") { save(); Task { await store.uploadPending() } }
                    .disabled(!s3.enabled || store.backupStatus != nil)
                Button("Show Backups in S3") { save(); loadRemote() }.disabled(loading)
                if testing || loading { ProgressView().controlSize(.small) }
            }
            if let testResult { Text(testResult).font(.callout).foregroundStyle(testResult.hasPrefix("✓") ? Color.green : Color.orange) }
            Text("Changes are saved as you type. The keys and passphrase are kept in secrets.json in Seatbay's folder, readable only by you (like ~/.aws/credentials).")
                .font(.caption).foregroundStyle(.secondary)
            if let remoteError { Text(remoteError).font(.callout).foregroundStyle(.orange) }
            if !remote.isEmpty { remoteList }
        }
        .onChange(of: s3) { _, _ in save() }
        .onChange(of: secrets) { _, _ in save() }
        .onChange(of: confirmPassphrase) { _, _ in save() }
        .confirmationDialog(restoreTitle, isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                if let (item, target) = pendingRestore { Task { await store.restoreRemote(item, into: target) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let (item, target) = pendingRestore {
                Text((item.machine == Snapshots.machineName ? "" : "This backup was made on another Mac (\(item.machine)); its sign-in usually doesn't carry over. ")
                     + "If \(target.name) is open, it closes first. Its current state is backed up before anything is replaced, and the replaced folder goes to the Trash.")
            }
        }
    }

    private var restoreTitle: String {
        guard let (item, target) = pendingRestore else { return "Restore?" }
        return "Replace \(target.name) with the backup \(item.snapshotID)?"
    }

    private var remoteList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            ForEach(remote.prefix(40)) { item in
                HStack(spacing: 8) {
                    Text(item.machine).font(.caption).foregroundStyle(.secondary).frame(width: 140, alignment: .leading).lineLimit(1)
                    Text(targetName(item)).lineLimit(1)
                    Text(item.snapshotID).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    Text(ByteFormat.file(UInt64(item.size))).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if let target = store.target(withID: item.targetID) {
                        Button("Restore…") { pendingRestore = (item, target) }
                            .help("Replaces \(target.name) with this backup (its current state is backed up first)")
                            .disabled(busy)
                    }
                    Button("As New Instance…") { onRestoreAsNew(item) }.disabled(busy)
                }
                .font(.callout)
            }
        }
    }

    private func targetName(_ item: S3Backup.Remote) -> String {
        if item.targetID == ClaudeTarget.mainID { return "Claude (main)" }
        return store.target(withID: item.targetID)?.name ?? "Instance \(item.targetID.prefix(8))"
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content()
        }
    }

    private func save() {
        store.updateSettings { $0.s3 = s3 }
        var toSave = secrets
        if !passphraseConfirmed { toSave.passphrase = savedPassphrase }
        guard toSave != SettingsFile.loadSecrets() else { return }
        do {
            try SettingsFile.saveSecrets(toSave)
            savedPassphrase = toSave.passphrase
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let settings = s3, keys = secrets
        Task {
            do {
                try await S3Backup.testConnection(settings: settings, secrets: keys)
                testResult = keys.passphrase.isEmpty ? "Connected, but set a passphrase before uploading." : "✓ Connected: wrote, read and deleted a test file."
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func loadRemote() {
        loading = true
        remoteError = nil
        Task {
            do { remote = try await S3Backup.listRemote() } catch { remoteError = error.localizedDescription }
            if remote.isEmpty, remoteError == nil { remoteError = "No backups in S3 yet." }
            loading = false
        }
    }
}

// MARK: Updates

struct UpdatesTab: View {
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var updates: UpdateCoordinator
    @State private var confirmUpdate = false
    @State private var confirmRollback = false


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusCard
                SectionCard(title: "Safe updates",
                            subtitle: "Your regular Claude downloads and installs its own updates. Instances don't: each one runs the installed version from the moment it opens, so after an update it keeps the earlier version until you restart it. With safe updates on, Seatbay does the whole round for you: it checks the download is signed by Anthropic, closes every Claude, backs each one up, runs Claude's installer, and reopens exactly the Claudes that were open, each with its own account.") {
                    Toggle("Let Seatbay install Claude updates", isOn: binding(\.safeUpdates))
                    Group {
                        Toggle("Install automatically when you're away (10 minutes with no input and no Claude working)", isOn: binding(\.autoInstallWhenIdle))
                        if store.settings.autoInstallPaused {
                            HStack {
                                Label("Automatic installs are paused after a rollback.", systemImage: "pause.circle").foregroundStyle(.orange)
                                Button("Resume") { store.updateSettings { $0.autoInstallPaused = false } }
                            }
                        }
                        Toggle("Keep the previous version so I can roll back", isOn: binding(\.keepPreviousVersion))
                        Text("Updates are found while your regular Claude is open. Open it now and then if you mostly work in instances.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(!store.settings.safeUpdates)
                }
                if !updates.steps.isEmpty { stepsCard }
                if !updates.history.isEmpty { historyCard }
            }
            .padding(16)
        }
        .confirmationDialog("Update every Claude to \(updates.status.stagedVersion ?? "the new version")?", isPresented: $confirmUpdate, titleVisibility: .visible) {
            Button("Update All Now") { Task { await updates.updateAll(trigger: "Update All Now") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every open Claude closes for about a minute. Running Code sessions stop and resume when they reopen.")
        }
        .confirmationDialog("Roll back to Claude \(updates.status.previousVersion ?? "")?", isPresented: $confirmRollback, titleVisibility: .visible) {
            Button("Roll Back") { Task { await updates.rollback() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every open Claude closes and reopens on the earlier version. Automatic installs pause until you resume them.")
        }
    }

    private var statusCard: some View {
        let s = updates.status
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: s.pending ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 26)).foregroundStyle(s.pending ? Color.accentColor : Color.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.pending ? "Claude \(s.stagedVersion ?? "") is downloaded and ready" : "Claude \(s.installedVersion) is installed")
                    .font(.headline)
                Text(s.pending ? "Installed: \(s.installedVersion)." : "Claude downloads updates by itself; they show up here when ready.")
                    .font(.callout).foregroundStyle(.secondary)
                if let previous = s.previousVersion { Text("Kept for rollback: Claude \(previous)").font(.caption).foregroundStyle(.secondary) }
                switch updates.phase {
                case .finished(let text): resultLine(text, ok: true)
                case .failed(let text): resultLine(text, ok: false)
                default: EmptyView()
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button("Update All Now…") { confirmUpdate = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!s.pending || updates.phase.isWorking)
                if s.previousVersion != nil {
                    Button("Roll Back…") { confirmRollback = true }.disabled(updates.phase.isWorking)
                }
            }
        }
        .padding(14)
        .cardBackground()
    }

    private func resultLine(_ text: String, ok: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(ok ? .green : .orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("OK") { updates.dismissResult() }.buttonStyle(.borderless)
        }
    }

    private var stepsCard: some View {
        SectionCard(title: "Last run") {
            ForEach(Array(updates.steps.enumerated()), id: \.offset) { _, step in
                Label(step, systemImage: "checkmark").font(.callout)
            }
        }
    }

    private var historyCard: some View {
        SectionCard(title: "History") {
            ForEach(updates.history.prefix(12), id: \.self) { entry in
                HStack(alignment: .top) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(entry.detail).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }

    private func binding(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: key] }, set: { value in store.updateSettings { $0[keyPath: key] = value } })
    }
}

// MARK: Other Mac

struct OtherMacTab: View {
    @EnvironmentObject private var store: InstanceStore
    @State private var host = ""
    @State private var status: OtherMac.Status?
    @State private var message: String?
    @State private var failed = false
    @State private var working = false
    @State private var selected: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionCard(title: "Copy instance profiles to another Mac",
                            subtitle: "Sends each instance's name, number, colour, icon style and label over SSH. The other Mac builds its own instance apps for its own Claude. Sign-ins and data are not copied (logins are encrypted per Mac): then open each instance there and use its Sign In… button.") {
                    HStack {
                        TextField("user@host (key-based SSH)", text: $host).textFieldStyle(.roundedBorder)
                            .onSubmit { check() }
                        Button("Check") { check() }.disabled(host.isEmpty || working)
                        if working { ProgressView().controlSize(.small) }
                    }
                    if let status { statusView(status) }
                    if let message {
                        Text(message).font(.callout).foregroundStyle(failed ? Color.orange : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SectionCard(title: "Instances to copy") {
                    if store.instances.isEmpty { Text("No instances yet.").foregroundStyle(.secondary) }
                    ForEach(store.instances) { instance in
                        Toggle(isOn: Binding(get: { selected.contains(instance.id) },
                                             set: { on in if on { selected.insert(instance.id) } else { selected.remove(instance.id) } })) {
                            HStack {
                                if let icon = store.icons[instance.id] { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                                Text(instance.name)
                                Text("#\(instance.number) · \(instance.colorName)").foregroundStyle(.secondary).font(.caption)
                                if status?.instanceNames.contains(instance.name) == true {
                                    Text("already there").font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    HStack {
                        Button(status?.seatbayCurrent == true ? "Copy Profiles" : "Install Seatbay There and Copy Profiles") { copy() }
                            .buttonStyle(.borderedProminent)
                            .disabled(host.isEmpty || selected.isEmpty || working)
                        Text("Existing instances with the same name get the new look; nothing on the other Mac is deleted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            if host.isEmpty { host = store.settings.otherMacHost }
            if selected.isEmpty { selected = Set(store.instances.map(\.id)) }
        }
    }

    private func statusView(_ s: OtherMac.Status) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Connected · macOS \(s.macOS)", systemImage: "checkmark.circle").foregroundStyle(.green)
            Label(s.claudeVersion.map { "Claude \($0) installed" } ?? "Claude is not installed there",
                  systemImage: s.claudeVersion == nil ? "xmark.circle" : "checkmark.circle")
                .foregroundStyle(s.claudeVersion == nil ? Color.orange : Color.primary)
            Label(s.seatbayInstalled ? (s.seatbayCurrent ? "Seatbay is up to date" : "Seatbay is an older build (will be updated)")
                  : "Seatbay is not installed (will be installed)", systemImage: "app.badge")
            if !s.instanceNames.isEmpty {
                Text("Instances there: \(s.instanceNames.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            }
            if let bypass = s.bypassDefault { Text("Default permission mode there: \(bypass)").font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout)
    }

    private func check() {
        let host = self.host.trimmingCharacters(in: .whitespaces)
        store.updateSettings { $0.otherMacHost = host }
        working = true
        message = nil
        Task {
            let result = await Task.detached { Result { try OtherMac.status(host: host) } }.value
            switch result {
            case .success(let s): status = s
            case .failure(let error): status = nil; failed = true; message = error.localizedDescription
            }
            working = false
        }
    }

    private func copy() {
        let host = self.host.trimmingCharacters(in: .whitespaces)
        let chosen = store.instances.filter { selected.contains($0.id) }
        let needsInstall = status?.seatbayCurrent != true
        working = true
        message = nil
        Task {
            let result = await Task.detached { () -> Result<String, Error> in
                do {
                    let current = try OtherMac.status(host: host)
                    guard current.claudeVersion != nil else { throw OtherMac.Failure(message: "Install Claude on \(host) first (claude.ai/download).") }
                    if needsInstall || !current.seatbayCurrent { try OtherMac.installSeatbay(host: host) }
                    return .success(try OtherMac.copyProfiles(chosen, host: host))
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let summary):
                failed = false
                message = "Done: \(summary). On the other Mac, open Seatbay and use Sign In… for each new instance."
            case .failure(let error):
                failed = true
                message = error.localizedDescription
            }
            working = false
            if let s = try? await Task.detached(operation: { try OtherMac.status(host: host) }).value { status = s }
        }
    }
}
