import Carbon.HIToolbox
import Foundation
import GlintCore
import GlintUI

/// Registers one system-wide shortcut with Carbon's hot key API, which needs no
/// Accessibility permission (unlike event taps).
@MainActor
final class HotKeyCenter {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// Registers `combo`, replacing any previous registration. Returns false if the shortcut
    /// is taken by another app.
    @discardableResult
    func register(_ combo: KeyCombo, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action
        installHandlerIfNeeded()
        var modifiers: UInt32 = 0
        if combo.command { modifiers |= UInt32(cmdKey) }
        if combo.option { modifiers |= UInt32(optionKey) }
        if combo.control { modifiers |= UInt32(controlKey) }
        if combo.shift { modifiers |= UInt32(shiftKey) }
        let identifier = EventHotKeyID(signature: OSType(0x474C_4E54), id: 1)  // 'GLNT'
        let status = RegisterEventHotKey(combo.keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            Log.app.error("Could not register the search shortcut (status \(status, privacy: .public))")
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { center.action?() }
            return noErr
        }, 1, &spec, context, &handler)
    }
}
