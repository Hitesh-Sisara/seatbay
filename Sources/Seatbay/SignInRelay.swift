import AppKit
import Foundation
import SeatbayCore

/// Routes a `claude://` sign-in link to one specific instance.
///
/// Signing in with Google (and email links) ends with the browser opening a `claude://…` link. macOS
/// sends it to "Claude", which, with several instances running, is whichever one LaunchServices
/// picks; an instance that didn't start the sign-in ignores it. That's why Parall asks you to quit
/// every other Claude first.
///
/// While a relay is active, Seatbay is the temporary handler for `claude://`. The link it
/// receives goes straight to the chosen instance's process as a standard "open URL" Apple Event,
/// and then `claude://` is handed back to Claude.
@MainActor
final class SignInRelay: ObservableObject {
    enum State: Equatable {
        case idle
        case waiting(UUID)
        case delivered(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let store: InstanceStore
    private var timer: Timer?
    private var deadline = Date.distantFuture
    private static let scheme = "claude"
    private static let timeout: TimeInterval = 10 * 60

    init(store: InstanceStore) { self.store = store }

    var waitingInstanceID: UUID? {
        if case .waiting(let id) = state { return id }
        return nil
    }

    // MARK: Relay lifecycle

    func start(for instance: Instance) {
        stopTimer()
        state = .waiting(instance.id)
        deadline = Date().addingTimeInterval(Self.timeout)
        store.open(instance)   // launches it, or brings it forward if it's already running
        claimScheme()
        // Claude may re-register itself as the claude:// handler when it starts; keep the claim while waiting.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        askForAutomationPermission()
    }

    /// Passing the link on is an Apple Event to Claude, which macOS gates behind a one-time
    /// "Seatbay wants to control Claude" prompt. Ask now, not halfway through the user's sign-in.
    private func askForAutomationPermission() {
        Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: SB.claudeBundleID)
            let status = AEDeterminePermissionToAutomateTarget(
                target.aeDesc, AEEventClass(kInternetEventClass), AEEventID(kAEGetURL), true)
            guard status == OSStatus(errAEEventNotPermitted) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.waitingInstanceID != nil else { return }
                self.cancel(keepState: true)
                self.state = .failed("Seatbay isn't allowed to pass links to Claude. Turn it on in System Settings → Privacy & Security → Automation → Seatbay → Claude, then press Sign In again.")
            }
        }
    }

    func cancel() {
        stopTimer()
        restoreScheme()
        state = .idle
    }

    func dismissResult() {
        if case .waiting = state { return }
        state = .idle
    }

    private func tick() {
        guard case .waiting(let id) = state else { stopTimer(); return }
        if Date() > deadline || store.instance(withID: id) == nil {
            cancel()
            state = .failed("Sign-in relay timed out. claude:// links go to Claude again.")
            return
        }
        if !isCurrentHandler { claimScheme() }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Incoming links

    func handle(url: URL) {
        if case .waiting(let id) = state, let instance = store.instance(withID: id) {
            store.refreshStatus()
            guard let pid = store.runningPIDs[id] else {
                state = .failed("\(instance.name) is not running. Open it and press Sign In again.")
                cancel(keepState: true)
                return
            }
            stopTimer()
            restoreScheme()
            deliver(url, to: pid) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.state = .failed("Could not pass the sign-in link to \(instance.name): \(error). Allow Seatbay to control Claude in System Settings → Privacy & Security → Automation, then try again.")
                } else {
                    self.state = .delivered(instance.name)
                    self.store.bringForward(pid: pid)
                }
            }
            return
        }
        // Not relaying (e.g. we were left as the handler after a crash): pass it on to the main Claude.
        restoreScheme()
        if let pid = store.mainClaudePID {
            deliver(url, to: pid) { _ in }
        } else if let claude = AppBuilder.claudeAppURL {
            NSWorkspace.shared.open([url], withApplicationAt: claude, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func cancel(keepState: Bool) {
        stopTimer()
        restoreScheme()
        if !keepState { state = .idle }
    }

    /// Sends a standard kAEGetURL ("open URL") Apple Event to one specific process.
    private func deliver(_ url: URL, to pid: pid_t, completion: @escaping @MainActor (String?) -> Void) {
        let link = url.absoluteString
        Task.detached {
            let event = NSAppleEventDescriptor.appleEvent(
                withEventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(string: link), forKeyword: AEKeyword(keyDirectObject))
            var failure: String?
            do {
                _ = try event.sendEvent(options: [.waitForReply], timeout: 20)
            } catch {
                switch (error as NSError).code {
                case -1743: failure = "macOS blocked it (Automation permission is off)"
                case -1712: failure = "Claude didn't answer in time"
                case let code: failure = "Apple Event error \(code)"
                }
            }
            let result = failure
            await MainActor.run { completion(result) }
        }
    }

    // MARK: claude:// ownership

    private var currentHandler: URL? {
        guard let probe = URL(string: "\(Self.scheme)://") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    private var isCurrentHandler: Bool {
        currentHandler?.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
    }

    private func claimScheme() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: Self.scheme) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.stopTimer()
                self?.state = .failed("macOS didn't let Seatbay receive the sign-in link: \(error.localizedDescription)")
            }
        }
    }

    func restoreScheme() {
        guard let claude = AppBuilder.claudeAppURL else { return }
        NSWorkspace.shared.setDefaultApplication(at: claude, toOpenURLsWithScheme: Self.scheme) { _ in }
    }

    /// At launch: if a previous run ended mid-relay, give claude:// back to Claude.
    func repairSchemeOwnership() {
        if isCurrentHandler { restoreScheme() }
    }
}
