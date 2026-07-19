import Foundation

public enum BrainstormDocumentEditError: Error, LocalizedError, Sendable {
    case nodeNotFound(UUID)
    case duplicateNodeID(UUID)
    case cannotModifyRoot(String)
    case invalidIndex(Int, validRange: ClosedRange<Int>)
    case invalidMove(String)
    case validationFailed([String])

    public var errorDescription: String? {
        switch self {
        case .nodeNotFound(let id):
            "Node not found: \(id.uuidString)"
        case .duplicateNodeID(let id):
            "A node with id \(id.uuidString) already exists."
        case .cannotModifyRoot(let operation):
            "Cannot \(operation) the root node."
        case .invalidIndex(let index, let range):
            "Index \(index) is outside the valid range \(range.lowerBound)...\(range.upperBound)."
        case .invalidMove(let detail):
            "Invalid move: \(detail)"
        case .validationFailed(let issues):
            "Document validation failed: \(issues.joined(separator: "; "))"
        }
    }
}

/// Pure, file-oriented tree operations shared by the agent CLI and tests.
/// No document session or GUI state is touched.
public enum BrainstormDocumentEditor {
    public static func node(in file: BrainstormFile, id: UUID) -> BrainstormNode? {
        findNode(file.root, id: id)
    }

    public static func allNodes(in file: BrainstormFile) -> [BrainstormNode] {
        var nodes: [BrainstormNode] = []
        walk(file.root) { nodes.append($0) }
        return nodes
    }

    @discardableResult
    public static func addNode(
        to file: inout BrainstormFile,
        parentID: UUID,
        id: UUID = UUID(),
        title: String,
        index: Int? = nil
    ) throws -> BrainstormNode {
        guard node(in: file, id: id) == nil else {
            throw BrainstormDocumentEditError.duplicateNodeID(id)
        }
        guard let parent = node(in: file, id: parentID) else {
            throw BrainstormDocumentEditError.nodeNotFound(parentID)
        }
        let insertionIndex = index ?? parent.children.count
        guard (0...parent.children.count).contains(insertionIndex) else {
            throw BrainstormDocumentEditError.invalidIndex(
                insertionIndex,
                validRange: 0...parent.children.count
            )
        }

        let newNode = BrainstormNode(id: id, title: normalizedTitle(title))
        _ = mutateNode(&file.root, id: parentID) { parent in
            parent.isExpanded = true
            parent.children.insert(newNode, at: insertionIndex)
        }
        return newNode
    }

    public static func updateNode(
        in file: inout BrainstormFile,
        id: UUID,
        _ mutate: (inout BrainstormNode) -> Void
    ) throws {
        guard mutateNode(&file.root, id: id, mutate) else {
            throw BrainstormDocumentEditError.nodeNotFound(id)
        }
    }

    @discardableResult
    public static func deleteNode(in file: inout BrainstormFile, id: UUID) throws -> BrainstormNode {
        guard id != file.root.id else {
            throw BrainstormDocumentEditError.cannotModifyRoot("delete")
        }
        var copy = file
        guard let removed = removeNode(from: &copy.root, id: id) else {
            throw BrainstormDocumentEditError.nodeNotFound(id)
        }
        file = copy
        return removed
    }

    public static func moveNode(
        in file: inout BrainstormFile,
        id: UUID,
        toParent parentID: UUID,
        index: Int? = nil
    ) throws {
        guard id != file.root.id else {
            throw BrainstormDocumentEditError.cannotModifyRoot("move")
        }
        guard let moving = node(in: file, id: id) else {
            throw BrainstormDocumentEditError.nodeNotFound(id)
        }
        guard let destination = node(in: file, id: parentID) else {
            throw BrainstormDocumentEditError.nodeNotFound(parentID)
        }
        guard id != parentID, findNode(moving, id: parentID) == nil else {
            throw BrainstormDocumentEditError.invalidMove("a node cannot become a child of itself or its descendant")
        }

        var copy = file
        guard removeNode(from: &copy.root, id: id) != nil else {
            throw BrainstormDocumentEditError.nodeNotFound(id)
        }
        let destinationCount = node(in: copy, id: parentID)?.children.count
            ?? destination.children.count
        let insertionIndex = index ?? destinationCount
        guard (0...destinationCount).contains(insertionIndex) else {
            throw BrainstormDocumentEditError.invalidIndex(
                insertionIndex,
                validRange: 0...destinationCount
            )
        }
        guard mutateNode(&copy.root, id: parentID, { parent in
            parent.isExpanded = true
            parent.children.insert(moving, at: insertionIndex)
        }) else {
            throw BrainstormDocumentEditError.nodeNotFound(parentID)
        }
        file = copy
    }

    public static func validationIssues(in file: BrainstormFile) -> [String] {
        var issues: [String] = []
        if !(1...BrainstormFile.currentVersion).contains(file.version) {
            issues.append("unsupported document version \(file.version)")
        }

        var ids: Set<UUID> = []
        walk(file.root) { node in
            if !ids.insert(node.id).inserted {
                issues.append("duplicate node id \(node.id.uuidString)")
            }
            if let width = node.style.borderWidth, width < 0 || width > 6 {
                issues.append("node \(node.id.uuidString) has border width outside 0...6")
            }
            if let size = node.style.fontSize, size < 8 || size > 72 {
                issues.append("node \(node.id.uuidString) has font size outside 8...72")
            }
            for (name, color) in [
                ("fill", node.style.fillHex),
                ("text", node.style.textHex),
                ("branch", node.style.branchHex),
                ("border", node.style.borderHex),
            ] {
                if let color, !isValidHexColor(color) {
                    issues.append("node \(node.id.uuidString) has invalid \(name) color \(color)")
                }
            }
            if let image = node.media.imageBase64, Data(base64Encoded: image) == nil {
                issues.append("node \(node.id.uuidString) has invalid base64 image data")
            }
        }
        if let themeID = file.themeID, !AppTheme.all.contains(where: { $0.id == themeID }) {
            issues.append("unknown theme id \(themeID)")
        }
        do {
            try NodeNoteValidator.validate(root: file.root)
        } catch let error as NodeNoteValidationError {
            issues.append("\(error.code.rawValue) at \(error.path): \(error.message)")
        } catch {
            issues.append("node note validation failed: \(error.localizedDescription)")
        }
        return issues
    }

    public static func validate(_ file: BrainstormFile) throws {
        let issues = validationIssues(in: file)
        if !issues.isEmpty {
            throw BrainstormDocumentEditError.validationFailed(issues)
        }
    }

    public static func normalizedTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func findNode(_ node: BrainstormNode, id: UUID) -> BrainstormNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(child, id: id) { return found }
        }
        return nil
    }

    private static func mutateNode(
        _ node: inout BrainstormNode,
        id: UUID,
        _ mutate: (inout BrainstormNode) -> Void
    ) -> Bool {
        if node.id == id {
            mutate(&node)
            return true
        }
        for index in node.children.indices {
            if mutateNode(&node.children[index], id: id, mutate) { return true }
        }
        return false
    }

    private static func removeNode(from node: inout BrainstormNode, id: UUID) -> BrainstormNode? {
        if let index = node.children.firstIndex(where: { $0.id == id }) {
            return node.children.remove(at: index)
        }
        for index in node.children.indices {
            if let removed = removeNode(from: &node.children[index], id: id) {
                return removed
            }
        }
        return nil
    }

    private static func walk(_ node: BrainstormNode, visit: (BrainstormNode) -> Void) {
        visit(node)
        for child in node.children { walk(child, visit: visit) }
    }

    private static func isValidHexColor(_ value: String) -> Bool {
        guard value.hasPrefix("#"), value.count == 7 else { return false }
        return value.dropFirst().allSatisfy(\.isHexDigit)
    }
}
