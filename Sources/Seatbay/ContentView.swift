import SeatbayCore
import SwiftUI

enum EditorTarget: Identifiable {
    case create(Instance)
    case edit(Instance)

    var id: UUID { instance.id }
    var instance: Instance {
        switch self {
        case .create(let instance), .edit(let instance): return instance
        }
    }
    var isNew: Bool {
        if case .create = self { return true }
        return false
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var relay: SignInRelay
    @EnvironmentObject private var updates: UpdateCoordinator
    @State private var editor: EditorTarget?
    @State private var pendingDelete: Instance?
    @SceneStorage("tab") private var tab = "instances"

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.notices.isEmpty || relay.state != .idle || store.backupStatus != nil || updates.phase.isWorking {
                VStack(spacing: 8) {
                    RelayBanner()
                    ActivityBanner()
                    NoticeList()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            TabView(selection: $tab) {
                instancesTab
                    .tabItem { Label("Instances", systemImage: "square.stack.3d.up") }.tag("instances")
                HealthTab()
                    .tabItem { Label("Health", systemImage: "waveform.path.ecg") }.tag("health")
                BackupsTab()
                    .tabItem { Label("Backups", systemImage: "externaldrive.badge.timemachine") }.tag("backups")
                UpdatesTab()
                    .tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag("updates")
                OtherMacTab()
                    .tabItem { Label("Other Mac", systemImage: "laptopcomputer.and.arrow.down") }.tag("othermac")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .onAppear {
            // `-SBInitialTab health` on the command line opens a given tab (used for screenshots).
            if let initial = UserDefaults.standard.string(forKey: "SBInitialTab") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tab = initial }
            }
        }
        .sheet(item: $editor) { target in EditorView(target: target) }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "instance")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { instance in
            Button("Delete App, Keep Its Data") { Task { await store.delete(instance, deleteData: false) } }
            Button("Delete App and Data", role: .destructive) { Task { await store.delete(instance, deleteData: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The app goes to the Trash. Deleting its data also moves this instance's sign-in, chats and settings to the Trash.")
        }
        .alert("Seatbay", isPresented: Binding(get: { store.errorMessage != nil },
                                                    set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var instancesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !store.claudeInstalled { MissingClaudeBanner() }
                if !store.settings.nightlyPromptAnswered { NightlyPromptCard() }
                MainClaudeRow()
                ForEach(store.instances) { instance in
                    InstanceRow(instance: instance,
                                onEdit: { editor = .edit(instance) },
                                onDelete: { pendingDelete = instance })
                }
                if store.instances.isEmpty { emptyState }
                Text("Options").font(.headline).padding(.top, 10)
                SleepCard()
                PermissionDefaultCard()
                TipsSection().padding(.top, 6)
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Seatbay").font(.title2.weight(.bold))
                Text("Every Claude account in its own seat: side by side, each with its own colour and number.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editor = .create(store.makeDraft())
            } label: {
                Label("New Instance", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!store.claudeInstalled)
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("No extra Claudes yet").font(.headline)
            Text("Create one for work, a client or a second account. It gets its own app in ~/Applications, its own coloured, numbered Dock icon and its own sign-in.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: Rows

struct MainClaudeRow: View {
    @EnvironmentObject private var store: InstanceStore

    var body: some View {
        let running = store.mainClaudePID != nil
        HStack(spacing: 14) {
            Image(nsImage: store.mainClaudeIcon).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Claude").font(.headline)
                    StatusPill(running: running, working: store.health[ClaudeTarget.mainID]?.working ?? false)
                }
                Text("Main app · #1 · your usual data folder").font(.callout).foregroundStyle(.secondary)
                Text("Each instance starts from its own private copy of /Applications/Claude.app; Claude.app itself isn't changed.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Button(running ? "Show" : "Open") { store.openMainClaude() }
                .help(running ? "Bring the main Claude to the front" : "Start the main Claude, even if instances are already running")
        }
        .padding(14)
        .cardBackground()
    }
}

struct InstanceRow: View {
    let instance: Instance
    let onEdit: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var relay: SignInRelay

    var body: some View {
        let running = store.isRunning(instance)
        HStack(spacing: 14) {
            Group {
                if let icon = store.icons[instance.id] {
                    Image(nsImage: icon).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Palette.swiftUIColor(named: instance.colorName))
                }
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(instance.name).font(.headline)
                    StatusPill(running: running, sleeping: store.sleeping.contains(instance.id),
                               working: store.health[instance.id.uuidString]?.working ?? false)
                }
                Text(detailLine).font(.callout).foregroundStyle(.secondary)
                Text((instance.dataDir as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)

            if store.busy.contains(instance.id) { ProgressView().controlSize(.small) }
            if !instance.usesAPI {
                Button("Sign In…") { relay.start(for: instance) }
                    .help("Send the next Claude sign-in link to \(instance.name) only")
                    .disabled(relay.waitingInstanceID != nil)
            }
            if running {
                Button("Quit") { store.quit(instance) }
            }
            Button(running ? "Show" : "Open") { store.open(instance) }
                .buttonStyle(.borderedProminent)
                .tint(Palette.swiftUIColor(named: instance.colorName))
            Menu {
                Button("Edit…", action: onEdit)
                Button("Show App in Finder") { store.revealApp(instance) }
                Button("Show Data Folder") { store.revealData(instance) }
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(14)
        .cardBackground()
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Show App in Finder") { store.revealApp(instance) }
            Button("Show Data Folder") { store.revealData(instance) }
        }
    }

    private var detailLine: String {
        var parts = ["#\(instance.number)", instance.colorName, instance.style.title]
        if !instance.label.isEmpty { parts.append("“\(instance.label.uppercased())”") }
        if instance.usesAPI {
            let api = APIConfigFile.load(dataDir: URL(fileURLWithPath: instance.dataDir, isDirectory: true))
            parts.append(api.map { "API: \($0.endpointDescription)" } ?? "API: not set up")
        }
        return parts.joined(separator: " · ")
    }
}

struct StatusPill: View {
    let running: Bool
    var sleeping = false
    var working = false

    var body: some View {
        HStack(spacing: 4) {
            if sleeping && !running {
                Image(systemName: "moon.zzz.fill").font(.system(size: 9)).foregroundStyle(.indigo)
            } else {
                Circle().fill(running ? (working ? Color.orange : Color.green) : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            }
            Text(running ? (working ? "Working" : "Running") : (sleeping ? "Sleeping" : "Not running")).font(.caption.weight(.medium))
                .foregroundStyle(running ? .primary : .secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }
}

/// Switch for `permissions.defaultMode = bypassPermissions` in ~/.claude/settings.json.
struct PermissionDefaultCard: View {
    @EnvironmentObject private var store: InstanceStore
    @State private var confirmOn = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: store.bypassByDefault ? "bolt.shield.fill" : "shield.lefthalf.filled")
                .font(.system(size: 24))
                .foregroundStyle(store.bypassByDefault ? Color.orange : Color.secondary)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Start new Code sessions in Bypass permissions").font(.headline)
                Text("Applies to the main Claude, every instance and the terminal `claude` CLI. It's saved as permissions.defaultMode in ~/.claude/settings.json; there is no launch variable for it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.bypassByDefault {
                    Text("For each Claude app and account, also turn on Settings → Claude Code → Allow bypass permissions mode once, in that app.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("Bypass by default", isOn: Binding(get: { store.bypassByDefault },
                                                      set: { on in if on { confirmOn = true } else { store.setBypassByDefault(false) } }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
        .cardBackground()
        .confirmationDialog("Start new Code sessions in Bypass permissions?", isPresented: $confirmOn, titleVisibility: .visible) {
            Button("Turn On", role: .destructive) { store.setBypassByDefault(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claude Code will then run commands and edit files without asking first, in every Claude on this Mac and in the terminal `claude` command. Only use it for folders and machines where that is safe. You can turn it off here at any time.")
        }
    }
}

// MARK: Banners

struct RelayBanner: View {
    @EnvironmentObject private var store: InstanceStore
    @EnvironmentObject private var relay: SignInRelay

    var body: some View {
        switch relay.state {
        case .idle:
            EmptyView()
        case .waiting(let id):
            let name = store.instance(withID: id)?.name ?? "this instance"
            banner(tint: .accentColor) {
                ProgressView().controlSize(.small)
            } text: {
                Text("Waiting for the sign-in link for \(name)…").font(.headline)
                Text("In \(name), choose how to sign in (for example Continue with Google) and finish in your browser. When the browser opens the Claude link, Seatbay passes it to \(name) only. Your other Claudes stay as they are.")
                    .foregroundStyle(.secondary)
            } action: {
                Button("Cancel") { relay.cancel() }
            }
        case .delivered(let name):
            banner(tint: .green) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            } text: {
                Text("Sign-in link delivered to \(name).").font(.headline)
                Text(store.bypassByDefault
                     ? "claude:// links go to your main Claude again. For sessions in \(name) to start in bypass, turn on Settings → Claude Code → Allow bypass permissions mode in \(name)."
                     : "claude:// links go to your main Claude again.")
                    .foregroundStyle(.secondary)
            } action: {
                Button("Done") { relay.dismissResult() }
            }
        case .failed(let message):
            banner(tint: .orange) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            } text: {
                Text(message)
            } action: {
                Button("Dismiss") { relay.dismissResult() }
            }
        }
    }

    private func banner<Icon: View, Body: View, Action: View>(
        tint: Color, @ViewBuilder icon: () -> Icon, @ViewBuilder text: () -> Body, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon().frame(width: 22)
            VStack(alignment: .leading, spacing: 4) { text() }
                .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35)))
    }
}

struct MissingClaudeBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Claude Desktop isn't installed in /Applications. Install it from claude.ai/download, then reopen Seatbay.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }
}

struct TipsSection: View {
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                tip("person.2", "Each instance keeps its own sign-in, chats, projects and settings in its own data folder. Your main Claude and its data are not touched.")
                tip("key", "To sign an instance in to a different account, press Sign In… next to it first. Then sign in as usual, and the browser's Claude link goes to that instance. You don't need to quit your other Claudes.")
                tip("arrow.up.arrow.down", "Each instance runs from its own copy of Claude, made when it opens (it takes no extra disk space), so macOS treats it as a separate app. Clicking the regular Claude icon always opens your main Claude. macOS still calls every instance “Claude” in the menu bar; the icon tells them apart.")
                tip("arrow.triangle.2.circlepath", "Only your regular Claude updates itself. An instance picks up the new version the next time it opens; Health shows “Restart to update” until then. Safe updates (Updates tab) can install a downloaded update and restart every Claude for you, with a backup first.")
                tip("hand.raised", "For privacy permissions (microphone, folders, Automation), macOS treats each instance as its own app. You may see a one-time prompt or a “Data Access Blocked” notice that names the instance. Allow what you need in System Settings → Privacy & Security.")
                tip("pin", "Instances live in ~/Applications, so Spotlight, Raycast and Alfred find them. To pin one, drag it from ~/Applications to the Dock (Show App in Finder in the instance's menu shows it).")
            }
            .padding(.top, 6)
        } label: {
            Text("How it works").font(.headline)
        }
        .padding(14)
        .cardBackground()
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    func cardBackground() -> some View {
        background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Asked once: nightly backups copy sign-in data, so they start only when you say so.
struct NightlyPromptCard: View {
    @EnvironmentObject private var store: InstanceStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "moon.stars.fill").font(.system(size: 26)).foregroundStyle(.indigo).frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text("Back up every Claude each night?").font(.headline)
                Text("Between 2 and 3 AM, Seatbay backs up each Claude that changed (sign-in, settings, chats and Code sessions, without caches), even the ones that are open, without closing anything. If the Mac is asleep it catches up later. Add S3-compatible storage in Backups to keep an encrypted copy off this Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Turn On Nightly Backups") {
                        store.updateSettings { $0.nightlyBackup = true; $0.nightlyPromptAnswered = true }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Not Now") { store.updateSettings { $0.nightlyPromptAnswered = true } }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardBackground()
    }
}
