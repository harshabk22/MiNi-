import AppKit

/// Mini Flow's on-screen indicator, in two standard shapes:
///  • a small pill while listening/working (mic level bars + short status + timer in hands-free mode)
///  • a compact card only when there's something to act on (text you need to copy, a setup step)
/// It never takes focus from your app (non-activating panel), so pasting still goes where your cursor is.
final class FlowHUD: NSObject {
    private let panel: NSPanel
    private let bg = NSVisualEffectView()
    private let levels = LevelBars()
    private let label = NSTextField(labelWithString: "")
    private let timerLabel = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "Copy", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private var primary: (() -> Void)?
    private var secondary: (() -> Void)?
    private var hideTimer: Timer?
    private(set) var currentText = ""

    static let pillSize = NSSize(width: 300, height: 40)
    static let cardWidth: CGFloat = 400

    override init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.pillSize),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        super.init()
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        bg.material = .hudWindow; bg.blendingMode = .behindWindow; bg.state = .active
        bg.wantsLayer = true; bg.layer?.cornerCurve = .continuous; bg.layer?.masksToBounds = true
        panel.contentView = bg

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingHead           // live text: always show the newest words
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timerLabel.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: 13)
        body.textColor = .labelColor
        body.isSelectable = true
        body.maximumNumberOfLines = 8

        for b in [primaryButton, secondaryButton] {
            b.bezelStyle = .rounded; b.controlSize = .small; b.target = self
        }
        primaryButton.action = #selector(primaryClicked)
        primaryButton.keyEquivalent = ""
        secondaryButton.action = #selector(secondaryClicked)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self; closeButton.action = #selector(close)

        for v in [levels, label, timerLabel, body, primaryButton, secondaryButton, closeButton] as [NSView] { bg.addSubview(v) }
    }

    // MARK: states

    func showListening(handsFree: Bool) {
        hideTimer?.invalidate()
        currentText = ""
        label.stringValue = handsFree ? "Listening — tap Fn to stop" : "Listening…"
        label.textColor = .secondaryLabelColor
        timerLabel.stringValue = handsFree ? "1:00" : ""
        levels.reset(); levels.color = .systemRed
        layoutPill()
        show()
    }

    func updatePartial(_ text: String) {
        guard panel.isVisible, !text.isEmpty else { return }
        label.stringValue = text.replacingOccurrences(of: "\n", with: " ")
        label.textColor = .labelColor
    }

    func updateLevel(_ level: Float) { levels.push(level) }

    func updateTimer(secondsLeft: Int) { timerLabel.stringValue = String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60) }

    func showWorking() {
        label.stringValue = "Writing…"; label.textColor = .secondaryLabelColor
        timerLabel.stringValue = ""
        levels.color = .systemBlue; levels.reset()
        layoutPill()
    }

    /// Pasted: a brief confirmation with a Copy button, in case the app ignored the paste.
    func showPasted(text: String) {
        currentText = text; primary = nil
        label.stringValue = "Pasted"; label.textColor = .labelColor
        timerLabel.stringValue = ""
        levels.showCheck()
        layoutPill(withCopy: true)
        scheduleHide(after: 3)
    }

    /// Not pasted (no text box, or a password field): show the text with Copy.
    func showText(_ text: String, title: String) {
        hideTimer?.invalidate()
        currentText = text
        primary = nil
        layoutCard(title: title, text: text, button: "Copy", second: nil)
        show()
        scheduleHide(after: 20)
    }

    /// A short note in the pill (cancelled, nothing heard…).
    func showNote(_ text: String, seconds: Double = 1.8) {
        label.stringValue = text; label.textColor = .secondaryLabelColor
        timerLabel.stringValue = ""
        levels.reset(); levels.color = .systemGray
        layoutPill()
        show()
        scheduleHide(after: seconds)
    }

    /// Something the user has to do (permissions, a setting). Stays until fixed or closed.
    func showSetup(_ title: String, body text: String, button: String, action: @escaping () -> Void,
                   second: (String, () -> Void)? = nil) {
        hideTimer?.invalidate()
        primary = action
        secondary = second?.1
        layoutCard(title: title, text: text, button: button, second: second?.0)
        show()
    }

    func hide() { hideTimer?.invalidate(); panel.orderOut(nil) }

    // MARK: actions

    @objc private func primaryClicked() {
        if let primary { primary(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentText, forType: .string)
        primaryButton.title = "Copied"
        scheduleHide(after: 1.0)
    }
    @objc private func secondaryClicked() { secondary?() }
    @objc private func close() { hide() }

    // MARK: layout (manual frames: small, predictable, no constraint churn)

    private func layoutPill(withCopy: Bool = false) {
        for v in [body, primaryButton, secondaryButton, closeButton] as [NSView] { v.isHidden = true }
        for v in [levels, label, timerLabel] as [NSView] { v.isHidden = false }
        let size = Self.pillSize
        setPanelSize(size)
        bg.layer?.cornerRadius = size.height / 2
        if withCopy {
            primaryButton.isHidden = false; primaryButton.title = "Copy"; primaryButton.sizeToFit()
            primaryButton.frame.origin = NSPoint(x: size.width - 12 - primaryButton.frame.width,
                                                 y: (size.height - primaryButton.frame.height) / 2)
        }
        let timerW: CGFloat = withCopy ? primaryButton.frame.width + 4 : (timerLabel.stringValue.isEmpty ? 0 : 38)
        levels.frame = NSRect(x: 16, y: (size.height - 16) / 2, width: 26, height: 16)
        label.frame = NSRect(x: 50, y: (size.height - 18) / 2, width: size.width - 50 - 16 - timerW, height: 18)
        timerLabel.frame = NSRect(x: size.width - 16 - timerW, y: (size.height - 16) / 2, width: timerW, height: 16)
    }

    private func layoutCard(title: String, text: String, button: String, second: String?) {
        for v in [levels, timerLabel] as [NSView] { v.isHidden = true }
        for v in [label, body, primaryButton, closeButton] as [NSView] { v.isHidden = false }
        secondaryButton.isHidden = second == nil
        label.stringValue = title; label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        body.stringValue = text
        primaryButton.title = button
        secondaryButton.title = second ?? ""
        let w = Self.cardWidth, pad: CGFloat = 16
        let textH = min(body.sizeThatFits(NSSize(width: w - 2 * pad, height: 1000)).height, 170)
        let h = pad + 18 + 8 + textH + 12 + 24 + pad
        setPanelSize(NSSize(width: w, height: h))
        bg.layer?.cornerRadius = 14
        closeButton.frame = NSRect(x: w - pad - 16, y: h - pad - 17, width: 16, height: 16)
        label.frame = NSRect(x: pad, y: h - pad - 18, width: w - 2 * pad - 24, height: 18)
        body.frame = NSRect(x: pad, y: pad + 24 + 12, width: w - 2 * pad, height: textH)
        primaryButton.sizeToFit(); secondaryButton.sizeToFit()
        primaryButton.frame.origin = NSPoint(x: w - pad - primaryButton.frame.width, y: pad - 2)
        secondaryButton.frame.origin = NSPoint(x: primaryButton.frame.minX - 8 - secondaryButton.frame.width, y: pad - 2)
        label.lineBreakMode = .byTruncatingHead
    }

    private func setPanelSize(_ size: NSSize) {
        var f = panel.frame
        let centerX = f.midX
        f.size = size
        if panel.isVisible { f.origin.x = centerX - size.width / 2 }   // stay centred, anchored at the bottom
        panel.setFrame(f, display: true)
    }

    private func show() {
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let vf = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.minY + 24))
            }
        }
        panel.orderFrontRegardless()
    }

    private func scheduleHide(after seconds: Double) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.hide() }
    }
}

/// Five small bars that follow the microphone level (shows the mic is really hearing you).
final class LevelBars: NSView {
    private var values = [Float](repeating: 0, count: 5)
    private var check = false
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    func push(_ level: Float) {
        check = false
        values.removeFirst(); values.append(max(0, min(1, level)))
        needsDisplay = true
    }
    func reset() { check = false; values = [Float](repeating: 0, count: 5); needsDisplay = true }
    func showCheck() { check = true; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if check {
            let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
            NSColor.systemGreen.set()
            img?.isTemplate = true
            let tinted = img.map { i -> NSImage in
                let t = i.copy() as! NSImage; t.lockFocus(); NSColor.systemGreen.set()
                NSRect(origin: .zero, size: t.size).fill(using: .sourceAtop); t.unlockFocus(); return t
            }
            tinted?.draw(in: NSRect(x: (bounds.width - 16) / 2, y: 0, width: 16, height: 16))
            return
        }
        color.setFill()
        let w: CGFloat = 3, gap = (bounds.width - 5 * w) / 4
        for (i, v) in values.enumerated() {
            let h = max(3, CGFloat(v) * bounds.height)
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
