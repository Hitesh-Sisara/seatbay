import AppKit
import Foundation
import SeatbayCore

/// Command-line access to backups, health and updates (for scripts, SSH and tests):
///
///     --import-profiles <file|->              create/update instances from InstanceProfile JSON
///     --backup <main|name|id|all> [--force]   back up closed Claudes
///     --list-backups
///     --restore-snapshot <snapshot id> <main|name|id>
///     --configure-s3 < settings.json          {"endpoint","region","bucket","prefix","pathStyle","enabled",
///                                              "keepRemote","accessKeyID","secretAccessKey","passphrase"}
///     --s3-test | --s3-list | --s3-upload <snapshot id> | --s3-download <machine/target/snapshot> <out.tar.gz>
///     --health                                one sample of memory, CPU, sign-in and idle state
///     --update-status
///     --update-all | --restart-all            the same flow as the Updates tab
///     --scheduled-backup                      run by the launchd agent: a backup round, only when one is due
///     --backup-round                          a backup round now (every Claude, open ones from a clone, then upload)
///     --backup-schedule [status|on|off|hour <0-23>|install]
///     --configure-api <name|id> < api.json    {"baseURL","apiKey","authScheme":"x-api-key|bearer","models":[],"headers":{}}
///                                             (or "account" instead of the JSON file: back to a Claude account)
///     --api-status <name|id> | --api-test <name|id>
enum AutomationCLI {
    static func run(_ args: [String]) -> Never {
        let rest = Array(args.dropFirst(2))
        switch args[1] {
        case "--import-profiles":
            let data = rest.first.map { $0 == "-" ? FileHandle.standardInput.readDataToEndOfFile() : (try? Data(contentsOf: URL(fileURLWithPath: $0))) ?? Data() }
                ?? FileHandle.standardInput.readDataToEndOfFile()
            guard let profiles = try? JSONDecoder().decode([InstanceProfile].self, from: data) else { fail("expected a JSON array of profiles") }
            let result = Profiles.importProfiles(profiles)
            print(result.summary)
            exit(result.failed.isEmpty ? 0 : 1)

        case "--list-backups":
            for info in Snapshots.listAll() {
                print("\(info.id)\t\(info.targetName)\t\(ByteFormat.file(UInt64(info.bytes)))\t\(info.claudeVersion)\t\(info.uploadedAt == nil ? "local" : "local+S3")")
            }
            exit(0)

        case "--backup":
            guard let which = rest.first else { fail("usage: --backup <main|name|id|all> [--force]") }
            let force = rest.contains("--force")
            let targets = which == "all" ? allTargets() : [target(which)]
            var failures = 0
            for target in targets {
                do {
                    if !force, let last = Snapshots.latest(targetID: target.id),
                       Date().timeIntervalSince(last.createdAt) < TimeInterval(SettingsFile.load().backupMinIntervalHours * 3600) {
                        print("\(target.name): skipped (backed up \(last.id))")
                        continue
                    }
                    let info = try Snapshots.create(target, reason: "command line")
                    Snapshots.prune(targetID: target.id, keep: SettingsFile.load().keepLocalSnapshots)
                    print("\(target.name): \(info.id) (\(ByteFormat.file(UInt64(info.bytes))))")
                } catch {
                    print("\(target.name): \(error.localizedDescription)")
                    failures += 1
                }
            }
            exit(failures == 0 ? 0 : 1)

        case "--restore-snapshot":
            guard rest.count >= 2 else { fail("usage: --restore-snapshot <snapshot id> <main|name|id>") }
            let chosen = target(rest[1])
            // Ids are timestamps, so two Claudes backed up in the same second share one: prefer the
            // destination's own backup, and only take another Claude's when the id is unambiguous.
            let matches = Snapshots.listAll().filter { $0.id == rest[0] }
            guard let info = matches.first(where: { $0.targetID == chosen.id }) ?? (matches.count == 1 ? matches.first : nil) else {
                fail(matches.isEmpty ? "no snapshot \(rest[0])"
                     : "\(rest[0]) exists for \(matches.map(\.targetName).joined(separator: ", ")); name one of those as the destination")
            }
            let destination = chosen.forRestore(of: info)
            do {
                let safety = try Snapshots.restore(archive: Snapshots.archiveURL(info), into: destination)
                print("restored \(destination.name) from \(info.id)\(safety.map { "; previous state saved as \($0.id)" } ?? "")")
                exit(0)
            } catch { fail(error.localizedDescription) }

        case "--configure-s3":
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail("expected JSON on stdin") }
            var settings = SettingsFile.load()
            var secrets = SettingsFile.loadSecrets()
            if let v = json["endpoint"] as? String { settings.s3.endpoint = v }
            if let v = json["region"] as? String { settings.s3.region = v }
            if let v = json["bucket"] as? String { settings.s3.bucket = v }
            if let v = json["prefix"] as? String { settings.s3.prefix = v }
            if let v = json["pathStyle"] as? Bool { settings.s3.pathStyle = v }
            if let v = json["enabled"] as? Bool { settings.s3.enabled = v }
            if let v = json["keepRemote"] as? Int { settings.s3.keepRemote = v }
            if let v = json["accessKeyID"] as? String { secrets.accessKeyID = v }
            if let v = json["secretAccessKey"] as? String { secrets.secretAccessKey = v }
            if let v = json["passphrase"] as? String { secrets.passphrase = v }
            do {
                try SettingsFile.save(settings)
                try SettingsFile.saveSecrets(secrets)
                print("S3: \(settings.s3.enabled ? "on" : "off"), \(settings.s3.endpoint) bucket \(settings.s3.bucket), prefix \(settings.s3.prefix)")
                exit(0)
            } catch { fail(error.localizedDescription) }

        case "--s3-test":
            async {
                try await S3Backup.testConnection(settings: SettingsFile.load().s3, secrets: SettingsFile.loadSecrets())
                print("S3 connection OK (write, read, delete, list)")
            }

        case "--s3-list":
            async {
                for remote in try await S3Backup.listRemote() {
                    print("\(remote.id)\t\(ByteFormat.file(UInt64(remote.size)))")
                }
            }

        case "--s3-upload":
            guard let id = rest.first else { fail("usage: --s3-upload <snapshot id> [main|name|id]") }
            var matches = Snapshots.listAll().filter { $0.id == id }
            if rest.count > 1 { let only = target(rest[1]).id; matches = matches.filter { $0.targetID == only } }
            guard matches.count == 1, let info = matches.first else {
                fail(matches.isEmpty ? "no snapshot \(id)" : "\(id) exists for \(matches.map(\.targetName).joined(separator: ", ")); add which one")
            }
            async {
                try await S3Backup.upload(info)
                print("uploaded \(info.id)")
            }

        case "--s3-download":
            guard rest.count >= 2 else { fail("usage: --s3-download <machine/target/snapshot> <out.tar.gz>") }
            async {
                guard let remote = try await S3Backup.listRemote().first(where: { $0.id == rest[0] }) else { fail("not in S3: \(rest[0])") }
                let meta = try await S3Backup.metadata(remote)
                let file = try await S3Backup.download(remote)
                let out = URL(fileURLWithPath: rest[1])
                guard !FileManager.default.fileExists(atPath: out.path) else {
                    try? FileManager.default.removeItem(at: file)
                    fail("\(out.path) already exists; choose a new file name")
                }
                try FileManager.default.moveItem(at: file, to: out)
                print("downloaded \(meta.targetName) \(meta.id) → \(out.path) (sha256 \(meta.sha256.prefix(12))…)")
            }

        case "--health":
            onMain { store in
                store.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                store.tick()   // second sample gives CPU %
                let awakeIdle = Int(SystemState.userIdleSeconds)
                print("user idle: \(awakeIdle)s")
                for target in store.allTargets {
                    let h = store.health[target.id] ?? TargetHealth()
                    let state = h.pid == nil ? "closed" : (h.working ? "working" : "idle \(h.idleMinutes ?? 0)m")
                    print("\(target.name)\t\(state)\tsigned in: \(h.signedIn.map { $0 ? "yes" : "no" } ?? "?")\tmemory \(ByteFormat.string(h.memory))\tcpu \(String(format: "%.1f", h.cpuPercent))%\tprocesses \(h.processCount)\(h.outdated ? "\tneeds restart" : "")\(h.sharesClaudeApp ? "\tshares Claude.app (restart once)" : "")")
                }
                return 0
            }

        case "--other-mac-status":
            guard let host = rest.first else { fail("usage: --other-mac-status <user@host>") }
            do {
                let s = try OtherMac.status(host: host)
                print("macOS \(s.macOS); Claude \(s.claudeVersion ?? "not installed"); Seatbay \(s.seatbayInstalled ? (s.seatbayCurrent ? "up to date" : "older build") : "not installed")\(s.seatbayRunning ? " (running)" : ""); instances: \(s.instanceNames.isEmpty ? "none" : s.instanceNames.joined(separator: ", "))")
                exit(0)
            } catch { fail(error.localizedDescription) }

        case "--copy-profiles":
            // --copy-profiles <user@host> [all | name,name,…]
            guard let host = rest.first else { fail("usage: --copy-profiles <user@host> [all|name,name]") }
            let all = InstanceFile.load()
            let names = rest.count > 1 && rest[1] != "all" ? Set(rest[1].split(separator: ",").map { $0.lowercased() }) : nil
            let chosen = names.map { set in all.filter { set.contains($0.name.lowercased()) } } ?? all
            guard !chosen.isEmpty else { fail("no matching instances") }
            do {
                let s = try OtherMac.status(host: host)
                guard s.claudeVersion != nil else { fail("Claude is not installed on \(host)") }
                if !s.seatbayCurrent {
                    try OtherMac.installSeatbay(host: host)
                    print("installed this build of Seatbay on \(host)")
                }
                print(try OtherMac.copyProfiles(chosen, host: host))
                exit(0)
            } catch { fail(error.localizedDescription) }

        case "--update-status":
            let status = ClaudeUpdateStatus.probe()
            print("installed: \(status.installedVersion)")
            print("downloaded: \(status.stagedVersion ?? "none")\(status.pending ? " (ready to install)" : "")")
            print("kept for rollback: \(status.previousVersion ?? "none")")
            exit(0)

        case "--update-all", "--restart-all":
            // --restart-all --only "Name,Name" restarts just those (handy for testing without closing everything).
            let requireUpdate = args[1] == "--update-all"
            let onlyNames = rest.firstIndex(of: "--only").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil }
                .map { Set($0.split(separator: ",").map { $0.lowercased() }) }
            onMain { store in
                let only = onlyNames.map { names in store.allTargets.filter { names.contains($0.name.lowercased()) || names.contains($0.id.lowercased()) } }
                await store.updates.updateAll(trigger: "command line", requireUpdate: requireUpdate, only: only)
                for step in store.updates.steps { print("• \(step)") }
                switch store.updates.phase {
                case .finished(let text): print(text); return 0
                case .failed(let text): print("FAILED: \(text)"); return 1
                default: return 0
                }
            }

        case "--scheduled-backup":
            let due = NightlyBackup.due(settings: SettingsFile.load(), state: NightlyBackup.loadState())
            if case .no = due { exit(0) }
            async {
                guard let outcome = await NightlyBackup.runRound(trigger: due == .tonight ? "nightly" : "catch-up") else { exit(0) }
                print(outcome.summary)
                exit(outcome.ok ? 0 : 1)
            }

        case "--backup-round":
            async {
                guard let outcome = await NightlyBackup.runRound(trigger: "command line") else {
                    fail("another backup round is running")
                }
                print(outcome.summary)
                for problem in outcome.problems { print("problem: \(problem)") }
                exit(outcome.ok ? 0 : 1)
            }

        case "--backup-schedule":
            var settings = SettingsFile.load()
            switch rest.first ?? "status" {
            case "on", "off":
                settings.nightlyBackup = rest.first == "on"
                do { try SettingsFile.save(settings) } catch { fail(error.localizedDescription) }
                print("nightly backup \(settings.nightlyBackup ? "on" : "off"): agent \(NightlyBackup.syncAgent(settings: settings))")
            case "hour":
                guard rest.count > 1, let hour = Int(rest[1]), (0...23).contains(hour) else { fail("usage: --backup-schedule hour <0-23>") }
                settings.nightlyHour = hour
                do { try SettingsFile.save(settings) } catch { fail(error.localizedDescription) }
                print("window \(hour):00–\((hour + 1) % 24):00: agent \(NightlyBackup.syncAgent(settings: settings))")
            case "install":
                print("agent \(NightlyBackup.syncAgent(settings: settings))")
            default:
                let state = NightlyBackup.loadState()
                let fmt: (Date?) -> String = { $0.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never" }
                print("nightly backup: \(settings.nightlyBackup ? "on" : "off"), window \(settings.nightlyHour):00–\((settings.nightlyHour + 1) % 24):00")
                print("agent: \(NightlyBackup.agentLoaded() ? "loaded" : "not loaded")")
                print("S3: \(settings.s3.enabled && settings.s3.isConfigured ? "\(settings.s3.bucket)" : "off")")
                print("last complete round: \(fmt(state.lastSuccess))")
                print("last attempt: \(fmt(state.lastAttempt))\(state.lastSummary.map { " (\($0))" } ?? "")")
                if let error = state.lastError { print("last problem: \(error)") }
                switch NightlyBackup.due(settings: settings, state: state) {
                case .no(let why): print("due now: no (\(why))")
                case .tonight: print("due now: yes (tonight's round)")
                case .catchUp: print("due now: yes (catch-up)")
                }
            }
            exit(0)

        case "--configure-api":
            guard let key = rest.first else { fail("usage: --configure-api <name|id> < api.json   (or: --configure-api <name|id> account)") }
            let instance = instance(key)
            var connection: APIConnection?
            if rest.count > 1, rest[1] == "account" {
                connection = nil
            } else {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail("expected JSON on stdin") }
                // Start from its saved settings (also the ones put aside when it went back to an account).
                let apiDir = URL(fileURLWithPath: instance.apiDataDir, isDirectory: true)
                var api = APIConfigFile.load(dataDir: apiDir) ?? APIConfigFile.loadDisabled(dataDir: apiDir) ?? APIConnection()
                if let v = json["baseURL"] as? String { api.baseURL = v }
                if let v = json["apiKey"] as? String { api.apiKey = v }
                if let v = json["authScheme"] as? String {
                    guard let scheme = APIConnection.AuthScheme(rawValue: v) else { fail("authScheme must be x-api-key or bearer") }
                    api.authScheme = scheme
                }
                if let v = json["models"] as? [String] { api.models = v }
                if let v = json["headers"] as? [String: String] { api.headers = v }
                if let problem = api.problem { fail(problem) }
                connection = api
            }
            let chosen = connection
            onMain { store in
                guard let current = store.instance(withID: instance.id) else { print("no such instance"); return 1 }
                store.errorMessage = nil
                store.update(current, api: chosen)
                let after = store.instance(withID: instance.id) ?? current
                if let message = store.errorMessage, !message.hasPrefix("Saved.") { print(message); return 1 }
                print("\(after.name): \(chosen.map { "API (\($0.endpointDescription))" } ?? "Claude account"), data folder \(after.dataDir)")
                if let message = store.errorMessage { print(message) }
                return 0
            }

        case "--api-status":
            guard let key = rest.first else { fail("usage: --api-status <name|id>") }
            let instance = instance(key)
            guard instance.usesAPI else { print("\(instance.name): Claude account"); exit(0) }
            guard let api = APIConfigFile.load(dataDir: URL(fileURLWithPath: instance.dataDir)) else {
                print("\(instance.name): API, but no settings in \(instance.dataDir)/configLibrary"); exit(1)
            }
            print("\(instance.name): API via \(api.isGateway ? api.trimmedBaseURL : APIConnection.anthropicAPI)")
            let keyState = api.trimmedKey.isEmpty ? "missing" : api.isSealed ? "set, sealed in the keychain by Claude" : "set (\(api.trimmedKey.count) characters), not yet sealed (Claude seals it when it starts)"
            print("key: \(keyState)\(api.isGateway ? ", sent as \(api.authScheme.title)" : "")")
            print("models: \(api.models.isEmpty ? "Claude's default list" : api.models.joined(separator: ", "))")
            if !api.headers.isEmpty { print("extra headers: \(api.headers.keys.sorted().joined(separator: ", "))") }
            exit(0)

        case "--api-test":
            guard let key = rest.first else { fail("usage: --api-test <name|id>") }
            let instance = instance(key)
            guard instance.usesAPI, let api = APIConfigFile.load(dataDir: URL(fileURLWithPath: instance.dataDir)) else {
                fail("\(instance.name) doesn't use an API key")
            }
            async {
                let result = await api.test()
                print(result.message)
                exit(result.ok ? 0 : 1)
            }

        default:
            fail("unknown option \(args[1])")
        }
    }

    private static func instance(_ key: String) -> Instance {
        if let match = InstanceFile.load().first(where: {
            $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame
        }) { return match }
        fail("no instance called \(key)")
    }

    // MARK: Helpers

    private static func fail(_ message: String) -> Never {
        fputs("\(message)\n", stderr)
        exit(1)
    }

    private static func allTargets() -> [ClaudeTarget] {
        [ClaudeTarget.main] + InstanceFile.load().map(ClaudeTarget.init)
    }

    private static func target(_ key: String) -> ClaudeTarget {
        if key == "main" { return .main }
        if let match = InstanceFile.load().first(where: {
            $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame
        }) { return ClaudeTarget(match) }
        fail("no Claude called \(key) (use main, an instance name or its id)")
    }

    /// Runs async work on a background task and keeps the process alive until it finishes.
    private static func async(_ body: @escaping () async throws -> Void) -> Never {
        Task.detached {
            do { try await body(); exit(0) } catch { fail(error.localizedDescription) }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Runs work that needs the (main-actor) store.
    private static func onMain(_ body: @escaping @MainActor (InstanceStore) async -> Int32) -> Never {
        Task { @MainActor in
            let store = InstanceStore(monitoring: false)
            exit(await body(store))
        }
        RunLoop.main.run()
        exit(0)
    }
}
