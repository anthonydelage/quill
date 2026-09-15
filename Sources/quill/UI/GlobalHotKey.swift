import AppKit
import Carbon.HIToolbox

/// A parsed key combo like `"cmd+opt+ctrl+r"`: a set of modifiers plus one
/// named key. Parsed once and shared by `GlobalHotKey` (Carbon registration)
/// and `MenuBarController` (so the menu item displays the *real* shortcut
/// instead of drifting out of sync with it).
struct HotKeyCombo {
    enum Modifier: CaseIterable { case cmd, shift, opt, ctrl }

    let modifiers: Set<Modifier>
    let key: String // canonical lowercase key name, e.g. "r", "space", "f1"

    /// Parses combos like `"cmd+shift+r"` or `"ctrl+opt+space"`:
    /// case-insensitive, any order, `cmd`/`command`, `opt`/`alt`/`option`,
    /// `ctrl`/`control` all accepted. Requires at least one modifier — a
    /// bare key would swallow normal typing system-wide.
    init?(_ combo: String) {
        let parts = combo.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyPart = parts.last, Self.carbonKeyCodes[keyPart] != nil else { return nil }

        var mods: Set<Modifier> = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": mods.insert(.cmd)
            case "shift": mods.insert(.shift)
            case "opt", "alt", "option": mods.insert(.opt)
            case "ctrl", "control": mods.insert(.ctrl)
            default: return nil
            }
        }
        guard !mods.isEmpty else { return nil }

        modifiers = mods
        key = keyPart
    }

    // MARK: - Carbon (for RegisterEventHotKey)

    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.cmd) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        if modifiers.contains(.opt) { mask |= UInt32(optionKey) }
        if modifiers.contains(.ctrl) { mask |= UInt32(controlKey) }
        return mask
    }

    var carbonKeyCode: Int { Self.carbonKeyCodes[key]! }

    private static let carbonKeyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "tab": kVK_Tab, "return": kVK_Return, "enter": kVK_Return,
        "escape": kVK_Escape, "delete": kVK_Delete,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
        "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
        "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    // MARK: - AppKit (for NSMenuItem.keyEquivalent, display only)

    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.cmd) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.opt) { mask.insert(.option) }
        if modifiers.contains(.ctrl) { mask.insert(.control) }
        return mask
    }

    /// The character NSMenuItem expects as its `keyEquivalent`: letters and
    /// digits pass through as-is; named keys map to their Unicode function-
    /// key/control-key constants.
    var menuKeyEquivalent: String {
        switch key {
        case "space": return " "
        case "tab": return "\t"
        case "return", "enter": return "\r"
        case "escape": return "\u{1B}"
        case "delete": return "\u{8}"
        case "f1": return String(UnicodeScalar(NSF1FunctionKey)!)
        case "f2": return String(UnicodeScalar(NSF2FunctionKey)!)
        case "f3": return String(UnicodeScalar(NSF3FunctionKey)!)
        case "f4": return String(UnicodeScalar(NSF4FunctionKey)!)
        case "f5": return String(UnicodeScalar(NSF5FunctionKey)!)
        case "f6": return String(UnicodeScalar(NSF6FunctionKey)!)
        case "f7": return String(UnicodeScalar(NSF7FunctionKey)!)
        case "f8": return String(UnicodeScalar(NSF8FunctionKey)!)
        case "f9": return String(UnicodeScalar(NSF9FunctionKey)!)
        case "f10": return String(UnicodeScalar(NSF10FunctionKey)!)
        case "f11": return String(UnicodeScalar(NSF11FunctionKey)!)
        case "f12": return String(UnicodeScalar(NSF12FunctionKey)!)
        default: return key
        }
    }
}

/// A single system-wide keyboard shortcut, registered via Carbon's
/// `RegisterEventHotKey`. AppKit has no public global-hotkey API — Carbon's
/// is still the mechanism every menu-bar utility uses, and it works
/// regardless of which app has focus, unlike an `NSMenuItem` key equivalent
/// (which only fires while the menu is open).
@MainActor
final class GlobalHotKey {
    // deinit runs nonisolated even on a @MainActor type, so this can't be
    // actor-isolated; it's only ever touched from init (main actor) and
    // deinit (whichever thread drops the last reference), never concurrently.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    fileprivate let handler: () -> Void

    /// One shared Carbon event handler dispatches to whichever registered
    /// instance the pressed combo belongs to, keyed by hot-key ID.
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// Registers `combo` to fire `handler` from anywhere in macOS. Returns
    /// nil — after logging to stderr — if the OS refuses the registration
    /// (usually because another app already owns that combo).
    init?(combo: HotKeyCombo, handler: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.handler = handler

        if !Self.handlerInstalled {
            Self.installEventHandler()
            Self.handlerInstalled = true
        }

        // Signature is an arbitrary 4-char OSType identifying quill as the
        // owner; only meaningful if another process ever enumerates hotkeys.
        let hotKeyID = EventHotKeyID(signature: OSType(0x7175_696c) /* 'quil' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.carbonKeyCode), combo.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            FileHandle.standardError.write(Data(
                "warning: could not register global hotkey (already in use by another app?) — ignoring\n".utf8
            ))
            return nil
        }

        hotKeyRef = ref
        Self.registry[id] = self
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    private static func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let firedID = hotKeyID.id
            Task { @MainActor in GlobalHotKey.registry[firedID]?.handler() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
