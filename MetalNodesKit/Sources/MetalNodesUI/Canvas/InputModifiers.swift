import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Modifier keys at the moment a gesture starts. SwiftUI gestures don't expose them.
enum InputModifiers {
    static func selectionMode() -> SelectionMode {
        #if os(macOS)
        let f = NSEvent.modifierFlags
        if f.contains(.command) { return .toggle }
        if f.contains(.shift) { return .add }
        #endif
        return .replace
    }

    static var shiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    static var optionHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }
}
