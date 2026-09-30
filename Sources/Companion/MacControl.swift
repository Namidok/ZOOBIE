import AppKit
import CompanionCore

/// Low-level input for the agent: media keys, mouse clicks, key presses and typing, posted as
/// system events. Requires Accessibility permission (already needed for hold-⌃⌥).
enum MacControl {
    // MARK: Media keys

    /// NX_KEYTYPE_* codes for the hardware media keys.
    private static let mediaKeys: [String: Int32] = [
        "play_pause": 16, "next": 17, "previous": 18, "volume_up": 0, "volume_down": 1, "mute": 7,
    ]

    static func media(_ command: String) -> String {
        guard let key = mediaKeys[command] else { return "Unknown media command \(command)." }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | (Int32(down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
        return "Pressed the \(command.replacingOccurrences(of: "_", with: "/")) media key."
    }

    // MARK: Mouse

    /// Clicks at a point in AppKit global coordinates, then puts the pointer back where it was.
    static func click(at point: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = CGPoint(x: point.x, y: primaryHeight - point.y) // CG events use a top-left origin
        let original = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(25_000)
        }
        if let original {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Keyboard

    private static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53, "forwarddelete": 117, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let functionKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() { map["f\(index + 1)"] = code }
        return map
    }()

    /// Presses a shortcut like "cmd+shift+t" in the frontmost app.
    static func pressKeys(_ keys: String) -> String {
        let parts = AgentAction.normalizedKeys(keys).split(separator: "+").map(String.init)
        var flags: CGEventFlags = []
        var key: String?
        for part in parts {
            switch part {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default: key = part
            }
        }
        guard let key, let code = keyCodes[key] else { return "Unknown key in \(keys)." }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(15_000)
        }
        return "Pressed \(keys)."
    }

    /// Types text into whatever has keyboard focus.
    static func typeText(_ text: String) -> String {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            var chunk = Array(units[start..<min(start + 16, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event?.post(tap: .cghidEventTap)
            }
            usleep(10_000)
        }
        return "Typed \(text.count) characters."
    }
}
