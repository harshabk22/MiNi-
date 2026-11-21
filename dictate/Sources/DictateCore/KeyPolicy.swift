import Foundation

/// Decisions about the Fn / 🌐 key, kept free of AppKit so they can be tested.
public enum KeyPolicy {
    public static let escapeKey: Int64 = 53

    /// macOS's "Press 🌐 key to" setting. The key is ABSENT until the user changes it, and absent means macOS's own
    /// default action (emoji picker / input source), not "Do Nothing". -1 = default, 0 = Do Nothing, 1–3 = an action.
    public static func fnAction(from value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return -1
    }

    /// macOS will also react to 🌐 (its own action, or Apple Dictation's 🌐 shortcut), so apps see extra pop-ups/keys.
    public static func fnConflict(fnAction: Int, dictation: Bool) -> Bool { fnAction != 0 || dictation }

    /// macOS sends an Escape by itself the instant 🌐 goes down. Apps (WhatsApp, browsers) react to it — closing a
    /// chat or dropping the text cursor — so Mini Dictate swallows that one Escape.
    public static func isAutoEscape(code: Int64, sinceFnDown: TimeInterval) -> Bool {
        code == escapeKey && sinceFnDown >= 0 && sinceFnDown < 0.25
    }
}
