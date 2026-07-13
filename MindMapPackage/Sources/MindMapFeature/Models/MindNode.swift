import Foundation

/// A single node in the mind map tree.
public struct MindNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var isExpanded: Bool
    public var children: [MindNode]

    public init(
        id: UUID = UUID(),
        title: String = "New node",
        isExpanded: Bool = true,
        children: [MindNode] = []
    ) {
        self.id = id
        self.title = title
        self.isExpanded = isExpanded
        self.children = children
    }

    public var hasChildren: Bool { !children.isEmpty }

    /// Fresh main node title is empty so the user can type immediately (MindNode first-map UX).
    public static func root(title: String = "") -> MindNode {
        MindNode(title: title, isExpanded: true, children: [])
    }

    public static let mainPlaceholder = "Main Idea"
    public static let nodePlaceholder = "New node"
}

/// On-disk document envelope.
public struct MindMapFile: Codable, Equatable, Sendable {
    public var version: Int
    public var root: MindNode

    public init(version: Int = 1, root: MindNode) {
        self.version = version
        self.root = root
    }

    public static let currentVersion = 1
}
