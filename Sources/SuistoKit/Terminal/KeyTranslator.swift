import AppKit
import RioKit

/// Turns an `NSEvent` into the key report librio expects.
///
/// The division of labour is librio's: the host says what the user physically
/// did, and librio decides what bytes the terminal receives, because that
/// depends on state the host does not track (application cursor mode, the
/// kitty keyboard flags, modifyOtherKeys).
enum KeyTranslator {
    /// `NSBackTabCharacter`: what AppKit sends for Shift-Tab.
    private static let backTab: UInt32 = 0x19

    /// AppKit delivers special keys as private-use scalars.
    private static let functionKeyTags: [Int: UInt32] = [
        NSUpArrowFunctionKey: RIO_KEY_UP,
        NSDownArrowFunctionKey: RIO_KEY_DOWN,
        NSLeftArrowFunctionKey: RIO_KEY_LEFT,
        NSRightArrowFunctionKey: RIO_KEY_RIGHT,
        NSHomeFunctionKey: RIO_KEY_HOME,
        NSEndFunctionKey: RIO_KEY_END,
        NSPageUpFunctionKey: RIO_KEY_PAGE_UP,
        NSPageDownFunctionKey: RIO_KEY_PAGE_DOWN,
        NSInsertFunctionKey: RIO_KEY_INSERT,
        NSDeleteFunctionKey: RIO_KEY_DELETE,
    ]

    static func mods(from flags: NSEvent.ModifierFlags) -> UInt8 {
        var mods: UInt8 = 0
        if flags.contains(.shift) { mods |= UInt8(RIO_MOD_SHIFT) }
        if flags.contains(.control) { mods |= UInt8(RIO_MOD_CTRL) }
        if flags.contains(.option) { mods |= UInt8(RIO_MOD_ALT) }
        if flags.contains(.command) { mods |= UInt8(RIO_MOD_SUPER) }
        return mods
    }

    /// Builds the event. `text` is what the platform produced for this key
    /// after any dead-key or input-method composition, or nil when it produced
    /// nothing. `composing` tells librio an input method owns the key, so
    /// nothing should be encoded yet.
    ///
    /// The returned struct borrows `text`, so it is only valid inside `body`.
    @discardableResult
    static func withKeyEvent<R>(
        for event: NSEvent,
        text: String?,
        composing: Bool = false,
        action: UInt32 = RIO_KEY_ACTION_PRESS,
        _ body: (rio_key_event_s) -> R
    ) -> R {
        // The tag names the key with *no* shift applied: shift+a is CHAR 'a',
        // and the "A" belongs in `text`.
        let unshifted = event.charactersIgnoringModifiers ?? ""
        var tag = RIO_KEY_CHAR
        var codepoint: UInt32 = 0
        var functionKey: UInt8 = 0

        if let scalar = unshifted.unicodeScalars.first {
            let value = Int(scalar.value)
            if let mapped = functionKeyTags[value] {
                tag = mapped
            } else if value >= NSF1FunctionKey, value <= NSF12FunctionKey {
                tag = RIO_KEY_F
                functionKey = UInt8(value - NSF1FunctionKey + 1)
            } else {
                switch scalar.value {
                case 0x0D, 0x03:        // Return, Enter
                    tag = RIO_KEY_ENTER
                case 0x09, Self.backTab:
                    // AppKit does not report Shift-Tab as Tab with a shift
                    // flag: it delivers NSBackTabCharacter, U+0019, as both
                    // the characters and the unshifted characters. Left to
                    // fall through, that is an ordinary character and librio
                    // encodes the raw 0x19 byte — Ctrl-Y, which every
                    // readline-style editor reads as "yank", so Shift-Tab
                    // pasted instead of sending CSI Z.
                    tag = RIO_KEY_TAB
                case 0x7F:              // AppKit sends DEL for the Backspace key
                    tag = RIO_KEY_BACKSPACE
                case 0x1B:
                    tag = RIO_KEY_ESCAPE
                default:
                    tag = RIO_KEY_CHAR
                    codepoint = scalar.value
                }
            }
        } else {
            tag = RIO_KEY_NONE
        }

        var consumed: UInt8 = 0
        // macOS already spent shift producing the uppercase/symbol text, so
        // librio must not encode it a second time. Alt is left unconsumed: with
        // alt-is-meta on (librio's default, and every terminal's) it has to
        // reach librio to become an ESC prefix.
        if tag == RIO_KEY_CHAR, let text, !text.isEmpty,
           event.modifierFlags.contains(.shift) {
            consumed |= UInt8(RIO_MOD_SHIFT)
        }

        var key = rio_key_event_s()
        key.action = action
        key.tag = tag
        key.codepoint = codepoint
        key.function_key = functionKey
        key.mods = mods(from: event.modifierFlags)
        key.consumed_mods = consumed
        key.composing = composing

        // The backtab character is in `text` as well, and librio sends text
        // in preference to encoding the key. Drop it, or the fix above is
        // undone whenever the input context declines the key and leaves
        // `event.characters` to stand in for it.
        let payload = text.flatMap { $0.unicodeScalars.first?.value == Self.backTab ? nil : $0 }

        guard let payload, !payload.isEmpty else {
            key.text = nil
            key.text_len = 0
            return body(key)
        }
        return payload.withCString { pointer in
            key.text = pointer
            key.text_len = strlen(pointer)
            return body(key)
        }
    }

    /// A text-only event, for an input method commit that is not tied to a
    /// key press.
    @discardableResult
    static func withTextEvent<R>(_ text: String, _ body: (rio_key_event_s) -> R) -> R {
        var key = rio_key_event_s()
        key.action = RIO_KEY_ACTION_PRESS
        key.tag = RIO_KEY_NONE
        return text.withCString { pointer in
            key.text = pointer
            key.text_len = strlen(pointer)
            return body(key)
        }
    }
}
