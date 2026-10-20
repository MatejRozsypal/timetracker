import Carbon.HIToolbox
import Foundation

/// A single global hotkey via Carbon's RegisterEventHotKey. No permission prompt.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(spec: String, action: @escaping () -> Void) {
        self.action = action
        guard let (code, mods) = Self.parse(spec) else { return nil }

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hk = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hk.action() }
            return noErr
        }, 1, &type, selfPtr, &handler)

        let id = EventHotKeyID(signature: OSType(0x4F45544C), id: 1) // "OETL"
        let status = RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Parses "opt+cmd+L" style specs.
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for raw in spec.lowercased().split(separator: "+").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            switch raw {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default: key = keyCodes[raw]
            }
        }
        guard let key, mods != 0 else { return nil }
        return (key, mods)
    }

    /// "opt+cmd+L" -> "⌥⌘L", in the standard macOS modifier order.
    static func display(_ spec: String) -> String {
        let parts = spec.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        var out = ""
        if parts.contains(where: { ["ctrl", "control"].contains($0) }) { out += "⌃" }
        if parts.contains(where: { ["opt", "option", "alt"].contains($0) }) { out += "⌥" }
        if parts.contains("shift") { out += "⇧" }
        if parts.contains(where: { ["cmd", "command"].contains($0) }) { out += "⌘" }
        let key = parts.first { !["ctrl", "control", "opt", "option", "alt", "shift", "cmd", "command"].contains($0) } ?? ""
        return out + (key == "space" ? "Space" : key.uppercased())
    }

    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z), "space": UInt32(kVK_Space),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
    ]
}
