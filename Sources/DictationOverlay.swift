import AppKit
import SwiftUI

@MainActor
private final class DictationOverlayState: ObservableObject {
    @Published var level = 0.0
    @Published var isStarting = true
    @Published var requiresHeldShortcut = true
}

@MainActor
final class DictationOverlayController {
    private let state = DictationOverlayState()
    private var panel: NSPanel?

    func show(requiresHeldShortcut: Bool) {
        state.level = 0
        state.isStarting = true
        state.requiresHeldShortcut = requiresHeldShortcut

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 110),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: DictationOverlayView(state: state))
            self.panel = panel
        }

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.frame.midX - 150, y: screen.frame.midY - 55))
        }
        panel?.orderFrontRegardless()
    }

    func update(level: Double, isStarting: Bool) {
        state.level = level
        state.isStarting = isStarting
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct DictationOverlayView: View {
    @ObservedObject var state: DictationOverlayState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 38, height: 38)
                    .background(.cyan.opacity(0.13), in: Circle())

                if state.isStarting {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        HStack(spacing: 4) {
                            ForEach(0..<25) { index in
                                Capsule()
                                    .fill(.cyan.opacity(0.55 + Double(index % 3) * 0.2))
                                    .frame(width: 4, height: barHeight(index, time: context.date.timeIntervalSinceReferenceDate))
                            }
                        }
                        .frame(height: 40)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text(state.isStarting ? "Preparing microphone…" : finishHint)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .frame(width: 300, height: 110)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.isStarting ? "Preparing microphone" : "Dictating")
        .accessibilityValue("\(Int(state.level * 100)) percent audio level")
    }

    private var finishHint: String {
        state.requiresHeldShortcut ? "Release ⌥Space to transcribe" : "Finish dictation from the menu"
    }

    private func barHeight(_ index: Int, time: TimeInterval) -> Double {
        let center = 1 - abs(Double(index) - 12) / 14
        let motion = 0.45 + 0.55 * abs(sin(time * 7 + Double(index) * 0.55))
        return 4 + 35 * center * motion * max(0.04, min(1, state.level))
    }
}
