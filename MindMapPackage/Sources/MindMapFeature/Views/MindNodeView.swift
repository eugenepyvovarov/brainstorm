import AppKit
import SwiftUI

struct MindNodeView: View {
    let layoutNode: LayoutNode
    let isRoot: Bool
    let isSelected: Bool
    let isEditing: Bool
    let isDropTarget: Bool
    let editSeed: String?
    /// Shared focus token from the parent — kept in sync for canvas shortcut handoff.
    var focusToken: FocusState<UUID?>.Binding

    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onDraftChange: (String) -> Void
    let onLiveTitle: (String) -> Void
    let onToggleExpand: () -> Void
    let onAddChild: () -> Void
    let onDelete: () -> Void
    let onDeleteSingle: () -> Void
    let onDropNode: (UUID) -> Bool
    let onDropTargeted: (Bool) -> Void

    @State private var draft: String = ""
    @State private var isHovered = false
    @State private var liveWriteTask: Task<Void, Never>?
    /// Bumped when editing starts so the AppKit field reclaims first responder.
    @State private var focusNonce: Int = 0

    private var showNodeWell: Bool {
        !isEditing && (isSelected || isHovered)
    }

    private var displayTitle: String {
        if layoutNode.title.isEmpty {
            return isRoot ? MindNode.mainPlaceholder : MindNode.nodePlaceholder
        }
        return layoutNode.title
    }

    private var placeholder: String {
        isRoot ? MindNode.mainPlaceholder : MindNode.nodePlaceholder
    }

    var body: some View {
        HStack(spacing: 6) {
            nodeCard
                .draggable(layoutNode.id.uuidString) {
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let draggedID = UUID(uuidString: raw) else {
                        return false
                    }
                    return onDropNode(draggedID)
                } isTargeted: { targeted in
                    onDropTargeted(targeted)
                }

            if layoutNode.hasChildren && !isEditing {
                foldControl
            }

            if showNodeWell {
                nodeWell
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.1), value: showNodeWell)
        .onHover { isHovered = $0 }
        .contextMenu { contextMenuItems }
        .onChange(of: isEditing) { _, editing in
            if editing {
                draft = editSeed ?? layoutNode.title
                focusNonce &+= 1
                // Keep shared FocusState in sync so canvas shortcuts know we're editing.
                focusToken.wrappedValue = layoutNode.id
            }
        }
        .onAppear {
            if isEditing {
                draft = editSeed ?? layoutNode.title
                focusNonce &+= 1
                focusToken.wrappedValue = layoutNode.id
            }
        }
    }

    private var nodeCard: some View {
        Group {
            if isEditing {
                NodeTitleField(
                    text: $draft,
                    placeholder: placeholder,
                    font: .systemFont(
                        ofSize: isRoot ? 16 : 14,
                        weight: isRoot ? .semibold : .medium
                    ),
                    focusNonce: focusNonce,
                    onTextChange: { newValue in
                        // Immediate store sync so Tab/Return/arrows never lose the last keystroke.
                        onDraftChange(newValue)
                        liveWriteTask?.cancel()
                        liveWriteTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(180))
                            guard !Task.isCancelled else { return }
                            onLiveTitle(newValue)
                        }
                    },
                    onCancel: onCancelEdit
                )
                .focused(focusToken, equals: layoutNode.id)
            } else {
                Text(displayTitle)
                    .font(.system(size: isRoot ? 16 : 14, weight: isRoot ? .semibold : .medium))
                    .foregroundStyle(layoutNode.title.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isRoot ? 12 : 10)
        // LayoutEngine sizes frames to fit the full title; don't clip glyphs.
        .frame(width: layoutNode.frame.width, height: layoutNode.frame.height, alignment: .leading)
        .background(backgroundFill)
        .overlay(
            RoundedRectangle(cornerRadius: isRoot ? 14 : 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: isRoot ? 14 : 10, style: .continuous))
        .shadow(
            color: isSelected || isDropTarget
                ? Color.accentColor.opacity(0.22)
                : Color.black.opacity(0.06),
            radius: isSelected || isDropTarget ? 5 : 1.5,
            y: 1
        )
        .contentShape(RoundedRectangle(cornerRadius: isRoot ? 14 : 10, style: .continuous))
        .onTapGesture(count: 2) {
            onSelect()
            onBeginEdit()
        }
        .onTapGesture {
            onSelect()
        }
        .accessibilityLabel(displayTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foldControl: some View {
        Button {
            onToggleExpand()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: layoutNode.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                if !layoutNode.isExpanded {
                    Text("\(layoutNode.childCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(layoutNode.isExpanded ? Color.secondary : Color.accentColor)
            .padding(.horizontal, layoutNode.isExpanded ? 6 : 8)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(layoutNode.isExpanded ? "Fold branch (⌥.)" : "Unfold branch (⌥.)")
        .accessibilityLabel(layoutNode.isExpanded ? "Fold" : "Unfold")
    }

    private var nodeWell: some View {
        Button(action: onAddChild) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .help("Add child idea (Tab)")
        .accessibilityLabel("Add child idea")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Edit Title") { onBeginEdit() }
        Button("Add Child Idea") { onAddChild() }
        if layoutNode.hasChildren {
            Button(layoutNode.isExpanded ? "Fold Branch" : "Unfold Branch") {
                onToggleExpand()
            }
        }
        Divider()
        if !isRoot {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Delete Node Only") { onDeleteSingle() }
        }
    }

    private var backgroundFill: Color {
        if isDropTarget { return Color.accentColor.opacity(0.28) }
        if isSelected { return Color.accentColor.opacity(0.15) }
        if isRoot { return Color.accentColor.opacity(0.08) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if isDropTarget || isSelected { return Color.accentColor }
        return Color(nsColor: .separatorColor)
    }

    private var borderWidth: CGFloat {
        if isDropTarget { return 2.5 }
        if isSelected { return 2 }
        return isRoot ? 1.5 : 1
    }
}

// MARK: - AppKit title field (reliable first-responder after Tab/Return)

/// Plain `NSTextField` that becomes first responder when `focusNonce` changes.
/// SwiftUI `FocusState` alone often fails for fields inserted on the same key event.
private struct NodeTitleField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var focusNonce: Int
    var onTextChange: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 3
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.font = font

        // Avoid fighting the field editor while the user types.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }

        if context.coordinator.lastFocusNonce != focusNonce {
            context.coordinator.lastFocusNonce = focusNonce
            // Defer until after the new node is laid out in the window.
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                // Select all so typing replaces an empty/placeholder title cleanly.
                field.currentEditor()?.selectAll(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let window = field.window else { return }
                if window.firstResponder !== field && window.firstResponder !== field.currentEditor() {
                    window.makeFirstResponder(field)
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NodeTitleField
        var lastFocusNonce: Int = -1

        init(_ parent: NodeTitleField) {
            self.parent = parent
        }

        private func pushText(_ value: String) {
            parent.text = value
            parent.onTextChange(value)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // Immediate store sync so Tab/Return/arrows never lose the last keystroke.
            pushText(field.stringValue)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // Flush text before any structural key is handled by the global monitor.
            pushText(textView.string)

            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            // Return / Tab are owned by MindMapKeyRouter (continuous capture).
            // Swallow newline here so the field does not ding; the monitor creates the next node.
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            {
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:))
                || commandSelector == #selector(NSResponder.insertBacktab(_:))
            {
                return true
            }
            // ↑↓ leave the field — router commits and navigates.
            if commandSelector == #selector(NSResponder.moveUp(_:))
                || commandSelector == #selector(NSResponder.moveDown(_:))
            {
                return true
            }
            return false
        }
    }
}
