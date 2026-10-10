import AppKit
import SwiftUI

/// Records a global shortcut: click, then press the keys. Esc cancels; a modifier is required.
public struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo
    @State private var isRecording = false
    @State private var monitor: Any?

    public init(combo: Binding<KeyCombo>) {
        _combo = combo
    }

    public var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? String(localized: "Type Shortcut…") : combo.displayString)
                .frame(minWidth: 110)
                .monospaced(!isRecording)
        }
        .accessibilityLabel(Text("Search shortcut"))
        .accessibilityValue(Text(verbatim: combo.displayString))
        .accessibilityHint(Text("Click, then press the new key combination"))
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let candidate = KeyCombo(
                keyCode: UInt32(event.keyCode),
                command: flags.contains(.command),
                option: flags.contains(.option),
                control: flags.contains(.control),
                shift: flags.contains(.shift)
            )
            guard candidate.hasModifier else {
                NSSound.beep()
                return nil
            }
            combo = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
