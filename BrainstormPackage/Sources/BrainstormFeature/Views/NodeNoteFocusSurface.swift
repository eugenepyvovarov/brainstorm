import AppKit
import SwiftUI

/// A transient foreground workspace for composing one node's note.
///
/// The selected node is matched to its source card on the canvas, while the
/// rest of the map is dimmed and interaction-locked by `ContentView`.
struct NodeNoteFocusSurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var store: BrainstormStore

    let nodeID: UUID
    let namespace: Namespace.ID
    let onDone: () -> Void

    private var node: BrainstormNode? {
        store.node(id: nodeID)
    }

    private var isRoot: Bool {
        nodeID == store.root.id
    }

    var body: some View {
        GeometryReader { proxy in
            if let node {
                let panelSize = panelSize(in: proxy.size)

                VStack(spacing: 0) {
                    panelHeader

                    FocusedNoteNodeHeader(
                        node: node,
                        isRoot: isRoot,
                        maxWidth: min(560, panelSize.width - 48)
                    )
                    .matchedGeometryEffect(
                        id: nodeID,
                        in: namespace,
                        properties: .frame,
                        anchor: .center,
                        isSource: false
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)

                    Divider()
                        .opacity(0.45)

                    NodeNoteEditorView(store: store, nodeID: nodeID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.18))
                }
                .frame(width: panelSize.width, height: panelSize.height)
                .brainstormGlassCard(
                    cornerRadius: 24,
                    interactive: false,
                    tint: store.theme.selectionColor.opacity(0.22)
                )
                .shadow(color: .black.opacity(0.24), radius: 36, y: 18)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Note for \(displayTitle(node))")
                .accessibilityIdentifier("nodeNoteFocusSurface")
                .background(
                    NoteEditorInitialFocusBridge(
                        nodeID: nodeID,
                        delay: reduceMotion ? 0 : 0.28
                    )
                )
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 12) {
            Label("Node note", systemImage: "note.text")
                .font(.headline)

            Text("Write naturally; paste links or images")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            BrainstormGlassGroup(spacing: 10) {
                HStack(spacing: 12) {
                    HStack(spacing: 5) {
                        KeyCap(text: "Esc")
                        Text("close")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        onDone()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .controlSize(.regular)
                    .brainstormGlassButton(prominent: true)
                    .accessibilityHint("Saves this note editing session and returns to the map.")
                    .accessibilityIdentifier("finishNodeNote")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func panelSize(in available: CGSize) -> CGSize {
        CGSize(
            width: min(760, max(320, available.width - 48)),
            height: min(620, max(400, available.height - 48))
        )
    }

    private func displayTitle(_ node: BrainstormNode) -> String {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return isRoot ? BrainstormNode.mainPlaceholder : BrainstormNode.nodePlaceholder
    }
}

/// A slightly enlarged, non-editable copy of the source node that anchors the
/// note editor to the user's current context.
private struct FocusedNoteNodeHeader: View {
    @Environment(\.brainstormTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let node: BrainstormNode
    let isRoot: Bool
    let maxWidth: CGFloat

    private var shape: FocusedNoteNodeShape {
        FocusedNoteNodeShape(kind: node.style.shape, isRoot: isRoot)
    }

    private var title: String {
        let trimmed = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return node.title
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\t", with: " ")
        }
        return isRoot ? BrainstormNode.mainPlaceholder : BrainstormNode.nodePlaceholder
    }

    private var titleFont: Font {
        let baseSize = node.style.fontSize ?? (isRoot ? 16 : 14)
        let weight: Font.Weight = node.style.isBold
            ? .semibold
            : (isRoot ? .semibold : .medium)
        var font = Font.system(size: baseSize + 1, weight: weight)
        if node.style.isItalic {
            font = font.italic()
        }
        return font
    }

    private var preferredWidth: CGFloat {
        let longestLine = title
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count)
            .max() ?? 0
        let mediaAllowance: CGFloat = node.media.isEmpty ? 0 : 36
        let estimated = CGFloat(min(longestLine, 60)) * 8.2 + mediaAllowance + 48
        return min(maxWidth, max(isRoot ? 300 : 240, estimated))
    }

    var body: some View {
        HStack(spacing: node.media.isEmpty ? 0 : 8) {
            media

            Text(title)
                .font(titleFont)
                .foregroundStyle(
                    theme.resolvedTextColor(
                        style: node.style,
                        isRoot: isRoot,
                        isPlaceholder: node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                )
                .lineLimit(LayoutEngine.displayLineLimit)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, isRoot ? 14 : 12)
        .frame(width: preferredWidth)
        .background { nodeBackground }
        .overlay(
            shape.stroke(
                theme.selectionColor.opacity(0.9),
                lineWidth: max(2, CGFloat(node.style.borderWidth ?? 1))
            )
        )
        .shadow(color: theme.selectionColor.opacity(0.32), radius: 15, y: 5)
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityIdentifier("focusedNoteNodeTitle")
    }

    @ViewBuilder
    private var nodeBackground: some View {
        if let hex = theme.resolvedFillHex(style: node.style, isRoot: isRoot),
           let color = Color(hex: hex)
        {
            shape.fill(color)
        } else if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            shape.fill(.regularMaterial)
        }
    }

    @ViewBuilder
    private var media: some View {
        switch node.media.activeKind {
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: 21))
                .frame(width: 28, height: 28)
        case .sticker(let symbol):
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.selectionColor)
                .frame(width: 28, height: 28)
        case .image(let base64):
            if let data = Data(base64Encoded: base64),
               let image = NSImage(data: data)
            {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        case .none:
            EmptyView()
        }
    }
}

private struct FocusedNoteNodeShape: Shape {
    let kind: NodeShape
    let isRoot: Bool

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .roundedRect:
            return RoundedRectangle(
                cornerRadius: isRoot ? BrainstormChrome.rootCorner : BrainstormChrome.nodeCorner,
                style: .continuous
            ).path(in: rect)
        case .capsule:
            return Capsule(style: .continuous).path(in: rect)
        case .rectangle:
            return RoundedRectangle(cornerRadius: 4, style: .continuous).path(in: rect)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }
}

/// Places the caret in the rich note editor after SwiftUI mounts the focus
/// surface. This never steals focus while the surface is closed.
private struct NoteEditorInitialFocusBridge: NSViewRepresentable {
    let nodeID: UUID
    let delay: TimeInterval

    func makeNSView(context: Context) -> NoteEditorFocusHostView {
        let view = NoteEditorFocusHostView(frame: .zero)
        view.requestInitialFocus(for: nodeID, delay: delay)
        return view
    }

    func updateNSView(_ nsView: NoteEditorFocusHostView, context: Context) {
        nsView.requestInitialFocus(for: nodeID, delay: delay)
    }
}

private final class NoteEditorFocusHostView: NSView {
    private var requestedNodeID: UUID?
    private var requestedDelay: TimeInterval = 0
    private var scheduledNodeID: UUID?
    private var focusedNodeID: UUID?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let requestedNodeID else { return }
        requestInitialFocus(for: requestedNodeID, delay: requestedDelay)
    }

    func requestInitialFocus(for nodeID: UUID, delay: TimeInterval) {
        requestedNodeID = nodeID
        requestedDelay = delay
        guard focusedNodeID != nodeID,
              scheduledNodeID != nodeID,
              let window
        else {
            return
        }
        scheduledNodeID = nodeID
        let responderAtRequest = window.firstResponder

        // Let the matched node finish most of its travel before the insertion
        // point appears. If the user deliberately focuses another note field
        // during that interval, preserve their choice.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
            guard let self,
                  self.scheduledNodeID == nodeID,
                  let window,
                  let contentView = window.contentView,
                  let editor = Self.firstEditor(in: contentView)
            else {
                return
            }
            if let currentResponder = window.firstResponder,
               currentResponder !== responderAtRequest,
               currentResponder !== editor,
               currentResponder is NSTextView || currentResponder is NSTextField
            {
                self.focusedNodeID = nodeID
                self.scheduledNodeID = nil
                return
            }
            window.makeFirstResponder(editor)
            self.focusedNodeID = nodeID
            self.scheduledNodeID = nil
        }
    }

    private static func firstEditor(in view: NSView) -> NodeNoteTextView? {
        if let editor = view as? NodeNoteTextView {
            return editor
        }
        for subview in view.subviews {
            if let editor = firstEditor(in: subview) {
                return editor
            }
        }
        return nil
    }
}
