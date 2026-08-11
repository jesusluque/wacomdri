// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

extension KeyCode {
    /// Human-readable name for a virtual key code.
    ///
    /// These are physical key positions, so the table is for display only —
    /// on a non-US layout the legend printed on the key may differ. The
    /// preferences app prefers the character the capture actually produced and
    /// falls back to this.
    public static func name(for code: UInt16) -> String {
        if let special = specialNames[code] { return special }
        if let character = characterNames[code] { return character }
        return "Key \(code)"
    }

    private static let specialNames: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        76: "Enter", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let characterNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 50: "`",
    ]
}

extension Modifiers {
    /// The symbols macOS uses in menus, in Apple's canonical order.
    public var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

extension PadAction {
    /// Short label for a binding, e.g. "⇧⌘Z" or "Hold Space".
    public var displayName: String {
        switch self {
        case .none:
            return "—"
        case .tapKey(let code, let modifiers):
            return modifiers.symbols + KeyCode.name(for: code)
        case .holdKey(let code, let modifiers):
            return "Hold " + modifiers.symbols + KeyCode.name(for: code)
        case .leftClick: return "Left click"
        case .rightClick: return "Right click"
        case .middleClick: return "Middle click"
        case .doubleClick: return "Double click"
        }
    }
}

extension StripAction {
    public var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .scrollVertical(let inverted): return inverted ? "Scroll up" : "Scroll down"
        case .scrollHorizontal(let inverted): return inverted ? "Scroll left" : "Scroll right"
        case .keySteps: return "Keystrokes"
        }
    }
}
