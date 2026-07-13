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
}

public struct LayoutEdge: Equatable, Sendable, Identifiable {
    public var id: String { "\(fromID.uuidString)-\(toID.uuidString)" }
    public let fromID: UUID
    public let toID: UUID
    public let from: CGPoint
    public let to: CGPoint
}

public struct LayoutResult: Equatable, Sendable {
    public let nodes: [LayoutNode]
    public let edges: [LayoutEdge]
    public let contentSize: CGSize

    public static let empty = LayoutResult(nodes: [], edges: [], contentSize: .zero)
}

public struct LayoutEngine: Sendable {
    /// Matches MindNodeView horizontal padding.
    public var horizontalPadding: CGFloat = 16
    /// Child node vertical padding (root uses `rootVerticalPadding`).
    public var verticalPadding: CGFloat = 10
    public var rootVerticalPadding: CGFloat = 12
    public var minNodeWidth: CGFloat = 100
    public var maxNodeWidth: CGFloat = 320
    public var levelGap: CGFloat = 80
    public var siblingSpacing: CGFloat = 16
    public var canvasPadding: CGFloat = 48
    /// Extra width so kerning / antialiasing never clips the last glyph.
    public var textWidthFudge: CGFloat = 4

    public init() {}

    public func layout(root: MindNode) -> LayoutResult {
        let metrics = measure(root, isRoot: true)
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
            nodes: &nodes,
            edges: &edges
        )

        let maxX = nodes.map { $0.frame.maxX }.max() ?? 0
        let maxY = nodes.map { $0.frame.maxY }.max() ?? 0
        let contentSize = CGSize(
            width: maxX + canvasPadding,
            height: maxY + canvasPadding
        )
        return LayoutResult(nodes: nodes, edges: edges, contentSize: contentSize)
    }

    // MARK: - Measure

    private struct SubtreeMetrics {
        var nodeSize: CGSize
        var subtreeHeight: CGFloat
        var children: [SubtreeMetrics]
    }

    /// Always measure the full tree (including folded branches).
    /// Fold only hides nodes when placing — it must not reflow siblings/ancestors,
    /// so elements keep a stable position in the window when hide/show toggles.
    private func measure(_ node: MindNode, isRoot: Bool) -> SubtreeMetrics {
        let nodeSize = sizeForTitle(node.title, isRoot: isRoot)
        guard !node.children.isEmpty else {
            return SubtreeMetrics(nodeSize: nodeSize, subtreeHeight: nodeSize.height, children: [])
        }

        let childMetrics = node.children.map { measure($0, isRoot: false) }
        let spacing = CGFloat(max(0, childMetrics.count - 1)) * siblingSpacing
        let childrenHeight = childMetrics.reduce(0) { $0 + $1.subtreeHeight } + spacing
        return SubtreeMetrics(
            nodeSize: nodeSize,
            subtreeHeight: max(nodeSize.height, childrenHeight),
            children: childMetrics
        )
    }

    /// Measure with the same fonts the view uses so titles never truncate after edit.
    private func sizeForTitle(_ title: String, isRoot: Bool) -> CGSize {
        let text: String
        if title.isEmpty {
            text = isRoot ? MindNode.mainPlaceholder : MindNode.nodePlaceholder
        } else {
            text = title
        }

        let font = NSFont.systemFont(
            ofSize: isRoot ? 16 : 14,
            weight: isRoot ? .semibold : .medium
        )
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let maxTextWidth = maxNodeWidth - horizontalPadding * 2
        let minTextWidth = minNodeWidth - horizontalPadding * 2

        // Natural single-line width first.
        let singleLine = (text as NSString).size(withAttributes: attributes)
        let needsWrap = singleLine.width + textWidthFudge > maxTextWidth

        let textSize: CGSize
        if needsWrap {
            let constraint = CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude)
            let rect = (text as NSString).boundingRect(
                with: constraint,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            )
            textSize = CGSize(
                width: maxTextWidth,
                height: max(ceil(rect.height), ceil(font.ascender - font.descender + font.leading))
            )
        } else {
            textSize = CGSize(
                width: ceil(singleLine.width) + textWidthFudge,
                height: ceil(singleLine.height)
            )
        }

        let contentWidth = min(maxTextWidth, max(minTextWidth, textSize.width))
        let vPad = isRoot ? rootVerticalPadding : verticalPadding
        // Cap wrapped lines similarly to the view's lineLimit(3).
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let maxTextHeight = lineHeight * 3
        let contentHeight = min(maxTextHeight, max(lineHeight, textSize.height))

        return CGSize(
            width: contentWidth + horizontalPadding * 2,
            height: contentHeight + vPad * 2
        )
    }

    // MARK: - Place

    private func place(
        _ node: MindNode,
        metrics: SubtreeMetrics,
        originX: CGFloat,
        centerY: CGFloat,
        depth: Int,
        nodes: inout [LayoutNode],
        edges: inout [LayoutEdge]
    ) {
        let frame = CGRect(
            x: originX,
            y: centerY - metrics.nodeSize.height / 2,
            width: metrics.nodeSize.width,
            height: metrics.nodeSize.height
        )

        nodes.append(
            LayoutNode(
                id: node.id,
                title: node.title,
                frame: frame,
                isExpanded: node.isExpanded,
                hasChildren: node.hasChildren,
                childCount: node.children.count,
                depth: depth
            )
        )

        // Still walk metrics for every child so coordinates stay stable when folded.
        // Only emit child nodes/edges when this branch is expanded (visible).
        guard !node.children.isEmpty, !metrics.children.isEmpty else { return }

        let childX = originX + metrics.nodeSize.width + levelGap
        let childrenHeight =
            metrics.children.reduce(0) { $0 + $1.subtreeHeight }
            + CGFloat(max(0, metrics.children.count - 1)) * siblingSpacing
        var y = centerY - childrenHeight / 2

        for (child, childMetrics) in zip(node.children, metrics.children) {
            let childCenterY = y + childMetrics.subtreeHeight / 2
            if node.isExpanded {
                place(
                    child,
                    metrics: childMetrics,
                    originX: childX,
                    centerY: childCenterY,
                    depth: depth + 1,
                    nodes: &nodes,
                    edges: &edges
                )

                if let childNode = nodes.last(where: { $0.id == child.id }) {
                    let from = CGPoint(x: frame.maxX, y: frame.midY)
                    let to = CGPoint(x: childNode.frame.minX, y: childNode.frame.midY)
                    edges.append(
                        LayoutEdge(fromID: node.id, toID: child.id, from: from, to: to)
                    )
                }
            }
            // Advance vertical slot even when folded so lower siblings keep their place.
            y += childMetrics.subtreeHeight + siblingSpacing
        }
    }
}
