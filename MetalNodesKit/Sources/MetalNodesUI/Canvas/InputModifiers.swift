import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Modifier keys at the moment a gesture starts. SwiftUI gestures don't expose them.
enum InputModifiers {
    static func selectionMode() -> SelectionMode {
        #if os(macOS)
        let f = current
        if f.contains(.command) { return .toggle }
        if f.contains(.shift) { return .add }
        #endif
        return .replace
    }

    static var shiftHeld: Bool {
        #if os(macOS)
        current.contains(.shift)
        #else
        false
        #endif
    }

    static var optionHeld: Bool {
        #if os(macOS)
        current.contains(.option)
        #else
        false
        #endif
    }

    #if os(macOS)
    /// The event that started the gesture carries its own flags; the class-level
    /// state covers keys pressed after mouse-down. Synthesized events (accessibility,
    /// automation) only set the former, so read both.
    private static var current: NSEvent.ModifierFlags {
        let event = NSApp.currentEvent?.modifierFlags ?? []
        return event.union(NSEvent.modifierFlags).intersection(.deviceIndependentFlagsMask)
    }
    #endif
}
