import AppKit
import CoreGraphics
import Foundation

public struct LayoutNode: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let frame: CGRect
    public let isExpanded: Bool
    public let hasChildren: Bool
    public let childCount: Int
    public let depth: Int
    public let style: NodeStyle
    public let media: NodeMedia
    /// Whether the source node owns non-empty note content, regardless of
    /// whether the current layout includes the note card itself.
    public let hasNote: Bool
    /// Note payload selected by the current layout policy.
    public let note: NodeNote?
    /// Static note-card frame below the node card. Branch endpoints still use `frame`.
    public let noteFrame: CGRect?
    public let hasManualPosition: Bool
    /// Edge color for links *from this node* to children (may be nil → default).
    public let branchHex: String?
}

public struct LayoutEdge: Equatable, Sendable, Identifiable {
    public var id: String { "\(fromID.uuidString)-\(toID.uuidString)" }
    public let fromID: UUID
    public let toID: UUID
    public let from: CGPoint
    public let to: CGPoint
    public let colorHex: String?
}

public struct LayoutResult: Equatable, Sendable {
    public let nodes: [LayoutNode]
    public let edges: [LayoutEdge]
    public let contentSize: CGSize

    public static let empty = LayoutResult(nodes: [], edges: [], contentSize: .zero)
}

/// Controls whether placement emits only the currently unfolded map or the
/// complete stored hierarchy.
///
/// ``expandedOnly`` measures and places only the unfolded map, so collapsing a
/// branch compacts the visible canvas. ``allDescendants`` measures and emits the
/// complete stored hierarchy, including manual offsets. This gives presentation
/// mode the exact geometry of the fully expanded map without mutating the
/// document's saved expansion state.
public enum LayoutPlacementPolicy: Equatable, Sendable {
    case expandedOnly
    case allDescendants
}

public struct LayoutEngine: Sendable {
    /// Matches BrainstormNodeView horizontal padding.
    public var horizontalPadding: CGFloat = 16
    /// Child node vertical padding (root uses `rootVerticalPadding`).
    public var verticalPadding: CGFloat = 10
    public var rootVerticalPadding: CGFloat = 12
    public var minNodeWidth: CGFloat = 100
    /// About 50 characters at the default node font before word wrapping.
    public var maxNodeWidth: CGFloat = 420
    /// Displayed titles wrap before they truncate. Keep this in sync with BrainstormNodeView.
    public static let displayLineLimit = 3
    public var levelGap: CGFloat = 80
    public var siblingSpacing: CGFloat = 16
    public var canvasPadding: CGFloat = 48
    /// Room past the card for fold chevron / + well so they aren’t clipped.
    public var accessoryPadding: CGFloat = 56
    /// Extra width so kerning / antialiasing never clips the last glyph.
    public var textWidthFudge: CGFloat = 10
    /// Room for the caret while a title is being edited (avoids mid-type "…").
    public var editingCaretPad: CGFloat = 16
    /// Display box for the single media decoration (matches BrainstormNodeView.mediaFrame root).
    public var mediaSlot: CGFloat = 22
    /// Gap between media and title (matches BrainstormNodeView HStack spacing).
    public var mediaSpacing: CGFloat = 6
    /// Vertical gap between a node card and its optional note card.
    public var noteSpacing: CGFloat = 8
    /// Notes stay readable even when their node title is only a few characters.
    public var minNoteWidth: CGFloat = 300
    /// Keep note cards aligned with the normal maximum node-card width.
    public var maxNoteWidth: CGFloat = 420
    public init() {}

    /// Optional live title while editing — layout uses the draft immediately so the
    /// card grows with each keystroke (not after a debounce on the tree title).
    public struct LiveTitleOverride: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public init(id: UUID, title: String) {
            self.id = id
            self.title = title
        }
    }

    public func layout(
        root: BrainstormNode,
        liveTitle: LiveTitleOverride? = nil,
        noteInclusion: BrainstormNoteInclusion = .none,
        placementPolicy: LayoutPlacementPolicy = .expandedOnly
    ) -> LayoutResult {
        let metrics = measure(
            root,
            isRoot: true,
            liveTitle: liveTitle,
            noteInclusion: noteInclusion,
            placementPolicy: placementPolicy
        )
        var nodes: [LayoutNode] = []
        var edges: [LayoutEdge] = []

        let originX = canvasPadding
        let originCenterY = canvasPadding + metrics.subtreeHeight / 2
        place(
            root,
            metrics: metrics,
            originX: originX,
            centerY: originCenterY,
            depth: 0,
            placementPolicy: placementPolicy,
            nodes: &nodes,
            edges: &edges
        )

        // Manual free-position offsets can push frames into negative space. EdgeCanvas
        // (and other bounded layers) clip at (0,0), while `.position`’d nodes still paint
        // outside — so lines vanish in a region even though nodes remain visible.
        // Shift everything so the content origin stays non-negative with padding.
        let minX = nodes.map(\.frame.minX).min() ?? 0
        let minY = nodes.map(\.frame.minY).min() ?? 0
        let shiftX = minX < canvasPadding ? (canvasPadding - minX) : 0
        let shiftY = minY < canvasPadding ? (canvasPadding - minY) : 0
        if shiftX != 0 || shiftY != 0 {
            nodes = nodes.map { node in
                LayoutNode(
                    id: node.id,
                    title: node.title,
                    frame: node.frame.offsetBy(dx: shiftX, dy: shiftY).integral,
                    isExpanded: node.isExpanded,
                    hasChildren: node.hasChildren,
                    childCount: node.childCount,
                    depth: node.depth,
                    style: node.style,
                    media: node.media,
                    hasNote: node.hasNote,
                    note: node.note,
                    noteFrame: node.noteFrame?.offsetBy(dx: shiftX, dy: shiftY).integral,
                    hasManualPosition: node.hasManualPosition,
                    branchHex: node.branchHex
                )
            }
            edges = edges.map { edge in
                LayoutEdge(
                    fromID: edge.fromID,
                    toID: edge.toID,
                    from: CGPoint(x: (edge.from.x + shiftX).rounded(), y: (edge.from.y + shiftY).rounded()),
                    to: CGPoint(x: (edge.to.x + shiftX).rounded(), y: (edge.to.y + shiftY).rounded()),
                    colorHex: edge.colorHex
                )
            }
        }

        let maxX = nodes.map { max($0.frame.maxX, $0.noteFrame?.maxX ?? 0) }.max() ?? 0
        let maxY = nodes.map { max($0.frame.maxY, $0.noteFrame?.maxY ?? 0) }.max() ?? 0
        // Include edge endpoints (should already lie on node frames) and accessory gutter.
        let edgeMaxX = edges.map { max($0.from.x, $0.to.x) }.max() ?? 0
        let edgeMaxY = edges.map { max($0.from.y, $0.to.y) }.max() ?? 0
        let contentSize = CGSize(
            width: max(max(maxX, edgeMaxX) + canvasPadding + accessoryPadding, canvasPadding * 2),
            height: max(max(maxY, edgeMaxY) + canvasPadding + accessoryPadding, canvasPadding * 2)
        )
        return LayoutResult(nodes: nodes, edges: edges, contentSize: contentSize)
    }

    // MARK: - Measure

    private struct SubtreeMetrics {
        var nodeSize: CGSize
        var noteSize: CGSize?
        var subtreeHeight: CGFloat
        var children: [SubtreeMetrics]

        var clusterHeight: CGFloat {
            nodeSize.height + (noteSize?.height ?? 0)
        }
    }

    /// Measure only visible descendants for the normal map. Presentation asks
    /// for `.allDescendants`, which preserves fully expanded map geometry.
    private func measure(
        _ node: BrainstormNode,
        isRoot: Bool,
        liveTitle: LiveTitleOverride?,
        noteInclusion: BrainstormNoteInclusion,
        placementPolicy: LayoutPlacementPolicy
    ) -> SubtreeMetrics {
        let isEditing = liveTitle?.id == node.id
        let title = isEditing ? (liveTitle?.title ?? node.title) : node.title
        let nodeSize = sizeForNode(node, title: title, isRoot: isRoot, isEditing: isEditing)
        let includedNote = node.note.flatMap {
            noteInclusion.includes($0) ? $0 : nil
        }
        let measuredNoteSize = includedNote.map {
            let noteWidth = min(
                maxNoteWidth,
                max(minNoteWidth, nodeSize.width)
            )
            return CGSize(
                width: noteWidth,
                height: NodeNoteRendering.measuredHeight(
                    note: $0,
                    width: noteWidth,
                    mode: .canvas
                ) + noteSpacing
            )
        }
        let clusterHeight = nodeSize.height + (measuredNoteSize?.height ?? 0)
        guard !node.children.isEmpty,
              node.isExpanded || placementPolicy == .allDescendants
        else {
            return SubtreeMetrics(
                nodeSize: nodeSize,
                noteSize: measuredNoteSize,
                subtreeHeight: clusterHeight,
                children: []
            )
        }

        let childMetrics = node.children.map {
            measure(
                $0,
                isRoot: false,
                liveTitle: liveTitle,
                noteInclusion: noteInclusion,
                placementPolicy: placementPolicy
            )
        }
        let spacing = CGFloat(max(0, childMetrics.count - 1)) * siblingSpacing
        let childrenHeight = childMetrics.reduce(0) { $0 + $1.subtreeHeight } + spacing
        return SubtreeMetrics(
            nodeSize: nodeSize,
            noteSize: measuredNoteSize,
            subtreeHeight: max(clusterHeight, childrenHeight),
            children: childMetrics
        )
    }

    private func sizeForNode(
        _ node: BrainstormNode,
        title: String,
        isRoot: Bool,
        isEditing: Bool
    ) -> CGSize {
        // Title gets its full measured width; media adds horizontal room so the
        // icon never steals title space (which caused "Brainstorm…" truncation).
        // Height and outer padding stay the same with or without media.
        let titleSize = sizeForTitle(
            title,
            isRoot: isRoot,
            style: node.style,
            isEditing: isEditing
        )
        let mediaW = mediaExtraWidth(for: node.media, isRoot: isRoot)
        let vPad = isRoot ? rootVerticalPadding : verticalPadding
        let caret = isEditing ? editingCaretPad : 0

        var width = titleSize.width + mediaW + horizontalPadding * 2 + caret
        var height = titleSize.height + vPad * 2

        // Diamond needs a bit more room so text fits inside.
        if node.style.shape == .diamond {
            width *= 1.15
            height *= 1.2
        }

        return CGSize(width: width, height: height)
    }

    /// Horizontal space for the single media decoration (emoji | sticker | image).
    /// Matches BrainstormNodeView: one `mediaFrame` box + spacing before the title.
    private func mediaExtraWidth(for media: NodeMedia, isRoot: Bool) -> CGFloat {
        guard media.activeKind != nil else { return 0 }
        let frame = isRoot ? mediaSlot : max(16, mediaSlot - 2)
        return frame + mediaSpacing
    }

    /// Measure with the same fonts and line limit used by the node view.
    /// Titles preserve manual newlines and wrap to three visible lines. The live editor
    /// may temporarily grow wider so its caret remains visible while typing.
    private func sizeForTitle(
        _ title: String,
        isRoot: Bool,
        style: NodeStyle,
        isEditing: Bool = false
    ) -> CGSize {
        let text: String
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = isRoot ? BrainstormNode.mainPlaceholder : BrainstormNode.nodePlaceholder
        } else {
            // Normalize line endings and tabs; preserve intentional newlines.
            text = title
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\t", with: " ")
        }

        let font = font(for: style, isRoot: isRoot)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        // While editing, allow the card to grow past the normal max so the caret
        // and full draft stay visible (no mid-type "…").
        let maxCap = isEditing ? maxNodeWidth * 2 : maxNodeWidth
        let maxTextWidth = maxCap - horizontalPadding * 2
        let minTextWidth = minNodeWidth - horizontalPadding * 2

        // `NSString.size` ignores trailing whitespace width — measure with a
        // sentinel glyph and subtract so "Open " still widens while typing.
        let measuredWidth = measuredTextWidth(text, attributes: attributes)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let contentWidth = min(
            maxTextWidth,
            max(minTextWidth, ceil(measuredWidth) + textWidthFudge)
        )
        let contentHeight: CGFloat
        if !text.contains("\n"), measuredWidth + textWidthFudge <= maxTextWidth {
            contentHeight = lineHeight
        } else {
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            contentHeight = min(
                ceil(bounds.height),
                lineHeight * CGFloat(Self.displayLineLimit)
            )
        }

        return CGSize(width: contentWidth, height: contentHeight)
    }

    /// Text width that includes trailing spaces (unlike plain `NSString.size`).
    private func measuredTextWidth(_ text: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        text.components(separatedBy: "\n")
            .map { measuredLineWidth($0, attributes: attributes) }
            .max() ?? 0
    }

    private func measuredLineWidth(_ text: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        let sentinel = "\u{2060}." // word-joiner + visible mark
        let full = ((text + sentinel) as NSString).size(withAttributes: attributes).width
        let mark = (sentinel as NSString).size(withAttributes: attributes).width
        return max(0, full - mark)
    }

    public func font(for style: NodeStyle, isRoot: Bool) -> NSFont {
        // Match BrainstormNodeView.titleFont: bold → semibold (not heavy .bold) so edit
        // and display weights stay consistent across selected / unselected nodes.
        let size = CGFloat(style.fontSize ?? (isRoot ? 16 : 14))
        var weight: NSFont.Weight = isRoot ? .semibold : .medium
        if style.isBold { weight = .semibold }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if style.isItalic {
            let traits: NSFontTraitMask = style.isBold ? [.boldFontMask, .italicFontMask] : .italicFontMask
            return NSFontManager.shared.convert(base, toHaveTrait: traits)
        }
        return base
    }

    // MARK: - Place

    /// Places `node` and returns its frame (O(1) for edge endpoints — no scan of `nodes`).
    @discardableResult
    private func place(
        _ node: BrainstormNode,
        metrics: SubtreeMetrics,
        originX: CGFloat,
        centerY: CGFloat,
        depth: Int,
        placementPolicy: LayoutPlacementPolicy,
        nodes: inout [LayoutNode],
        edges: inout [LayoutEdge]
    ) -> CGRect {
        let ox = CGFloat(node.offsetX ?? 0)
        // A branch is commonly positioned while its complete subtree is
        // visible. Reusing that expanded-layout vertical displacement after
        // folding would leave the exact empty space the fold is meant to
        // remove. Auto-pack the folded card vertically in the normal map while
        // retaining the saved offset for re-expansion and all-descendant
        // presentation/export geometry.
        let compactsFoldedBranchOffset =
            placementPolicy == .expandedOnly
            && node.hasChildren
            && !node.isExpanded
        let oy = compactsFoldedBranchOffset
            ? 0
            : CGFloat(node.offsetY ?? 0)
        // Snap to whole points so SwiftUI text isn’t painted on fractional
        // origins (which makes some nodes look softer/thinner than others).
        let frame = CGRect(
            x: originX + ox,
            y: centerY - metrics.clusterHeight / 2 + oy,
            width: metrics.nodeSize.width,
            height: metrics.nodeSize.height
        ).integral
        let noteFrame = metrics.noteSize.map { noteSize in
            CGRect(
                x: frame.minX,
                y: frame.maxY + noteSpacing,
                width: noteSize.width,
                height: max(1, noteSize.height - noteSpacing)
            ).integral
        }
        let includedNote = noteFrame == nil ? nil : node.note

        nodes.append(
            LayoutNode(
                id: node.id,
                title: node.title,
                frame: frame,
                isExpanded: node.isExpanded,
                hasChildren: node.hasChildren,
                childCount: node.children.count,
                depth: depth,
                style: node.style,
                media: node.media,
                hasNote: node.note?.isEmpty == false,
                note: includedNote,
                noteFrame: noteFrame,
                hasManualPosition: node.hasManualPosition,
                branchHex: node.style.branchHex
            )
        )

        guard !node.children.isEmpty, !metrics.children.isEmpty else { return frame }

        let clusterWidth = max(
            metrics.nodeSize.width,
            metrics.noteSize?.width ?? 0
        )
        let childX = originX + clusterWidth + levelGap
        // Children use the *auto* center (without parent offset) for packing, but connect to offset frame.
        let autoCenterY = centerY
        let childrenHeight =
            metrics.children.reduce(0) { $0 + $1.subtreeHeight }
            + CGFloat(max(0, metrics.children.count - 1)) * siblingSpacing
        var y = autoCenterY - childrenHeight / 2

        for (child, childMetrics) in zip(node.children, metrics.children) {
            let childCenterY = y + childMetrics.subtreeHeight / 2
            if node.isExpanded || placementPolicy == .allDescendants {
                let childFrame = place(
                    child,
                    metrics: childMetrics,
                    originX: childX,
                    centerY: childCenterY,
                    depth: depth + 1,
                    placementPolicy: placementPolicy,
                    nodes: &nodes,
                    edges: &edges
                )
                let from = CGPoint(x: frame.maxX, y: frame.midY)
                let to = CGPoint(x: childFrame.minX, y: childFrame.midY)
                edges.append(
                    LayoutEdge(
                        fromID: node.id,
                        toID: child.id,
                        from: from,
                        to: to,
                        colorHex: node.style.branchHex
                    )
                )
            }
            y += childMetrics.subtreeHeight + siblingSpacing
        }
        return frame
    }
}
