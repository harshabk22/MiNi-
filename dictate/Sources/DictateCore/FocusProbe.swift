import AppKit
import ApplicationServices

/// Is there a text cursor (an editable text field) in the app right now? Uses the Accessibility API, read-only.
public enum FocusProbe {
    public struct Info: Sendable {
        public let editable: Bool     // a text field / text area / editable web or chat box has focus (confirmed)
        public let secure: Bool       // a password field
        public let role: String
        /// Focus is on something that clearly can't take text (button, image, menu…). Many apps — WhatsApp,
        /// browsers, Electron apps — don't report their text boxes at all ("none" / "AXWebArea"), so an
        /// UNKNOWN focus is NOT treated as "no text box": we paste there (many chat and web text boxes report no role).
        public var knownNonText: Bool { FocusProbe.nonTextRoles.contains(role) }
    }

    static let nonTextRoles: Set<String> = ["AXButton", "AXImage", "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem",
        "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXDisclosureTriangle", "AXToolbar", "AXTabGroup",
        "AXColorWell", "AXIncrementor", "AXDockItem"]

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    public static func focused(in app: NSRunningApplication?) -> Info {
        let pid = app?.processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let appElement = AXUIElementCreateApplication(pid)
        // Electron/Chromium apps (VS Code, Slack, Discord…) only publish their text fields once asked to.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var ref: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &ref)
        if err != .success {
            err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &ref)
        }
        guard err == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return Info(editable: false, secure: false, role: "none")
        }
        let element = ref as! AXUIElement
        let role = string(element, kAXRoleAttribute) ?? "?"
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let secure = subrole == (kAXSecureTextFieldSubrole as String)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        var range: CFTypeRef?
        let hasCursor = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
        let editable = !secure && (textRoles.contains(role) || (hasCursor && settable.boolValue))
        return Info(editable: editable, secure: secure, role: role)
    }

    /// The text in the focused text box, if the app exposes it (used to confirm a paste really landed).
    public static func focusedValue(in app: NSRunningApplication?) -> String? {
        let pid = app?.processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        if string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return nil }
        return string(element, kAXValueAttribute)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// macOS's own action for the Fn/🌐 key (-1 = macOS default, never changed; 0 = do nothing; 1 = input source;
    /// 2 = emoji; 3 = dictation).
    public static var fnKeySystemAction: Int {
        KeyPolicy.fnAction(from: UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType"))
    }

    /// Apple's own Dictation is on (its shortcut is often "Press 🌐 twice", which clashes with tap ×3).
    public static var appleDictationEnabled: Bool {
        UserDefaults(suiteName: "com.apple.assistant.support")?.bool(forKey: "Dictation Enabled") ?? false
    }

    public static var fnConflict: Bool { KeyPolicy.fnConflict(fnAction: fnKeySystemAction, dictation: appleDictationEnabled) }
}
