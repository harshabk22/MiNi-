import Foundation
import IOKit.hid

/// Watches the physical Fn / 🌐 key at the hardware (HID) level. This reports the real key press even when macOS
/// uses the 🌐 key for its own action (emoji picker, input source…), which changes the normal keyboard event.
/// Read-only: it never blocks or alters any key. Needs Input Monitoring permission.
final class FnKeyWatcher {
    private var manager: IOHIDManager?
    var onChange: ((Bool) -> Void)?           // true = Fn went down, false = Fn came up
    private(set) var isRunning = false

    // Apple's vendor "top case" page: usage 0x03 is the Fn/🌐 key on Mac keyboards (built-in and Magic Keyboard).
    static let appleVendorTopCasePage: Int = 0xFF
    static let appleVendorKeyboardPage: Int = 0xFF01
    static let fnUsage: Int = 0x03

    func start() -> Bool {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: Self.appleVendorTopCasePage],
            [kIOHIDDeviceUsagePageKey: Self.appleVendorKeyboardPage],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { context, _, _, value in
            guard let context else { return }
            let me = Unmanaged<FnKeyWatcher>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = Int(IOHIDElementGetUsagePage(element)), usage = Int(IOHIDElementGetUsage(element))
            guard usage == FnKeyWatcher.fnUsage,
                  page == FnKeyWatcher.appleVendorTopCasePage || page == FnKeyWatcher.appleVendorKeyboardPage else { return }
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            DispatchQueue.main.async { me.onChange?(pressed) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        isRunning = result == kIOReturnSuccess
        return isRunning
    }
}
