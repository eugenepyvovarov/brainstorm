import Foundation
import Testing
@testable import MindMapFeature

@Suite("MindMapStore")
@MainActor
struct MindMapStoreTests {
    @Test func newDocumentSelectsRootAndStartsEditing() {
        // MindNode: new document opens with main node in edit mode.
        let store = MindMapStore(startEditing: true)
        #expect(store.selectedID == store.root.id)
        #expect(store.editingID == store.root.id)
        #expect(store.root.title.isEmpty)

        store.addChild()
        store.newDocument()
        #expect(store.selectedID == store.root.id)
        #expect(store.editingID == store.root.id)
        #expect(store.root.children.isEmpty)
        #expect(store.isDirty == false)
    }

    @Test func canvasClickEndsEditing() {
        let store = MindMapStore(startEditing: true)
        #expect(store.isEditing)
        store.commitEditing(title: "Summer Vacation")
        #expect(store.root.title == "Summer Vacation")
        #expect(!store.isEditing)

        store.beginEditing()
        store.canvasBackgroundClicked()
        #expect(!store.isEditing)
        #expect(store.selectedID == store.root.id)
    }

    @Test func documentTitleTracksMainNodeName() {
        let store = MindMapStore(startEditing: false)
        #expect(store.mapName == "Untitled")
        #expect(store.documentTitle == "Untitled")
        #expect(store.suggestedFileName == "Untitled.mindmap")

        store.rename(id: store.root.id, to: "Summer Vacation")
        #expect(store.mapName == "Summer Vacation")
        #expect(store.documentTitle.contains("Summer Vacation"))
        #expect(store.suggestedFileName == "Summer Vacation.mindmap")

        // Child renames must not change the map title.
        let child = store.addChild()!
        store.rename(id: child, to: "Packing list")
        #expect(store.mapName == "Summer Vacation")
    }

    @Test func rewireChangesParent() {
        let store = MindMapStore(startEditing: false)
        let a = store.addChild()!
        let b = store.addSibling()!
        let grand = store.addChild(of: a)!
        store.rewire(nodeID: grand, onto: b)
        #expect(store.node(id: a)?.children.isEmpty == true)
        #expect(store.node(id: b)?.children.map(\.id) == [grand])
    }

    @Test func rewireRejectsCycle() {
        let store = MindMapStore(startEditing: false)
        let a = store.addChild()!
        let grand = store.addChild(of: a)!
        store.rewire(nodeID: a, onto: grand) // would cycle
        #expect(store.node(id: a)?.children.map(\.id) == [grand])
        #expect(store.parentID(of: a) == store.root.id)
    }

    @Test func mindNodeTabChildAndReturnSibling() {
        let store = MindMapStore()
        // Tab on root -> child (MindNode)
        let childID = store.addChild()
        #expect(store.root.children.count == 1)
        #expect(store.selectedID == childID)

        // Return on child -> sibling (MindNode)
        let siblingID = store.addSibling(after: true)
        #expect(store.root.children.count == 2)
        #expect(store.selectedID == siblingID)
        #expect(store.root.children.map(\.id) == [childID!, siblingID!])
    }

    @Test func optionReturnAddsSiblingAbove() {
        let store = MindMapStore()
        let a = store.addChild()!
        let b = store.addSibling(after: true)!
        store.select(b)
        let above = store.addSibling(after: false)!
        #expect(store.root.children.map(\.id) == [a, above, b])
    }

    @Test func optionTabInsertsParent() {
        let store = MindMapStore()
        let child = store.addChild()!
        store.select(child)
        let parent = store.insertParentForSelection()!
        #expect(store.root.children.count == 1)
        #expect(store.root.children[0].id == parent)
        #expect(store.root.children[0].children.map(\.id) == [child])
        #expect(store.selectedID == parent)
    }

    @Test func shiftReturnAddsMainNode() {
        let store = MindMapStore()
        let branch = store.addChild()!
        _ = store.addChild(of: branch)
        store.select(branch)
        let main = store.addMainNode()!
        #expect(store.root.children.map(\.id).contains(main))
        #expect(store.root.children.last?.id == main)
    }

    @Test func cannotDeleteRoot() {
        let store = MindMapStore()
        store.deleteSelected()
        #expect(store.root.id == store.selectedID)
        #expect(store.node(id: store.root.id) != nil)
    }

    @Test func deleteSelectsNeighbor() {
        let store = MindMapStore()
        let a = store.addChild()!
        let b = store.addSibling()!
        store.select(a)
        store.deleteSelected()
        #expect(store.node(id: a) == nil)
        #expect(store.selectedID == b)
        #expect(store.root.children.count == 1)
    }

    @Test func deleteSinglePromotesChildren() {
        let store = MindMapStore()
        let mid = store.addChild()!
        let grand = store.addChild(of: mid)!
        store.select(mid)
        store.deleteSingleNode()
        #expect(store.node(id: mid) == nil)
        #expect(store.root.children.map(\.id) == [grand])
        #expect(store.selectedID == grand)
    }

    @Test func indentAndOutdentViaCommandArrows() {
        let store = MindMapStore()
        let first = store.addChild()!
        let second = store.addSibling()!
        store.select(second)
        store.indentSelected()

        #expect(store.root.children.count == 1)
        #expect(store.root.children[0].id == first)
        #expect(store.root.children[0].children.map(\.id) == [second])

        store.select(second)
        store.outdentSelected()
        #expect(store.root.children.map(\.id) == [first, second])
        #expect(store.root.children[0].children.isEmpty)
    }

    @Test func moveAmongSiblings() {
        let store = MindMapStore()
        let a = store.addChild()!
        let b = store.addSibling()!
        store.select(a)
        store.moveSelectedDown()
        #expect(store.root.children.map(\.id) == [b, a])
        store.moveSelectedUp()
        #expect(store.root.children.map(\.id) == [a, b])
    }

    @Test func navigationDoesNotFoldOnLeft() {
        let store = MindMapStore()
        let child = store.addChild()!
        _ = store.addChild(of: child)
        store.select(child)
        #expect(store.node(id: child)?.isExpanded == true)
        store.navigateLeft()
        // MindNode canvas: left moves to parent; fold is ⌥.
        #expect(store.selectedID == store.root.id)
        #expect(store.node(id: child)?.isExpanded == true)
    }

    @Test func foldToggle() {
        let store = MindMapStore()
        let child = store.addChild()!
        _ = store.addChild(of: child)
        store.select(child)
        store.toggleFoldSelected()
        #expect(store.node(id: child)?.isExpanded == false)
        store.toggleFoldSelected()
        #expect(store.node(id: child)?.isExpanded == true)
    }

    @Test func goToMainAndDeselect() {
        let store = MindMapStore()
        let child = store.addChild()!
        store.select(child)
        store.goToMainNode()
        #expect(store.selectedID == store.root.id)
        store.deselect()
        #expect(store.selectedID == nil)
    }

    @Test func renameAndCodecRoundTrip() throws {
        let store = MindMapStore()
        store.rename(id: store.root.id, to: "  Hello Map  ")
        #expect(store.root.title == "Hello Map")

        let file = MindMapFile(root: store.root)
        let data = try MindMapCodec.encode(file)
        let decoded = try MindMapCodec.decode(from: data)
        #expect(decoded.root.title == "Hello Map")
        #expect(decoded.version == 1)
    }

    @Test func undoRedoAddChild() {
        let store = MindMapStore(startEditing: false)
        _ = store.addChild()
        #expect(store.root.children.count == 1)
        #expect(store.canUndo)
        store.undo()
        #expect(store.root.children.isEmpty)
        #expect(store.canRedo)
        store.redo()
        #expect(store.root.children.count == 1)
    }

    @Test func undoRestoresAccidentallyDeletedNode() {
        let store = MindMapStore(startEditing: false)
        let child = store.addChild()!
        store.rename(id: child, to: "Important idea")
        store.select(child)
        store.deleteSelected()
        #expect(store.node(id: child) == nil)
        #expect(store.root.children.isEmpty)

        store.undo()
        #expect(store.node(id: child)?.title == "Important idea")
        #expect(store.root.children.map(\.id) == [child])
        #expect(store.selectedID == child)

        store.redo()
        #expect(store.node(id: child) == nil)
        store.undo()
        #expect(store.node(id: child)?.title == "Important idea")
    }

    @Test func undoRestoresDeletedSubtree() {
        let store = MindMapStore(startEditing: false)
        let parent = store.addChild()!
        store.rename(id: parent, to: "Parent")
        let grand = store.addChild(of: parent)!
        store.rename(id: grand, to: "Child")
        store.select(parent)
        store.deleteSelected()
        #expect(store.root.children.isEmpty)

        store.undo()
        #expect(store.node(id: parent)?.title == "Parent")
        #expect(store.node(id: parent)?.children.map(\.id) == [grand])
        #expect(store.node(id: grand)?.title == "Child")
    }

    @Test func ensureSelectionRestoresRootWhenNil() {
        let store = MindMapStore(startEditing: false)
        store.deselect()
        #expect(store.selectedID == nil)
        let id = store.ensureSelection()
        #expect(id == store.root.id)
        #expect(store.selectedID == store.root.id)
    }

    @Test func continuousReturnWhileEditingCreatesSiblings() {
        // Keyboard-only capture: type → Return → type → Return (no double-Return).
        let store = MindMapStore(startEditing: false)
        store.commitEditing()
        let first = store.addChild()!
        store.beginEditing(id: first)
        store.updateEditingDraft("Alpha")
        store.applyTitleLive(id: first, raw: "Alpha")

        let second = store.addSibling(after: true)!
        #expect(store.node(id: first)?.title == "Alpha")
        #expect(store.editingID == second)
        #expect(store.selectedID == second)

        store.updateEditingDraft("Beta")
        store.applyTitleLive(id: second, raw: "Beta")
        let third = store.addSibling(after: true)!
        // New sibling opens empty + in edit mode (placeholder applied only on commit).
        #expect(store.root.children.map(\.title) == ["Alpha", "Beta", ""])
        #expect(store.editingID == third)
        #expect(store.selectedID == third)
    }

    @Test func arrowsWhileEditingCommitAndNavigate() {
        let store = MindMapStore(startEditing: false)
        let a = store.addChild()!
        let b = store.addSibling()!
        store.beginEditing(id: b)
        store.updateEditingDraft("Second")
        store.applyTitleLive(id: b, raw: "Second")

        store.navigateUp()
        #expect(!store.isEditing)
        #expect(store.selectedID == a)
        #expect(store.node(id: b)?.title == "Second")
    }

    @Test func tabWhileEditingCreatesChildReadyToType() {
        let store = MindMapStore(startEditing: false)
        let parent = store.addChild()!
        store.beginEditing(id: parent)
        store.updateEditingDraft("Parent")
        store.applyTitleLive(id: parent, raw: "Parent")

        let child = store.addChild()!
        #expect(store.node(id: parent)?.title == "Parent")
        #expect(store.editingID == child)
        #expect(store.node(id: parent)?.children.map(\.id) == [child])
    }

    @Test func navigateWithNoSelectionSelectsRoot() {
        let store = MindMapStore(startEditing: false)
        store.deselect()
        store.navigateDown()
        #expect(store.selectedID == store.root.id)
    }
}

@Suite("LayoutEngine")
struct LayoutEngineTests {
    @Test func layoutPlacesChildrenToTheRight() {
        var root = MindNode.root(title: "Root")
        root.children = [
            MindNode(title: "A"),
            MindNode(title: "B"),
        ]
        let result = LayoutEngine().layout(root: root)
        #expect(result.nodes.count == 3)
        #expect(result.edges.count == 2)

        let rootLayout = result.nodes.first { $0.title == "Root" }!
        let a = result.nodes.first { $0.title == "A" }!
        let b = result.nodes.first { $0.title == "B" }!

        #expect(a.frame.minX > rootLayout.frame.maxX)
        #expect(b.frame.minX > rootLayout.frame.maxX)
        #expect(b.frame.minY > a.frame.minY)
    }

    @Test func collapsedHidesDescendants() {
        var root = MindNode.root(title: "Root")
        var child = MindNode(title: "Child", isExpanded: true)
        child.children = [MindNode(title: "Grand")]
        child.isExpanded = false
        root.children = [child]

        let result = LayoutEngine().layout(root: root)
        #expect(result.nodes.map(\.title) == ["Root", "Child"])
        #expect(result.edges.count == 1)
    }

    @Test func foldDoesNotMoveSiblingFrames() {
        // Hide/show must not reflow other branches — positions stay put in the window.
        var root = MindNode.root(title: "Root")
        var branch = MindNode(title: "Branch", isExpanded: true)
        branch.children = [
            MindNode(title: "B1"),
            MindNode(title: "B2"),
            MindNode(title: "B3"),
        ]
        let sibling = MindNode(title: "Sibling")
        root.children = [branch, sibling]

        let expanded = LayoutEngine().layout(root: root)
        let siblingExpanded = expanded.nodes.first { $0.title == "Sibling" }!
        let branchExpanded = expanded.nodes.first { $0.title == "Branch" }!
        let rootExpanded = expanded.nodes.first { $0.title == "Root" }!

        root.children[0].isExpanded = false
        let folded = LayoutEngine().layout(root: root)
        let siblingFolded = folded.nodes.first { $0.title == "Sibling" }!
        let branchFolded = folded.nodes.first { $0.title == "Branch" }!
        let rootFolded = folded.nodes.first { $0.title == "Root" }!

        #expect(folded.nodes.map(\.title) == ["Root", "Branch", "Sibling"])
        #expect(siblingFolded.frame == siblingExpanded.frame)
        #expect(branchFolded.frame == branchExpanded.frame)
        #expect(rootFolded.frame == rootExpanded.frame)
    }

    @Test func rootTitleFrameFitsFullTextWithoutTruncation() {
        // Regression: "Main Idea" was laid out too narrow and showed as "Main I…".
        let short = LayoutEngine().layout(root: .root(title: "Main Idea"))
        let shortNode = short.nodes[0]
        #expect(shortNode.frame.width > 100)

        let longTitle = "Summer Vacation Planning"
        let long = LayoutEngine().layout(root: .root(title: longTitle))
        let longNode = long.nodes[0]
        // Must be wider than a short root; still within max width + padding.
        #expect(longNode.frame.width > shortNode.frame.width)
        #expect(longNode.frame.width <= 320)
    }
}
