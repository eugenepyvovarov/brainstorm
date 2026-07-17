import AppKit
import SwiftUI

/// Opens the system Character Viewer / emoji palette and reports the first inserted grapheme.
struct EmojiPickerBridge: NSViewRepresentable {
    @Binding var isPresented: Bool
    var onPick: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onPick = onPick
        if isPresented {
            context.coordinator.presentPalette()
            DispatchQueue.main.async {
                isPresented = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var hostView: NSView?
        var onPick: ((String) -> Void)?
        private var field: NSTextField?
        private var didInstall = false

        func presentPalette() {
            ensureField()
            guard let field else {
                NSApp.orderFrontCharacterPalette(nil)
                return
            }
            let window = hostView?.window ?? NSApp.keyWindow
            field.stringValue = ""
            window?.makeFirstResponder(field)
            NSApp.orderFrontCharacterPalette(field)
        }

        private func ensureField() {
            guard !didInstall, let hostView else { return }
            didInstall = true
            let field = NSTextField(frame: NSRect(x: -2, y: -2, width: 1, height: 1))
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 1)
            field.alphaValue = 0.01
            field.delegate = self
            hostView.addSubview(field)
            self.field = field
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let raw = field.stringValue
            let emoji = EmojiUsageStore.normalize(raw)
            guard !emoji.isEmpty else { return }
            field.stringValue = ""
            onPick?(emoji)
            field.window?.makeFirstResponder(nil)
        }
    }
}

/// Compact control: shortlist chips + system emoji picker.
struct EmojiSelectorRow: View {
    let shortlist: [String]
    let selected: String?
    var onSelect: (String) -> Void
    var onClear: () -> Void
    var onOpenPicker: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onOpenPicker()
                } label: {
                    Label("Emoji…", systemImage: "face.smiling")
                }
                .controlSize(.small)

                Button("Clear") { onClear() }
                    .controlSize(.small)
                    .disabled(selected == nil || selected?.isEmpty == true)
            }

            if shortlist.isEmpty {
                Text("Recently used emojis show up here after you pick one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Recent & most used")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 6)], spacing: 6) {
                    ForEach(shortlist, id: \.self) { emoji in
                        let isSelected = selected == emoji
                        Button {
                            onSelect(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 22))
                                .frame(width: 32, height: 32)
                                .background {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.22))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
