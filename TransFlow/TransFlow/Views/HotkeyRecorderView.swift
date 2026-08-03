import SwiftUI
import Carbon.HIToolbox

/// Records a global hotkey binding from a local key event monitor.
struct HotkeyRecorderView: View {
    @Binding var binding: HotkeyBinding
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if !binding.isEmpty {
                Button {
                    binding = .empty
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(displayText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isRecording ? .white : (binding.isEmpty ? .secondary : .primary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isRecording
                                  ? AnyShapeStyle(Color.accentColor)
                                  : AnyShapeStyle(.quaternary.opacity(0.5)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(isRecording ? Color.accentColor : .clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let keyCode = event.keyCode

            if keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if modifiers.isEmpty { return nil }

            binding = HotkeyBinding(
                keyCode: keyCode,
                modifiers: modifiers.rawValue
            )
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private var displayText: String {
        if isRecording {
            return String(localized: "settings.hotkey.recording")
        }
        if binding.isEmpty {
            return String(localized: "settings.hotkey.not_set")
        }
        return binding.displayString
    }
}
