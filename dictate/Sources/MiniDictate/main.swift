import AppKit
import ServiceManagement
@preconcurrency import AVFoundation
import DictateCore

// Mini Dictate — two ways to dictate with the Fn/🌐 key:
//  • Hold Fn, speak, release            → push-to-talk
//  • Tap Fn 3 times, speak hands-free   → tap Fn once to stop (stops by itself after 1 minute)
// The text is pasted where your cursor is; if no text box is selected it waits in a small card with Copy.
// Fn + any other key (arrows, F-keys…) keeps working normally. Mini Dictate only listens; it never blocks keys.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = DictateController()
app.delegate = controller
app.run()

/// Setup diagnostics: permission status and dictation outcomes (counts only — never your words or keys typed).
func diag(_ line: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MiniDictate")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("diagnostics.log")
    let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(entry.data(using: .utf8)!); try? h.close() }
    else { try? entry.write(to: url, atomically: true, encoding: .utf8) }
}

struct HistoryItem { let text: String; let path: String; let app: String; let date: Date }

final class DictateController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let fnKeys: Set<Int64> = [63, 179]     // Fn (63) / Globe 🌐 (179)
    static let escapeKey: Int64 = 53
    static let holdDelay = 0.35                   // hold this long → push-to-talk
    static let tapMax = 0.30                      // shorter than this = a tap
    static let tripleWindow = 1.2                 // 3 taps within this many seconds → hands-free
    static let handsFreeLimit = 60                // seconds

    var statusItem: NSStatusItem!
    let hud = DictateHUD()
    let recognizer = LiveRecognizer()
    let fnWatcher = FnKeyWatcher()
    var tap: CFMachPort?
    var vocab: [String] = []
    var useAI = UserDefaults.standard.object(forKey: "useAI") as? Bool ?? true
    var sounds = UserDefaults.standard.bool(forKey: "sounds")
    var history: [HistoryItem] = []
    var status = "Ready"

    // key + recording state
    var keyIsDown = false
    var otherKeyPressed = false
    var fnDownAt = Date.distantPast
    var taps: [Date] = []
    var pending: DispatchWorkItem?
    var recording = false { didSet { DispatchQueue.main.async { self.refreshIcon() } } }
    var handsFree = false
    var ignoreNextFnUp = false
    var countdown: Timer?
    var secondsLeft = 0
    var targetApp: NSRunningApplication?
    var startedAt = Date()

    // MARK: launch

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        refreshIcon()
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        Vocabulary.ensureUserFile()
        vocab = Vocabulary.load()
        AIFormatter.shared.prewarm()
        recognizer.onPartial = { [weak self] t in DispatchQueue.main.async { self?.hud.updatePartial(t) } }
        recognizer.onLevel = { [weak self] l in DispatchQueue.main.async { self?.hud.updateLevel(l) } }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        installTap()
        fnWatcher.onChange = { [weak self] down in self?.fnChanged(down: down) }
        let hidOK = fnWatcher.start()
        diag("start accessibility=\(AXIsProcessTrusted()) inputMonitoring=\(CGPreflightListenEventAccess()) fnWatcher=\(hidOK) fnSetting=\(FocusProbe.fnKeySystemAction)")
        if !permissionsOK { startSetupGuide(); return }
        if UserDefaults.standard.bool(forKey: "justGranted") {
            UserDefaults.standard.set(false, forKey: "justGranted")
            hud.showNote("Ready — hold Fn to talk", seconds: 3)
        }
        if FocusProbe.fnKeySystemAction != 0 { showFnSettingCard() }
        enableOpenAtLoginOnce()
    }

    /// Opened again while already running (Spotlight, Finder, Launchpad): say so, since the menu-bar icon
    /// can be hidden behind the notch on a full menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if permissionsOK { hud.showNote("Mini Dictate is running — hold Fn to talk", seconds: 3) }
        else { startSetupGuide() }
        return false
    }

    // MARK: open at login (on by default after setup; switch off in the menu or System Settings → Login Items)

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func enableOpenAtLoginOnce() {
        guard !UserDefaults.standard.bool(forKey: "loginItemSet") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemSet")
        do { try SMAppService.mainApp.register() } catch { diag("open at login failed: \(error)") }
    }

    @objc func toggleOpenAtLogin() {
        do {
            if opensAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            diag("open at login toggle failed: \(error)")
            open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        }
    }

    /// macOS also reacts to 🌐 (dictation / emoji / input source). Only you can change that setting; we explain once.
    func showFnSettingCard() {
        let what = ["", "switches input source", "opens Emoji & Symbols", "starts Apple Dictation"][min(FocusProbe.fnKeySystemAction, 3)]
        hud.showSetup("macOS also uses the 🌐 key",
                      body: "Right now pressing 🌐 \(what), so a system pop-up appears alongside Mini Dictate.\n"
                          + "Fix: Keyboard → “Press 🌐 key to” → Do Nothing.",
                      button: "Open Keyboard Settings", action: { [weak self] in
                          self?.openKeyboardSettings(); self?.hud.hide()
                      }, second: ("Not now", { [weak self] in self?.hud.hide() }))
    }

    // MARK: permissions (only you can grant these; Mini Dictate guides and restarts itself when they change)

    var permissionsOK: Bool { AXIsProcessTrusted() && CGPreflightListenEventAccess() }
    var setupTimer: Timer?

    func startSetupGuide() {
        var missing: [String] = []
        if !CGPreflightListenEventAccess() { missing.append("Input Monitoring") }
        if !AXIsProcessTrusted() { missing.append("Accessibility") }
        status = "Needs \(missing.joined(separator: " and "))"
        hud.showSetup("Mini Dictate needs permission",
                      body: "Switch on “Mini Dictate” in Privacy & Security → \(missing.joined(separator: " and ")). "
                          + "Mini Dictate restarts by itself when it's done.",
                      button: "Open Settings", action: { [weak self] in self?.openMissingPane() },
                      second: ("Restart", { [weak self] in self?.relaunch() }))
        openMissingPane()
        let axAtStart = AXIsProcessTrusted()
        setupTimer?.invalidate()
        setupTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Input Monitoring is only re-read when an app starts, so restart as soon as anything changes.
            guard AXIsProcessTrusted() != axAtStart || CGPreflightListenEventAccess() else { return }
            self.setupTimer?.invalidate()
            diag("permission change detected — restarting")
            self.relaunch()
        }
    }

    func openMissingPane() {
        let pane = !CGPreflightListenEventAccess() ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        open("x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        UserDefaults.standard.set(true, forKey: "justGranted")
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: menu bar

    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "Mini Dictate")
        button.contentTintColor = recording ? .systemRed : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Mini Dictate", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: "Mini Dictate", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(header)
        menu.addItem(withTitle: "Hold Fn to talk · tap Fn ×3 for hands-free", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        if FocusProbe.fnKeySystemAction != 0 {
            add(menu, "Turn off macOS's own 🌐 action…", #selector(openKeyboardSettings))
        }
        menu.addItem(.separator())
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if history.isEmpty { sub.addItem(withTitle: "Nothing yet", action: nil, keyEquivalent: "") }
        for (i, h) in history.prefix(10).enumerated() {
            let t = h.text.replacingOccurrences(of: "\n", with: " ")
            let item = NSMenuItem(title: String(t.prefix(50)) + (t.count > 50 ? "…" : ""), action: #selector(copyHistory(_:)), keyEquivalent: "")
            item.target = self; item.tag = i; item.toolTip = "Click to copy · \(h.app)"
            sub.addItem(item)
        }
        recent.submenu = sub; menu.addItem(recent)
        menu.addItem(.separator())
        toggle(menu, "Smart formatting", useAI && AIFormatter.shared.isAvailable, #selector(toggleAI))
        toggle(menu, "Sounds", sounds, #selector(toggleSounds))
        toggle(menu, "Open at login", opensAtLogin, #selector(toggleOpenAtLogin))
        add(menu, "Names & words…", #selector(editVocab))
        add(menu, "Permissions…", #selector(openPermissions))
        menu.addItem(.separator())
        add(menu, "Quit Mini Dictate", #selector(quit), "q")
    }

    func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    func toggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.state = on ? .on : .off
        menu.addItem(item)
    }
    func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    @objc func copyHistory(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(history[sender.tag].text, forType: .string)
    }
    @objc func toggleAI() { useAI.toggle(); UserDefaults.standard.set(useAI, forKey: "useAI") }
    @objc func toggleSounds() { sounds.toggle(); UserDefaults.standard.set(sounds, forKey: "sounds") }
    @objc func editVocab() { NSWorkspace.shared.open(Vocabulary.userFile) }
    @objc func openKeyboardSettings() { open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }
    @objc func openPermissions() {
        for p in ["Privacy_Accessibility", "Privacy_ListenEvent", "Privacy_Microphone"] { open("x-apple.systempreferences:com.apple.preference.security?\(p)") }
    }
    @objc func quit() { NSApp.terminate(nil) }

    func play(_ name: String) { if sounds { NSSound(named: name)?.play() } }

    // MARK: keys (listen-only event tap: other keys + Esc; the Fn key itself comes from the hardware watcher)

    func installTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<DictateController>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else {
                me.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(mask), callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in if self?.tap == nil { self?.installTap() } }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handle(type: CGEventType, event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown {
            if Self.fnKeys.contains(code) || event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            // macOS sends an Escape by itself the instant 🌐 goes down — ignore that one.
            if code == Self.escapeKey && Date().timeIntervalSince(fnDownAt) < 0.25 { return }
            if recording && code == Self.escapeKey { cancelRecording(); return }
            guard keyIsDown, !handsFree else { return }
            otherKeyPressed = true                     // Fn + another key = a normal shortcut, not dictation
            if recording { cancelRecording() } else { pending?.cancel(); pending = nil }
            return
        }
        // fallback for keyboards the hardware watcher can't see
        guard Self.fnKeys.contains(code), !fnWatcher.isRunning else { return }
        fnChanged(down: event.flags.contains(.maskSecondaryFn))
    }

    /// Fn went down/up: hold → push-to-talk; 3 quick taps → hands-free; one tap during hands-free → stop.
    func fnChanged(down: Bool) {
        if down {
            guard !keyIsDown else { return }
            keyIsDown = true; otherKeyPressed = false; fnDownAt = Date()
            if recording && handsFree {               // tap to stop hands-free
                ignoreNextFnUp = true
                finishRecording(); return
            }
            let work = DispatchWorkItem { [weak self] in self?.startRecording(handsFree: false) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
        } else {
            guard keyIsDown else { return }
            keyIsDown = false
            pending?.cancel(); pending = nil
            if ignoreNextFnUp { ignoreNextFnUp = false; return }
            if recording && !handsFree { finishRecording(); return }
            // count quick taps for hands-free mode
            guard !recording, !otherKeyPressed, Date().timeIntervalSince(fnDownAt) < Self.tapMax else { taps.removeAll(); return }
            let now = Date()
            taps = taps.filter { now.timeIntervalSince($0) < Self.tripleWindow } + [now]
            if taps.count >= 3 { taps.removeAll(); startRecording(handsFree: true) }
        }
    }

    // MARK: dictation

    func startRecording(handsFree hf: Bool) {
        if !hf { guard keyIsDown, !otherKeyPressed, !recording else { return } }
        guard !recording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            hud.showNote("Allow the microphone, then try again", seconds: 4)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            hud.showSetup("Microphone is off", body: "Privacy & Security → Microphone → switch on “Mini Dictate”.",
                          button: "Open Settings", action: { [weak self] in
                              self?.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") })
            return
        }
        recording = true; handsFree = hf; startedAt = Date()
        targetApp = NSWorkspace.shared.frontmostApplication
        status = hf ? "Listening (hands-free)" : "Listening"
        hud.showListening(handsFree: hf)
        play("Tink")
        if hf { startCountdown() }
        let vocab = self.vocab
        Task {
            do { try await recognizer.start(vocab: vocab); diag("listening started (\(hf ? "hands-free" : "hold"))") }
            catch {
                diag("listening failed: \(error.localizedDescription)")
                await MainActor.run {
                    recording = false; handsFree = false; countdown?.invalidate()
                    hud.showNote("Couldn't start the microphone", seconds: 3)
                }
            }
        }
    }

    func startCountdown() {
        secondsLeft = Self.handsFreeLimit
        countdown?.invalidate()
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.recording else { self?.countdown?.invalidate(); return }
            self.secondsLeft -= 1
            self.hud.updateTimer(secondsLeft: max(0, self.secondsLeft))
            if self.secondsLeft <= 0 { diag("hands-free reached 1 minute — stopping"); self.finishRecording() }
        }
    }

    func cancelRecording() {
        recording = false; handsFree = false; countdown?.invalidate()
        status = "Ready"
        hud.showNote("Cancelled")
        Task { await recognizer.cancel() }
    }

    func finishRecording() {
        guard recording else { return }
        recording = false; handsFree = false; countdown?.invalidate()
        hud.showWorking()
        let app = targetApp
        let tone = Tone.forApp(bundleID: app?.bundleIdentifier)
        let ai = useAI, vocab = self.vocab
        Task {
            let raw = await recognizer.stop()
            diag("stopped: heard \(raw.split(separator: " ").count) words")      // count only
            guard !raw.isEmpty else {
                await MainActor.run { status = "Ready"; hud.showNote("Didn't catch that") }
                return
            }
            let result = await DictateFormatter.format(raw, tone: tone, useAI: ai, vocabulary: vocab)
            await self.deliver(result, to: app)   // deliver is @MainActor
        }
    }

    /// Paste only if a text box has the cursor; otherwise keep it in the card for Copy.
    @MainActor
    func deliver(_ result: FormatResult, to app: NSRunningApplication?) async {
        let focus = FocusProbe.focused(in: app)
        let finderNoField = app?.bundleIdentifier == "com.apple.finder" && !focus.editable
        var pasted = false
        if focus.secure || Paster.isSecureInputActive {
            hud.showText(result.text, title: "Password field — not pasted")
        } else if focus.knownNonText || finderNoField || app == nil {
            hud.showText(result.text, title: "No text box selected")
        } else {
            // Confirmed text box, OR an app that doesn't report its text boxes (WhatsApp, browsers, Electron…):
            // paste where the cursor is, and offer Copy for a moment in case that app ignored it.
            pasted = await Paster.paste(result.text, into: app)
            if pasted { hud.showPasted(text: result.text); play("Pop") } else { hud.showText(result.text, title: "Couldn't paste — copy it") }
        }
        history.insert(HistoryItem(text: result.text, path: result.path, app: app?.localizedName ?? "?", date: Date()), at: 0)
        if history.count > 30 { history.removeLast() }
        status = pasted ? "Last: pasted into \(app?.localizedName ?? "app")" : "Last: kept in pop-up"
        diag("result: \(result.path) · role=\(focus.role) editable=\(focus.editable) · pasted=\(pasted) · \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s")
    }
}
