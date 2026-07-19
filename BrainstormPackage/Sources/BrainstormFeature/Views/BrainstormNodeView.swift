import AppKit
import SwiftUI

struct BrainstormNodeView: View {
    // MARK: - Environment
    @Environment(\.brainstormTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Inputs
    let layoutNode: LayoutNode
    let isRoot: Bool
    let isSelected: Bool
    let isEditing: Bool
    let isDropTarget: Bool
    let isSearchMatch: Bool
    let isDimmed: Bool
    let isFreeDragging: Bool
    /// Static export rendering hides editor-only controls and glass effects.
    let isExporting: Bool
    /// Whether this node owns non-empty note content.
    let hasNote: Bool
    /// Whether hover/selection may reveal the transient Note action.
    let showNoteAction: Bool
    /// Whether a compact note-presence marker is shown on the map.
    let showNoteIndicator: Bool
    let editSeed: String?
    /// When beginning an edit without a seed: select all (replace) vs caret at end.
    let editSelectAll: Bool
    /// Shared only by the interactive canvas note transition. Static exports
    /// pass `nil` and render the card without geometry matching.
    let noteFocusNamespace: Namespace.ID?
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
    /// ⌫ on an empty title while editing — delete node and select previous.
    let onDeleteEmptyWhileEditing: () -> Void
    /// Free-position drag in canvas viewport points (`brainstormCanvas` space).
    let onFreeDragChanged: (_ translation: CGSize, _ location: CGPoint) -> Void
    let onFreeDragEnded: (_ translation: CGSize, _ location: CGPoint) -> Void
    let onResetPosition: () -> Void
    /// Opens the node-centered note composition surface.
    let onOpenNote: () -> Void

    // MARK: - State
    @State private var draft: String = ""
    @State private var isHovered = false
    @State private var focusNonce: Int = 0
    /// When true, focusing the title field selects all (⌘↩ rename). When false, caret at end (type-to-edit seed).
    @State private var selectAllOnFocus = true
    /// True once this gesture started as a free-drag.
    @State private var freeDragActive = false

    // MARK: - Derived

    private var showNodeWell: Bool {
        // Dimmed (out-of-focus) nodes stay fully usable — well still appears on hover/select.
        !isExporting && !isEditing && (isSelected || isHovered)
    }

    private var showNotePill: Bool {
        // The note action remains available while the selected node title is
        // being edited; opening it commits the title through the existing
        // canvas callback before entering the centered note workspace.
        !isExporting && showNoteAction && (isSelected || isHovered)
    }

    private var displayTitle: String {
        if layoutNode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isRoot ? BrainstormNode.mainPlaceholder : BrainstormNode.nodePlaceholder
        }
        return Self.normalizedLineBreaks(layoutNode.title)
    }

    /// Keep intentional line breaks while normalizing platform newlines and tabs.
    /// Automatic visual wrapping is never written back into the document.
    fileprivate static func normalizedLineBreaks(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private var placeholder: String {
        isRoot ? BrainstormNode.mainPlaceholder : BrainstormNode.nodePlaceholder
    }

    private var titleFont: Font {
        // Keep design/weight identical for every non-root node so selection,
        // media, or fill color never reads as a different typeface.
        let size = layoutNode.style.fontSize ?? (isRoot ? 16 : 14)
        let weight: Font.Weight = layoutNode.style.isBold ? .semibold : (isRoot ? .semibold : .medium)
        var f = Font.system(size: size, weight: weight, design: .default)
        if layoutNode.style.isItalic { f = f.italic() }
        return f
    }

    private var nsTitleFont: NSFont {
        LayoutEngine().font(for: layoutNode.style, isRoot: isRoot)
    }

    private var cornerRadius: CGFloat {
        switch layoutNode.style.shape {
        case .roundedRect: return isRoot ? BrainstormChrome.rootCorner : BrainstormChrome.nodeCorner
        case .capsule: return 999
        case .rectangle: return 4
        case .diamond: return 0
        }
    }

    // MARK: - Body

    var body: some View {
        // Layout size = card only so selection / + well never shifts siblings horizontally.
        matchedNodeCard
            .overlay(alignment: .trailing) {
                HStack(spacing: 6) {
                    if layoutNode.hasChildren && !isEditing && !isExporting {
                        foldControl
                    }
                    if showNodeWell {
                        nodeWell
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.leading, 6)
                .fixedSize()
                // Place accessories just past the card’s trailing edge.
                .alignmentGuide(.trailing) { $0[.leading] }
            }
            .overlay(alignment: .bottom) {
                if showNotePill {
                    notePill
                        .offset(y: 16)
                        .zIndex(4)
                }
            }
            .overlay {
                if !isExporting && showNoteIndicator {
                    GeometryReader { proxy in
                        noteIndicator
                            .position(
                                noteIndicatorPosition(in: proxy.size)
                            )
                    }
                    .allowsHitTesting(false)
                    .zIndex(5)
                }
            }
            // Soften out-of-focus nodes but keep them readable enough to aim at.
            .opacity(isDimmed ? 0.38 : 1)
            .animation(.easeOut(duration: 0.12), value: showNodeWell)
            .animation(.easeOut(duration: 0.12), value: showNotePill)
            .animation(.easeOut(duration: 0.18), value: isDimmed)
            .onHover { isHovered = $0 }
            .contextMenu { contextMenuItems }
            .onChange(of: isEditing) { _, editing in
                if editing {
                    prepareEditingSession()
                }
            }
            .onAppear {
                if isEditing {
                    prepareEditingSession()
                }
            }
    }

    // MARK: - Node card

    @ViewBuilder
    private var matchedNodeCard: some View {
        if let noteFocusNamespace {
            nodeCard
                .matchedGeometryEffect(
                    id: layoutNode.id,
                    in: noteFocusNamespace,
                    properties: .frame,
                    anchor: .center,
                    isSource: true
                )
        } else {
            nodeCard
        }
    }

    private var nodeCard: some View {
        cardInterior
            .padding(.horizontal, 16)
            .padding(.vertical, isRoot ? 12 : 10)
            .frame(width: layoutNode.frame.width, height: layoutNode.frame.height, alignment: .leading)
            .modifier(NodeChromeModifier(
                shape: nodeShape,
                cornerRadius: cornerRadius,
                supportsRectangularGlass: layoutNode.style.shape != .diamond,
                fillHex: resolvedFillHex,
                isExporting: isExporting,
                isSelected: isSelected,
                isDropTarget: isDropTarget,
                isSearchMatch: isSearchMatch,
                isRoot: isRoot,
                borderColor: borderColor,
                borderWidth: borderWidth,
                theme: theme,
                searchHighlight: theme.searchHighlightColor,
                selectionColor: theme.selectionColor
            ))
            .shadow(
                color: shadowColor,
                radius: isSelected || isDropTarget || isFreeDragging ? 10 : 3,
                y: isSelected ? 3 : 1
            )
            .scaleEffect(isFreeDragging ? 1.03 : 1)
            .contentShape(nodeShape)
            // Free-position is the primary drag. Dropping directly onto a node
            // requests a confirmed reparent (handled in the canvas).
            // System `.draggable` is intentionally not used — it stole gestures from free move.
            .gesture(freePositionGesture)
            .onTapGesture(count: 2) {
                onSelect()
                onBeginEdit()
            }
            .onTapGesture { onSelect() }
            .accessibilityLabel(displayTitle)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardInterior: some View {
        // Same outer padding whether or not media is present; layout reserves
        // horizontal room for media so the title is not ellipsized.
        HStack(alignment: .center, spacing: layoutNode.media.isEmpty ? 0 : 6) {
            mediaView
            titleContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        if isEditing {
            NodeTitleField(
                text: $draft,
                placeholder: placeholder,
                font: nsTitleFont,
                focusNonce: focusNonce,
                selectAllOnFocus: selectAllOnFocus,
                onTextChange: { newValue in
                    let normalized = Self.normalizedLineBreaks(newValue)
                    if normalized != newValue {
                        draft = normalized
                    }
                    onDraftChange(normalized)
                    // Apply immediately so tree title stays in sync; layout already
                    // sizes from editingDraft, but commit/navigation still need the tree.
                    onLiveTitle(normalized)
                },
                onCancel: onCancelEdit,
                onBackspaceWhenEmpty: onDeleteEmptyWhileEditing
            )
            .focused(focusToken, equals: layoutNode.id)
        } else {
            Text(displayTitle)
                .font(titleFont)
                .fontWeight(layoutNode.style.isBold ? .semibold : (isRoot ? .semibold : .medium))
                .foregroundStyle(textColor)
                .lineLimit(LayoutEngine.displayLineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                // Avoid environment/minimum-scale inheritance changing apparent weight.
                .minimumScaleFactor(1)
                .allowsTightening(false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Display box for the single media decoration (matches LayoutEngine.mediaSlot).
    private var mediaFrame: CGFloat { isRoot ? 22 : 20 }

    @ViewBuilder
    private var mediaView: some View {
        // At most one of emoji | sticker | image.
        switch layoutNode.media.activeKind {
        case .emoji(let emoji):
            // Emoji glyphs need room beyond the font size; avoid tight frames that clip.
            Text(emoji)
                .font(.system(size: mediaFrame - 4))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
                .frame(width: mediaFrame, height: mediaFrame, alignment: .center)
                .accessibilityLabel("Emoji \(emoji)")
        case .sticker(let symbol):
            Image(systemName: symbol)
                .font(.system(size: mediaFrame - 6, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: mediaFrame, height: mediaFrame, alignment: .center)
                .accessibilityLabel("Icon \(symbol)")
        case .image(let b64):
            if let data = Data(base64Encoded: b64), let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: mediaFrame, height: mediaFrame)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityLabel("Image")
            }
        case .none:
            EmptyView()
        }
    }

    /// Seeded type-to-edit keeps the first keystroke and puts the caret after it.
    /// Plain begin-edit: select-all for rename, or caret at end to extend the title.
    private func prepareEditingSession() {
        if let seed = editSeed, !seed.isEmpty {
            draft = seed
            selectAllOnFocus = false
        } else {
            draft = layoutNode.title
            selectAllOnFocus = editSelectAll
        }
        focusNonce &+= 1
        focusToken.wrappedValue = layoutNode.id
    }

    // MARK: - Free position gesture

    private var freePositionGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("brainstormCanvas"))
            .onChanged { value in
                if !freeDragActive {
                    // Don't free-drag while editing a title.
                    guard !isEditing else { return }
                    freeDragActive = true
                    onSelect()
                }
                onFreeDragChanged(value.translation, value.location)
            }
            .onEnded { value in
                if freeDragActive {
                    onFreeDragEnded(value.translation, value.location)
                }
                freeDragActive = false
            }
    }

    // MARK: - Controls

    private var foldControl: some View {
        let accent = theme.selectionColor
        let collapsed = !layoutNode.isExpanded
        return Button(action: onToggleExpand) {
            HStack(spacing: 3) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(collapsed ? accent : Color.secondary)
                if collapsed {
                    Text("\(layoutNode.childCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, collapsed ? 10 : 8)
            .frame(height: 26)
        }
        .buttonStyle(.plain)
        .brainstormGlassCapsule(interactive: true, tint: collapsed ? accent : nil)
    }

    private var nodeWell: some View {
        let accent = theme.selectionColor
        return Button(action: onAddChild) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(accent.gradient))
                .shadow(color: accent.opacity(0.4), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var notePill: some View {
        Button(action: onOpenNote) {
            Label(
                hasNote ? "Note" : "+ Note",
                systemImage: hasNote ? "note.text" : "note.text.badge.plus"
            )
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 22)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .brainstormGlassCapsule(
            interactive: true,
            tint: hasNote ? theme.selectionColor.opacity(0.85) : nil
        )
        .accessibilityLabel(
            hasNote
                ? "Edit note for \(displayTitle)"
                : "Add note to \(displayTitle)"
        )
        .accessibilityHint("Opens a centered note editor without creating another node.")
        .accessibilityIdentifier("nodeNotePill-\(layoutNode.id.uuidString)")
    }

    private var noteIndicator: some View {
        Image(systemName: "note.text")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(
                theme.selectionColor.opacity(colorScheme == .dark ? 0.45 : 0.36)
            )
            .frame(width: 14, height: 14)
            .allowsHitTesting(false)
            .accessibilityLabel("Note present for \(displayTitle)")
            .accessibilityIdentifier("nodeNoteIndicator-\(layoutNode.id.uuidString)")
    }

    private func noteIndicatorPosition(in size: CGSize) -> CGPoint {
        if layoutNode.style.shape == .diamond {
            // A bounding-box corner sits outside a diamond. Keep the passive
            // marker in its upper-right interior quadrant instead.
            return CGPoint(x: size.width * 0.66, y: size.height * 0.30)
        }
        return CGPoint(
            x: max(7, size.width - 13),
            y: min(max(7, size.height - 7), 12)
        )
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Edit Title") { onBeginEdit() }
        Button(hasNote ? "Open Note" : "Add Note") { onOpenNote() }
        Button("Add Child Idea") { onAddChild() }
        if layoutNode.hasChildren {
            Button(layoutNode.isExpanded ? "Fold Branch" : "Unfold Branch") {
                onToggleExpand()
            }
        }
        if layoutNode.hasManualPosition {
            Button("Reset Position") { onResetPosition() }
        }
        Divider()
        if !isRoot {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Delete Node Only") { onDeleteSingle() }
        }
    }

    // MARK: - Appearance

    private var nodeShape: AnyShape {
        switch layoutNode.style.shape {
        case .roundedRect:
            return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .capsule:
            return AnyShape(Capsule(style: .continuous))
        case .rectangle:
            return AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .diamond:
            return AnyShape(DiamondShape())
        }
    }

    /// Custom fill override, else theme default for root/child.
    private var resolvedFillHex: String? {
        theme.resolvedFillHex(style: layoutNode.style, isRoot: isRoot)
    }

    private var textColor: Color {
        let isPlaceholder = layoutNode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return theme.resolvedTextColor(
            style: layoutNode.style,
            isRoot: isRoot,
            isPlaceholder: isPlaceholder
        )
    }

    /// System theme tracks macOS light/dark; fixed palettes use their catalog flag.
    private var paintsAsDark: Bool {
        theme.resolvesAsDark(in: colorScheme)
    }

    private var borderColor: Color {
        if isDropTarget || isSelected { return theme.selectionColor }
        if isSearchMatch { return Color.orange }
        if isFreeDragging { return theme.selectionColor.opacity(0.8) }
        if let hex = layoutNode.style.borderHex, let custom = Color(hex: hex) {
            return custom
        }
        return Color.primary.opacity(paintsAsDark ? 0.18 : 0.1)
    }

    private var borderWidth: CGFloat {
        let styledWidth = CGFloat(layoutNode.style.borderWidth ?? (isRoot ? 1.5 : 1))
        if isDropTarget || isFreeDragging { return 2.5 }
        if isSelected { return max(2, styledWidth) }
        if isSearchMatch { return 1.5 }
        return styledWidth
    }

    private var shadowColor: Color {
        if isSelected || isDropTarget || isFreeDragging {
            return theme.selectionColor.opacity(0.35)
        }
        return Color.black.opacity(paintsAsDark ? 0.45 : 0.08)
    }
}

// MARK: - Node chrome (glass or solid fill)

private struct NodeChromeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let shape: AnyShape
    let cornerRadius: CGFloat
    let supportsRectangularGlass: Bool
    let fillHex: String?
    let isExporting: Bool
    let isSelected: Bool
    let isDropTarget: Bool
    let isSearchMatch: Bool
    let isRoot: Bool
    let borderColor: Color
    let borderWidth: CGFloat
    let theme: AppTheme
    let searchHighlight: Color
    let selectionColor: Color

    func body(content: Content) -> some View {
        if let hex = fillHex, let c = Color(hex: hex) {
            // Fully opaque fill — translucent fills let the canvas show through glyph
            // edges so unselected text looks thinner/softer than selected text.
            content
                .background(c, in: shape)
                .overlay(shape.stroke(borderColor, lineWidth: borderWidth))
        } else if isExporting {
            // Offscreen/PDF rendering has no backing window for Liquid Glass.
            content
                .background(fallbackFill, in: shape)
                .overlay(shape.stroke(borderColor, lineWidth: borderWidth))
        } else if reduceTransparency {
            content
                .background {
                    ZStack {
                        shape.fill(Color(nsColor: .controlBackgroundColor))
                        shape.fill(fallbackFill)
                    }
                }
                .overlay(shape.stroke(borderColor, lineWidth: borderWidth))
        } else if !reduceTransparency,
                  theme.isSystem,
                  supportsRectangularGlass,
                  #available(macOS 26.0, *)
        {
            content
                .glassEffect(glassStyle, in: .rect(cornerRadius: cornerRadius))
                .overlay(shape.stroke(borderColor, lineWidth: borderWidth))
        } else {
            content
                .background(fallbackFill, in: shape)
                .overlay(shape.stroke(borderColor, lineWidth: borderWidth))
        }
    }

    @available(macOS 26.0, *)
    private var glassStyle: Glass {
        if isDropTarget { return .regular.tint(selectionColor.opacity(0.45)).interactive() }
        if isSelected { return .regular.tint(selectionColor.opacity(0.3)).interactive() }
        if isSearchMatch { return .regular.tint(searchHighlight.opacity(0.55)).interactive() }
        if isRoot { return .regular.tint(selectionColor.opacity(0.12)).interactive() }
        return .regular.interactive()
    }

    private var fallbackFill: Color {
        if isDropTarget { return selectionColor.opacity(0.28) }
        if isSearchMatch && !isSelected { return searchHighlight.opacity(0.55) }
        if isSelected { return selectionColor.opacity(0.18) }
        if isRoot { return selectionColor.opacity(0.12) }
        return Color(nsColor: .controlBackgroundColor)
    }
}

// MARK: - Shapes

private struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

private struct AnyShape: Shape {
    private let builder: @Sendable (CGRect) -> Path
    init<S: Shape>(_ shape: S) {
        builder = { rect in shape.path(in: rect) }
    }
    func path(in rect: CGRect) -> Path { builder(rect) }
}

// MARK: - Color hex

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let a = hasAlpha ? Double((value >> 24) & 0xFF) / 255 : 1
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - AppKit multiline title editor

/// Title editor with explicit Shift-Return line breaks and up to three visible lines.
private struct NodeTitleField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var focusNonce: Int
    /// `true` = select all on focus (replace mode). `false` = caret at end (type-to-edit seed).
    var selectAllOnFocus: Bool
    var onTextChange: (String) -> Void
    var onCancel: () -> Void
    /// ⌫ on an empty title — delete the node (handled by the store).
    var onBackspaceWhenEmpty: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Keep font + typing attributes locked so typed text never drifts weight/size.
    private func applyFont(_ font: NSFont, to view: NodeTitleTextView) {
        let fontChanged = view.font != font
        view.font = font
        view.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        // Only rewrite storage when the face actually changes — not on every keystroke.
        if fontChanged, let storage = view.textStorage, storage.length > 0 {
            storage.addAttributes(
                [.font: font],
                range: NSRange(location: 0, length: storage.length)
            )
        }
    }

    func makeNSView(context: Context) -> NodeTitleTextView {
        let view = NodeTitleTextView()
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.isRichText = false
        view.allowsUndo = true
        view.isEditable = true
        view.isSelectable = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.focusRingType = .none
        applyFont(font, to: view)
        view.string = text
        view.delegate = context.coordinator
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.maximumNumberOfLines = LayoutEngine.displayLineLimit
        view.textContainer?.lineBreakMode = .byWordWrapping
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: font.boundingRectForFont.height * CGFloat(LayoutEngine.displayLineLimit) + 4
        )
        view.minSize = .zero
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.insertionPointColor = NSColor.controlAccentColor
        context.coordinator.textView = view
        return view
    }

    func updateNSView(_ view: NodeTitleTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView = view
        applyFont(font, to: view)
        view.placeholderString = placeholder
        view.textContainer?.maximumNumberOfLines = LayoutEngine.displayLineLimit
        view.textContainer?.lineBreakMode = .byWordWrapping

        let focusing = context.coordinator.lastFocusNonce != focusNonce
        // Don't clobber in-progress typing; always sync when (re)focusing.
        if focusing || view.window?.firstResponder !== view {
            if view.string != text {
                view.string = text
            }
        }
        if focusing {
            context.coordinator.lastFocusNonce = focusNonce
            let selectAll = selectAllOnFocus
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                if view.string != self.text {
                    view.string = self.text
                }
                window.makeFirstResponder(view)
                if selectAll {
                    view.selectAll(nil)
                } else {
                    let end = (view.string as NSString).length
                    view.setSelectedRange(NSRange(location: end, length: 0))
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NodeTitleField
        var lastFocusNonce: Int = -1
        weak var textView: NodeTitleTextView?

        init(_ parent: NodeTitleField) { self.parent = parent }

        private func pushText(_ value: String) {
            let normalized = BrainstormNodeView.normalizedLineBreaks(value)
            parent.text = normalized
            parent.onTextChange(normalized)
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let normalized = BrainstormNodeView.normalizedLineBreaks(view.string)
            if view.string != normalized {
                let selected = view.selectedRange()
                view.string = normalized
                let end = (normalized as NSString).length
                let loc = min(selected.location, end)
                view.setSelectedRange(NSRange(location: loc, length: 0))
            }
            pushText(normalized)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }

            // Plain Return is owned by the key monitor (new sibling). Shift-Return
            // reaches the editor and inserts a real newline at the current caret.
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            {
                let flags = NSApp.currentEvent?.modifierFlags
                    .intersection(.deviceIndependentFlagsMask) ?? []
                if flags.contains(.shift) { return false }
                return true
            }

            // Tab / arrows are owned by mind-map navigation (key monitor).
            if commandSelector == #selector(NSResponder.insertTab(_:))
                || commandSelector == #selector(NSResponder.insertBacktab(_:))
            {
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:))
                || commandSelector == #selector(NSResponder.moveDown(_:))
            {
                return true
            }

            // Empty field + ⌫ → delete node and jump to previous (outliner behavior).
            if commandSelector == #selector(NSResponder.deleteBackward(_:))
                || commandSelector == #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:))
            {
                let empty = textView.string
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                if empty {
                    parent.onBackspaceWhenEmpty()
                    return true
                }
            }
            return false
        }
    }
}

/// `NSTextView` with a simple placeholder and multiline intrinsic height.
private final class NodeTitleTextView: NSTextView {
    var placeholderString: String = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let rect = bounds.insetBy(dx: 0, dy: 0)
        (placeholderString as NSString).draw(in: rect, withAttributes: attrs)
    }

    override var intrinsicContentSize: NSSize {
        let lineH = font?.boundingRectForFont.height ?? 16
        let explicitLines = max(
            1,
            string.components(separatedBy: "\n").count
        )
        let visibleLines = min(LayoutEngine.displayLineLimit, explicitLines)
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: lineH * CGFloat(visibleLines)
        )
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}
