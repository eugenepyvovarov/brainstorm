import CoreGraphics
import Foundation

/// One immutable step in Brainstorm's root-first, depth-first presentation.
public struct PresentationItem: Identifiable, Equatable, Sendable {
    public let node: BrainstormNode
    public let parentID: UUID?
    /// Root-first IDs above this item. The item's own ID is not included.
    public let ancestorIDs: [UUID]
    public let depth: Int
    public let siblingIndex: Int
    /// Frame from the layout snapshot used to construct the presentation.
    ///
    /// Sequence-only callers may omit a layout. Presentation renderers can pass
    /// an ``LayoutResult`` produced with ``LayoutPlacementPolicy/allDescendants``
    /// to receive the exact fully expanded map geometry without changing the
    /// document's saved fold state.
    public let layoutFrame: CGRect?

    public var id: UUID { node.id }
    public var pathIDs: [UUID] { ancestorIDs + [id] }
    public var layoutCenter: CGPoint? {
        layoutFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    public init(
        node: BrainstormNode,
        parentID: UUID?,
        ancestorIDs: [UUID],
        depth: Int,
        siblingIndex: Int,
        layoutFrame: CGRect? = nil
    ) {
        self.node = node
        self.parentID = parentID
        self.ancestorIDs = ancestorIDs
        self.depth = depth
        self.siblingIndex = siblingIndex
        self.layoutFrame = layoutFrame
    }
}

/// Tree-aware path used to move a presentation camera between two DFS steps.
///
/// `nodeIDs` always starts at the source and finishes at the destination. When
/// the nodes live in different branches, the path climbs to their lowest common
/// ancestor before descending the destination branch. `points` is available
/// only when every route node was present in the supplied layout snapshot.
public struct PresentationTraversalRoute: Equatable, Sendable {
    public let nodeIDs: [UUID]
    public let points: [CGPoint]?
    public let relationship: PresentationRelationship

    public init(
        nodeIDs: [UUID],
        points: [CGPoint]?,
        relationship: PresentationRelationship
    ) {
        self.nodeIDs = nodeIDs
        self.points = points
        self.relationship = relationship
    }

    public var hasCompleteSpatialPath: Bool {
        points?.count == nodeIDs.count
    }
}

/// How a presentation destination relates to its source.
///
/// Parent and child relationships may span more than one level when callers
/// compare non-adjacent slides. A branch jump records the lowest common
/// ancestor plus both sides of the climb so the UI can explain the transition.
public enum PresentationRelationship: Equatable, Sendable {
    case parent(levels: Int)
    case child(levels: Int)
    case sibling(parentID: UUID?)
    case branchJump(
        lowestCommonAncestorID: UUID,
        ascendingLevels: Int,
        descendingLevels: Int
    )

    var connectorLabel: String {
        switch self {
        case .parent(let levels):
            return levels == 1 ? "Parent" : "Ancestor · \(levels) levels up"
        case .child(let levels):
            return levels == 1 ? "Child" : "Descendant · \(levels) levels down"
        case .sibling:
            return "Sibling"
        case .branchJump(_, let ascendingLevels, let descendingLevels):
            return "Branch · \(Self.levelCount(ascendingLevels)) up · \(Self.levelCount(descendingLevels)) down"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .parent(let levels):
            return levels == 1
                ? "parent, one level up"
                : "ancestor, \(levels) levels up"
        case .child(let levels):
            return levels == 1
                ? "child, one level down"
                : "descendant, \(levels) levels down"
        case .sibling:
            return "sibling on the same level"
        case .branchJump(_, let ascendingLevels, let descendingLevels):
            return "another branch, \(Self.levelCount(ascendingLevels)) up and \(Self.levelCount(descendingLevels)) down"
        }
    }

    private static func levelCount(_ levels: Int) -> String {
        levels == 1 ? "one level" : "\(levels) levels"
    }
}

/// Stable presentation order independent of canvas expansion and layout.
///
/// Brainstorm presents the root, then each complete child subtree in stored
/// sibling order. Collapsed descendants are deliberately included.
public struct PresentationSequence: Equatable, Sendable {
    public let items: [PresentationItem]
    private let indicesByID: [UUID: Int]
    private let layoutFramesByID: [UUID: CGRect]
    private let layoutCentersByID: [UUID: CGPoint]

    public init(root: BrainstormNode, layout: LayoutResult? = nil) {
        let framesByID = layout.map {
            Dictionary(uniqueKeysWithValues: $0.nodes.map { ($0.id, $0.frame) })
        } ?? [:]
        var result: [PresentationItem] = []
        Self.append(
            root,
            parentID: nil,
            ancestorIDs: [],
            depth: 0,
            siblingIndex: 0,
            framesByID: framesByID,
            to: &result
        )
        items = result
        indicesByID = Dictionary(
            uniqueKeysWithValues: result.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        layoutFramesByID = Dictionary(
            uniqueKeysWithValues: result.compactMap { item in
                item.layoutFrame.map { (item.id, $0) }
            }
        )
        layoutCentersByID = Dictionary(
            uniqueKeysWithValues: result.compactMap { item in
                item.layoutCenter.map { (item.id, $0) }
            }
        )
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    public subscript(index: Int) -> PresentationItem {
        items[index]
    }

    public func index(of nodeID: UUID) -> Int? {
        indicesByID[nodeID]
    }

    public func layoutFrame(for nodeID: UUID) -> CGRect? {
        layoutFramesByID[nodeID]
    }

    /// Describes `destination` relative to `source`.
    public func relationship(
        from sourceIndex: Int,
        to destinationIndex: Int
    ) -> PresentationRelationship? {
        guard items.indices.contains(sourceIndex),
              items.indices.contains(destinationIndex),
              sourceIndex != destinationIndex
        else {
            return nil
        }
        return Self.relationship(
            from: items[sourceIndex],
            to: items[destinationIndex]
        )
    }

    /// Describes `destination` relative to `source`.
    public func relationship(
        from sourceID: UUID,
        to destinationID: UUID
    ) -> PresentationRelationship? {
        guard let sourceIndex = index(of: sourceID),
              let destinationIndex = index(of: destinationID)
        else {
            return nil
        }
        return relationship(from: sourceIndex, to: destinationIndex)
    }

    /// Returns the hierarchy path a camera should follow between two steps.
    ///
    /// Direct ancestors and descendants include every intermediate node.
    /// Siblings route through their parent. Cross-branch movement climbs from
    /// the source to the lowest common ancestor and then descends to the
    /// destination, so a DFS jump out of a deep branch visibly travels back
    /// across the map instead of taking a direct diagonal shortcut.
    public func traversalRoute(
        from sourceIndex: Int,
        to destinationIndex: Int
    ) -> PresentationTraversalRoute? {
        guard items.indices.contains(sourceIndex),
              items.indices.contains(destinationIndex),
              sourceIndex != destinationIndex,
              let relationship = relationship(
                  from: sourceIndex,
                  to: destinationIndex
              )
        else {
            return nil
        }

        let source = items[sourceIndex]
        let destination = items[destinationIndex]
        let commonPrefix = zip(source.pathIDs, destination.pathIDs)
            .prefix { $0.0 == $0.1 }
            .map(\.0)
        guard let lowestCommonAncestorID = commonPrefix.last else {
            return nil
        }

        let sourceBelowAncestor = source.pathIDs.dropFirst(commonPrefix.count)
        let destinationBelowAncestor = destination.pathIDs.dropFirst(commonPrefix.count)
        let nodeIDs =
            Array(sourceBelowAncestor.reversed())
            + [lowestCommonAncestorID]
            + Array(destinationBelowAncestor)

        var spatialPoints: [CGPoint] = []
        spatialPoints.reserveCapacity(nodeIDs.count)
        for nodeID in nodeIDs {
            guard let center = layoutCenter(for: nodeID) else {
                return PresentationTraversalRoute(
                    nodeIDs: nodeIDs,
                    points: nil,
                    relationship: relationship
                )
            }
            spatialPoints.append(center)
        }
        return PresentationTraversalRoute(
            nodeIDs: nodeIDs,
            points: spatialPoints,
            relationship: relationship
        )
    }

    public func traversalRoute(
        from sourceID: UUID,
        to destinationID: UUID
    ) -> PresentationTraversalRoute? {
        guard let sourceIndex = index(of: sourceID),
              let destinationIndex = index(of: destinationID)
        else {
            return nil
        }
        return traversalRoute(
            from: sourceIndex,
            to: destinationIndex
        )
    }

    public func layoutCenter(for nodeID: UUID) -> CGPoint? {
        layoutCentersByID[nodeID]
    }

    private static func relationship(
        from source: PresentationItem,
        to destination: PresentationItem
    ) -> PresentationRelationship? {
        if source.ancestorIDs.contains(destination.id) {
            return .parent(levels: source.depth - destination.depth)
        }
        if destination.ancestorIDs.contains(source.id) {
            return .child(levels: destination.depth - source.depth)
        }
        if source.parentID == destination.parentID {
            return .sibling(parentID: source.parentID)
        }

        let commonPrefix = zip(source.pathIDs, destination.pathIDs)
            .prefix { $0.0 == $0.1 }
            .map(\.0)
        guard let lowestCommonAncestorID = commonPrefix.last else {
            return nil
        }
        let ascendingLevels = source.pathIDs.count - commonPrefix.count
        let descendingLevels = destination.pathIDs.count - commonPrefix.count
        return .branchJump(
            lowestCommonAncestorID: lowestCommonAncestorID,
            ascendingLevels: ascendingLevels,
            descendingLevels: descendingLevels
        )
    }

    private static func append(
        _ node: BrainstormNode,
        parentID: UUID?,
        ancestorIDs: [UUID],
        depth: Int,
        siblingIndex: Int,
        framesByID: [UUID: CGRect],
        to result: inout [PresentationItem]
    ) {
        result.append(PresentationItem(
            node: node,
            parentID: parentID,
            ancestorIDs: ancestorIDs,
            depth: depth,
            siblingIndex: siblingIndex,
            layoutFrame: framesByID[node.id]
        ))
        for (index, child) in node.children.enumerated() {
            append(
                child,
                parentID: node.id,
                ancestorIDs: ancestorIDs + [node.id],
                depth: depth + 1,
                siblingIndex: index,
                framesByID: framesByID,
                to: &result
            )
        }
    }
}
