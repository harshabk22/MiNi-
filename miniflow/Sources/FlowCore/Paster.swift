import AppKit
import Carbon
import Foundation

/// Puts text at the cursor of the app you were in: clipboard + ⌘V, then your clipboard is restored.
public enum Paster {
    /// macOS turns this on in password fields; we never paste dictation into those.
    public static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    @MainActor
    public static func paste(_ text: String, into app: NSRunningApplication?) async -> Bool {
        if isSecureInputActive { return false }
        let pb = NSPasteboard.general
        // Save everything on the clipboard (all types), so it can be put back exactly.
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        pb.clearContents()
        pb.setString(text, forType: .string)

        if let app, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // 9 = V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 400_000_000)       // let the app read the clipboard first
        pb.clearContents()
        if !saved.isEmpty {
            let items = saved.map { d -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, v) in d { item.setData(v, forType: t) }
                return item
            }
            pb.writeObjects(items)
        }
        return true
    }
}
