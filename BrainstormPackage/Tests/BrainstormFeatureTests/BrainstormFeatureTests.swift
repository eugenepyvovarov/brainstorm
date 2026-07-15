import AppKit
import Foundation
import Testing
@testable import BrainstormFeature

@MainActor
private final class TestWindowDelegate: NSObject, NSWindowDelegate {
    let allowsClose: Bool

    init(allowsClose: Bool = true) {
        self.allowsClose = allowsClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        allowsClose
    }
}

@Suite("DocumentWindowTabbing", .serialized)
@MainActor
struct DocumentWindowTabbingTests {
    @Test func interleavedRequestsKeepTheirExactParents() {
        var registry = DocumentTabIntentRegistry()
        let firstParentID = UUID()
        let secondParentID = UUID()
        let firstChildID = UUID()
        let secondChildID = UUID()

        registry.set(
            childDocumentID: firstChildID,
            parentDocumentID: firstParentID,
            select: true
        )
        registry.set(
            childDocumentID: secondChildID,
            parentDocumentID: secondParentID,
            select: false
        )

        #expect(registry.children(waitingFor: firstParentID) == [firstChildID])
        #expect(registry.children(waitingFor: secondParentID) == [secondChildID])
        #expect(registry.intent(for: firstChildID)?.selectsNewTab == true)
        #expect(registry.intent(for: secondChildID)?.selectsNewTab == false)
    }

    @Test func removingDocumentClearsChildAndParentIntentsOnly() {
        var registry = DocumentTabIntentRegistry()
        let parentID = UUID()
        let otherParentID = UUID()
        let firstChildID = UUID()
        let secondChildID = UUID()
        registry.set(
            childDocumentID: firstChildID,
            parentDocumentID: parentID,
            select: true
        )
        registry.set(
            childDocumentID: secondChildID,
            parentDocumentID: otherParentID,
            select: true
        )

        registry.remove(documentID: parentID)

        #expect(registry.intent(for: firstChildID) == nil)
        #expect(registry.intent(for: secondChildID)?.parentDocumentID == otherParentID)
    }

    @Test func applicationDisablesImplicitGrouping() {
        NSWindow.allowsAutomaticWindowTabbing = true
        DocumentWindowTabbing.configureApplicationTabbing()
        #expect(NSWindow.allowsAutomaticWindowTabbing == false)
    }

    @Test func coordinatorExportsNativeTabBarPlusSelector() {
        var didRequestTab = false
        let coordinator = WindowChromeBridge.Coordinator(
            documentID: UUID(),
            isDocumentEdited: false,
            shouldClose: { _ in true },
            onNewTab: { _ in didRequestTab = true }
        )

        #expect(coordinator.responds(to: #selector(NSResponder.newWindowForTab(_:))))
        coordinator.newWindowForTab(nil)
        #expect(didRequestTab)
    }

    @Test func coordinatorRestoresWindowHooksWhenHostViewLeavesWindow() {
        let documentID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let originalDelegate = TestWindowDelegate()
        let originalResponder = NSResponder()
        window.delegate = originalDelegate
        window.nextResponder = originalResponder

        let coordinator = WindowChromeBridge.Coordinator(
            documentID: documentID,
            isDocumentEdited: false,
            shouldClose: { _ in true },
            onNewTab: { _ in }
        )
        coordinator.attach(to: window)
        #expect((window.delegate as AnyObject?) === coordinator)
        #expect(window.nextResponder === coordinator)

        coordinator.attach(to: nil)
        #expect((window.delegate as AnyObject?) === originalDelegate)
        #expect(window.nextResponder === originalResponder)
        DocumentWindowTabbing.unregister(documentID: documentID, window: window)
    }

    @Test func coordinatorRespectsForwardedCloseVeto() {
        let forwardedDelegate = TestWindowDelegate(allowsClose: false)
        var appCloseHandlerCalled = false
        let coordinator = WindowChromeBridge.Coordinator(
            documentID: UUID(),
            isDocumentEdited: false,
            shouldClose: { _ in
                appCloseHandlerCalled = true
                return true
            },
            onNewTab: { _ in }
        )
        coordinator.forwardedDelegate = forwardedDelegate

        #expect(!coordinator.windowShouldClose(NSWindow()))
        #expect(!appCloseHandlerCalled)
    }

    @Test func onlySelectedNativeTabReceivesSharedCommands() {
        let first = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let second = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        DocumentWindowTabbing.attachAsTab(second, into: first, select: true)

        #expect(!DocumentWindowTabbing.isCommandTarget(first))
        #expect(DocumentWindowTabbing.isCommandTarget(second))

        first.tabGroup?.selectedWindow = first
        #expect(DocumentWindowTabbing.isCommandTarget(first))
        #expect(!DocumentWindowTabbing.isCommandTarget(second))
    }
}

@Suite("BrainstormStore")
@MainActor
struct BrainstormStoreTests {
    @Test func newDocumentSelectsRootAndStartsEditing() {
        // BrainstormNode: new document opens with main node in edit mode.
        let store = BrainstormStore(startEditing: true)
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
        let store = BrainstormStore(startEditing: true)
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
        let store = BrainstormStore(startEditing: false)
        #expect(store.mapName == "Untitled")
        #expect(store.documentTitle == "Untitled")
        #expect(store.suggestedFileName == "Untitled.bs")

        store.rename(id: store.root.id, to: "Summer Vacation")
        #expect(store.mapName == "Summer Vacation")
        #expect(store.documentTitle == "Summer Vacation")
        #expect(store.suggestedFileName == "Summer Vacation.bs")

        // Child renames must not change the map title.
        let child = store.addChild()!
        store.rename(id: child, to: "Packing list")
        #expect(store.mapName == "Summer Vacation")
    }

    @Test func brainstormDocumentExtensionIsBs() {
        #expect(BrainstormCodec.fileExtension == "bs")
        #expect(BrainstormCodec.contentTypeIdentifier == "com.eugenep.Brainstorm.bs")
        #expect(ExternalDocumentRouter.isSupportedMap(URL(fileURLWithPath: "/tmp/Idea.bs")))
        #expect(!ExternalDocumentRouter.isSupportedMap(URL(fileURLWithPath: "/tmp/Idea.brainstorm")))
        #expect(!ExternalDocumentRouter.isSupportedMap(URL(fileURLWithPath: "/tmp/Idea.json")))
        #expect(!ExternalDocumentRouter.isSupportedMap(URL(fileURLWithPath: "/tmp/Idea.txt")))
    }

    @Test func rewireChangesParent() {
        let store = BrainstormStore(startEditing: false)
        let a = store.addChild()!
        let b = store.addSibling()!
        let grand = store.addChild(of: a)!
        store.rewire(nodeID: grand, onto: b)
        #expect(store.node(id: a)?.children.isEmpty == true)
        #expect(store.node(id: b)?.children.map(\.id) == [grand])
    }

    @Test func rewireRejectsCycle() {
        let store = BrainstormStore(startEditing: false)
        let a = store.addChild()!
        let grand = store.addChild(of: a)!
        store.rewire(nodeID: a, onto: grand) // would cycle
        #expect(store.node(id: a)?.children.map(\.id) == [grand])
        #expect(store.parentID(of: a) == store.root.id)
    }

    @Test func mindNodeTabChildAndReturnSibling() {
        let store = BrainstormStore()
        // Tab on root -> child (BrainstormNode)
        let childID = store.addChild()
        #expect(store.root.children.count == 1)
        #expect(store.selectedID == childID)

        // Return on child -> sibling (BrainstormNode)
        let siblingID = store.addSibling(after: true)
        #expect(store.root.children.count == 2)
        #expect(store.selectedID == siblingID)
        #expect(store.root.children.map(\.id) == [childID!, siblingID!])
    }

    @Test func optionReturnAddsSiblingAbove() {
        let store = BrainstormStore()
        let a = store.addChild()!
        let b = store.addSibling(after: true)!
        store.select(b)
        let above = store.addSibling(after: false)!
        #expect(store.root.children.map(\.id) == [a, above, b])
    }

    @Test func optionTabInsertsParent() {
        let store = BrainstormStore()
        let child = store.addChild()!
        store.select(child)
        let parent = store.insertParentForSelection()!
        #expect(store.root.children.count == 1)
        #expect(store.root.children[0].id == parent)
        #expect(store.root.children[0].children.map(\.id) == [child])
        #expect(store.selectedID == parent)
    }

    @Test func shiftReturnAddsMainNode() {
        let store = BrainstormStore()
        let branch = store.addChild()!
        _ = store.addChild(of: branch)
        store.select(branch)
        let main = store.addMainNode()!
        #expect(store.root.children.map(\.id).contains(main))
        #expect(store.root.children.last?.id == main)
    }

    @Test func cannotDeleteRoot() {
        let store = BrainstormStore()
        store.deleteSelected()
        #expect(store.root.id == store.selectedID)
        #expect(store.node(id: store.root.id) != nil)
    }

    @Test func deleteSelectsNeighbor() {
        let store = BrainstormStore()
        let a = store.addChild()!
        let b = store.addSibling()!
        store.select(a)
        store.deleteSelected()
        #expect(store.node(id: a) == nil)
        #expect(store.selectedID == b)
        #expect(store.root.children.count == 1)
    }

    @Test func emptyEditingBackspaceDeletesAndSelectsPrevious() {
        let store = BrainstormStore(startEditing: false)
        let a = store.addChild()!
        store.commitEditing()
        store.rename(id: a, to: "First")
        let b = store.addSibling()! // empty + editing
        #expect(store.editingID == b)
        #expect(store.editingDraft.isEmpty)

        #expect(store.deleteEmptyEditingNode())
        #expect(store.node(id: b) == nil)
        #expect(store.selectedID == a)
        #expect(store.editingID == nil)
        #expect(store.root.children.map(\.id) == [a])
    }

    @Test func emptyEditingBackspaceDoesNotDeleteRoot() {
        let store = BrainstormStore(startEditing: false)
        store.beginEditing(id: store.root.id)
        store.updateEditingDraft("")
        #expect(!store.deleteEmptyEditingNode())
        #expect(store.node(id: store.root.id) != nil)
        #expect(store.editingID == store.root.id)
    }

    @Test func emptyEditingBackspaceIgnoredWhenDraftHasText() {
        let store = BrainstormStore(startEditing: false)
        let child = store.addChild()!
        store.updateEditingDraft("Hello")
        #expect(!store.deleteEmptyEditingNode())
        #expect(store.node(id: child) != nil)
        #expect(store.editingID == child)
    }

    @Test func emptyEditingBackspaceSelectsParentWhenFirstChild() {
        let store = BrainstormStore(startEditing: false)
        let child = store.addChild()! // empty child of root, editing
        #expect(store.deleteEmptyEditingNode())
        #expect(store.node(id: child) == nil)
        #expect(store.selectedID == store.root.id)
        #expect(store.root.children.isEmpty)
    }

    @Test func deleteSinglePromotesChildren() {
        let store = BrainstormStore()
        let mid = store.addChild()!
        let grand = store.addChild(of: mid)!
        store.select(mid)
        store.deleteSingleNode()
        #expect(store.node(id: mid) == nil)
        #expect(store.root.children.map(\.id) == [grand])
        #expect(store.selectedID == grand)
    }

    @Test func indentAndOutdentViaCommandArrows() {
        let store = BrainstormStore()
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
        let store = BrainstormStore()
        let a = store.addChild()!
        let b = store.addSibling()!
        store.select(a)
        store.moveSelectedDown()
        #expect(store.root.children.map(\.id) == [b, a])
        store.moveSelectedUp()
        #expect(store.root.children.map(\.id) == [a, b])
    }

    @Test func reorderAmongSiblingsInsertsAndShiftsInterveningItems() {
        let store = BrainstormStore(startEditing: false)
        let a = store.addChild()!
        let b = store.addSibling()!
        let c = store.addSibling()!
        let d = store.addSibling()!
        #expect(store.root.children.map(\.id) == [a, b, c, d])

        // Moving first to last shifts the intervening siblings left.
        store.reorderAmongSiblings(nodeID: a, toIndex: 3)
        #expect(store.root.children.map(\.id) == [b, c, d, a])
        #expect(store.selectedID == a)

        // Moving last (a) to second shifts c and d right.
        store.reorderAmongSiblings(nodeID: a, toIndex: 1)
        #expect(store.root.children.map(\.id) == [b, a, c, d])

        // Nested siblings under b.
        store.select(b)
        let b1 = store.addChild(of: b)!
        let b2 = store.addChild(of: b)!
        let b3 = store.addChild(of: b)!
        store.reorderAmongSiblings(nodeID: b3, toIndex: 0)
        #expect(store.node(id: b)?.children.map(\.id) == [b3, b1, b2])

        // Root cannot be reordered; no-op.
        store.reorderAmongSiblings(nodeID: store.root.id, toIndex: 0)
        #expect(store.root.children.map(\.id) == [b, a, c, d])
    }

    @Test func reorderRotatesCustomCanvasPositionsAcrossWholeRange() throws {
        let store = BrainstormStore(startEditing: false)
        let first = store.addChild()!
        let second = store.addSibling()!
        let third = store.addSibling()!
        store.setManualOffset(id: first, x: 20, y: -35)
        store.setManualOffset(id: second, x: 90, y: 15)
        store.setManualOffset(id: third, x: -55, y: 70)

        let before = LayoutEngine().layout(root: store.root)
        let beforeRoot = try #require(before.nodes.first { $0.id == store.root.id })
        let beforeFirst = try #require(before.nodes.first { $0.id == first })
        let beforeSecond = try #require(before.nodes.first { $0.id == second })
        let beforeThird = try #require(before.nodes.first { $0.id == third })

        store.reorderAmongSiblings(nodeID: third, toIndex: 0)
        #expect(store.root.children.map(\.id) == [third, first, second])

        let after = LayoutEngine().layout(root: store.root)
        let afterRoot = try #require(after.nodes.first { $0.id == store.root.id })
        let afterFirst = try #require(after.nodes.first { $0.id == first })
        let afterSecond = try #require(after.nodes.first { $0.id == second })
        let afterThird = try #require(after.nodes.first { $0.id == third })

        func relative(_ node: LayoutNode, root: LayoutNode) -> CGPoint {
            CGPoint(x: node.frame.minX - root.frame.minX, y: node.frame.minY - root.frame.minY)
        }
        func isNear(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
            abs(lhs.x - rhs.x) < 0.5 && abs(lhs.y - rhs.y) < 0.5
        }

        #expect(isNear(relative(afterThird, root: afterRoot), relative(beforeFirst, root: beforeRoot)))
        #expect(isNear(relative(afterFirst, root: afterRoot), relative(beforeSecond, root: beforeRoot)))
        #expect(isNear(relative(afterSecond, root: afterRoot), relative(beforeThird, root: beforeRoot)))
    }

    @Test func reorderAmongSiblingsSwapsCustomCanvasPositionsAndIsUndoable() throws {
        let store = BrainstormStore(startEditing: false)
        let a = store.addChild()!
        let b = store.addSibling()!
        let c = store.addSibling()!
        store.rename(id: b, to: "A deliberately wide custom topic")
        store.rename(id: c, to: "Short")
        store.setManualOffset(id: b, x: 120, y: -30)
        store.setManualOffset(id: c, x: -70, y: 55)

        let before = LayoutEngine().layout(root: store.root)
        let beforeRoot = try #require(before.nodes.first { $0.id == store.root.id })
        let beforeB = try #require(before.nodes.first { $0.id == b })
        let beforeC = try #require(before.nodes.first { $0.id == c })

        store.reorderAmongSiblings(nodeID: b, toIndex: 2)
        #expect(store.root.children.map(\.id) == [a, c, b])
        let after = LayoutEngine().layout(root: store.root)
        let afterRoot = try #require(after.nodes.first { $0.id == store.root.id })
        let afterB = try #require(after.nodes.first { $0.id == b })
        let afterC = try #require(after.nodes.first { $0.id == c })

        #expect(abs((afterB.frame.minX - afterRoot.frame.minX) - (beforeC.frame.minX - beforeRoot.frame.minX)) < 0.5)
        #expect(abs((afterB.frame.minY - afterRoot.frame.minY) - (beforeC.frame.minY - beforeRoot.frame.minY)) < 0.5)
        #expect(abs((afterC.frame.minX - afterRoot.frame.minX) - (beforeB.frame.minX - beforeRoot.frame.minX)) < 0.5)
        #expect(abs((afterC.frame.minY - afterRoot.frame.minY) - (beforeB.frame.minY - beforeRoot.frame.minY)) < 0.5)

        store.undo()
        #expect(store.root.children.map(\.id) == [a, b, c])
        let restored = LayoutEngine().layout(root: store.root)
        #expect(restored.nodes.first { $0.id == b }?.frame == beforeB.frame)
        #expect(restored.nodes.first { $0.id == c }?.frame == beforeC.frame)
    }

    @Test func reorderKeepsUnaffectedCustomSiblingInPlace() throws {
        let store = BrainstormStore(startEditing: false)
        _ = store.addChild()!
        let b = store.addSibling()!
        let c = store.addSibling()!
        _ = store.addSibling()
        store.setManualOffset(id: b, x: 95, y: -45)

        let before = LayoutEngine().layout(root: store.root)
        let beforeRoot = try #require(before.nodes.first { $0.id == store.root.id })
        let beforeB = try #require(before.nodes.first { $0.id == b })

        // Only the third and fourth siblings shift; custom-positioned b is outside the range.
        store.reorderAmongSiblings(nodeID: c, toIndex: 3)

        let after = LayoutEngine().layout(root: store.root)
        let afterRoot = try #require(after.nodes.first { $0.id == store.root.id })
        let afterB = try #require(after.nodes.first { $0.id == b })
        #expect(abs((afterB.frame.minX - afterRoot.frame.minX) - (beforeB.frame.minX - beforeRoot.frame.minX)) < 0.5)
        #expect(abs((afterB.frame.minY - afterRoot.frame.minY) - (beforeB.frame.minY - beforeRoot.frame.minY)) < 0.5)
    }

    @Test func siblingIDsAndIndexHelpers() {
        let store = BrainstormStore(startEditing: false)
        let a = store.addChild()!
        let b = store.addSibling()!
        #expect(store.siblingIDs(of: a) == [a, b])
        #expect(store.siblingIndex(of: b) == 1)
        #expect(store.siblingIDs(of: store.root.id).isEmpty)
        #expect(store.siblingIndex(of: store.root.id) == nil)
    }

    @Test func navigationDoesNotFoldOnLeft() {
        let store = BrainstormStore()
        let child = store.addChild()!
        _ = store.addChild(of: child)
        store.select(child)
        #expect(store.node(id: child)?.isExpanded == true)
        store.navigateLeft()
        // BrainstormNode canvas: left moves to parent; fold is ⌥.
        #expect(store.selectedID == store.root.id)
        #expect(store.node(id: child)?.isExpanded == true)
    }

    @Test func foldToggle() {
        let store = BrainstormStore()
        let child = store.addChild()!
        _ = store.addChild(of: child)
        store.select(child)
        store.toggleFoldSelected()
        #expect(store.node(id: child)?.isExpanded == false)
        store.toggleFoldSelected()
        #expect(store.node(id: child)?.isExpanded == true)
    }

    @Test func goToMainAndDeselect() {
        let store = BrainstormStore()
        let child = store.addChild()!
        store.select(child)
        store.goToMainNode()
        #expect(store.selectedID == store.root.id)
        store.deselect()
        #expect(store.selectedID == nil)
    }

    @Test func shiftSelectionTogglesNodesAndNormalSelectionCollapses() {
        let store = BrainstormStore(startEditing: false)
        let a = store.addChild()!
        let b = store.addSibling()!

        store.select(a)
        store.select(b, extending: true)
        #expect(store.selectedIDs == [a, b])
        #expect(store.selectedID == b)

        store.select(a, extending: true)
        #expect(store.selectedIDs == [b])
        #expect(store.selectedID == b)

        store.select(store.root.id, extending: true)
        #expect(store.selectedIDs == [b, store.root.id])
        store.select(a)
        #expect(store.selectedIDs == [a])
        #expect(store.selectedID == a)
    }

    @Test func batchStyleAppliesToSelectionAndUndoRestoresEveryNode() {
        let store = BrainstormStore(startEditing: false)
        let a = store.addChild()!
        let b = store.addSibling()!
        let c = store.addSibling()!
        store.select(a)
        store.select(b, extending: true)

        store.updateStyle { style in
            style.fillHex = "#123456"
            style.textHex = "#F4F4F4"
            style.borderHex = "#FF8800"
            style.borderWidth = 3
            style.shape = .capsule
            style.fontSize = 18
            style.isBold = true
            style.isItalic = true
        }

        for id in [a, b] {
            let style = store.node(id: id)?.style
            #expect(style?.fillHex == "#123456")
            #expect(style?.textHex == "#F4F4F4")
            #expect(style?.borderHex == "#FF8800")
            #expect(style?.borderWidth == 3)
            #expect(style?.shape == .capsule)
            #expect(style?.fontSize == 18)
            #expect(style?.isBold == true)
            #expect(style?.isItalic == true)
        }
        #expect(store.node(id: c)?.style == .default)
        #expect(store.selectedIDs == [a, b])

        store.undo()
        #expect(store.node(id: a)?.style == .default)
        #expect(store.node(id: b)?.style == .default)
        #expect(store.selectedIDs == [a, b])
    }

    @Test func renameAndCodecRoundTrip() throws {
        let store = BrainstormStore()
        store.rename(id: store.root.id, to: "  Hello Map  ")
        #expect(store.root.title == "Hello Map")

        let file = BrainstormFile(root: store.root)
        let data = try BrainstormCodec.encode(file)
        let decoded = try BrainstormCodec.decode(from: data)
        #expect(decoded.root.title == "Hello Map")
        #expect(decoded.version == BrainstormFile.currentVersion)
    }

    @Test func fillLeavesTextAutoForThemeOrContrast() {
        let store = BrainstormStore(startEditing: false)
        // Custom fill stores hex; text stays nil (contrast resolved at render).
        store.setFillColor("#D6EAF8")
        #expect(store.root.style.fillHex == "#D6EAF8")
        #expect(store.root.style.textHex == nil)
        #expect(ColorContrast.contrastingTextHex(forFill: "#D6EAF8") == ColorContrast.darkTextHex)
        #expect(ColorContrast.contrastingTextHex(forFill: "#2C3E50") == ColorContrast.lightTextHex)
        // Clear fill → theme default fill/text at render
        store.setFillColor(nil)
        #expect(store.root.style.fillHex == nil)
        #expect(store.root.style.textHex == nil)
        // Manual text override still works
        store.setFillColor("#D6EAF8")
        store.setTextColor("#1A5276")
        #expect(store.root.style.textHex == "#1A5276")
        // Auto clears override so theme / contrast can apply
        store.setTextColor(nil)
        #expect(store.root.style.textHex == nil)
    }

    @Test func styleMediaAndManualOffsetRoundTrip() throws {
        let store = BrainstormStore(startEditing: false)
        let child = store.addChild()!
        store.select(child)
        store.setFillColor("#D6EAF8")
        store.setShape(.capsule)
        store.setBranchColor("#5DADE2")
        store.setBorderColor("#1B4F72")
        store.setBorderWidth(3)
        store.setEmoji("🎉")
        store.setManualOffset(id: child, x: 40, y: -20)
        store.rename(id: child, to: "Line one\nLine two")

        let data = try BrainstormCodec.encode(BrainstormFile(root: store.root))
        let decoded = try BrainstormCodec.decode(from: data)
        let node = decoded.root.children[0]
        #expect(node.style.fillHex == "#D6EAF8")
        #expect(node.style.shape == .capsule)
        #expect(node.style.branchHex == "#5DADE2")
        #expect(node.style.borderHex == "#1B4F72")
        #expect(node.style.borderWidth == 3)
        #expect(node.media.emoji == "🎉")
        #expect(node.media.sticker == nil)
        #expect(node.offsetX == 40)
        #expect(node.offsetY == -20)
        #expect(node.title == "Line one\nLine two")
    }

    @Test func reselectingEmojiOrStickerClearsThem() {
        let store = BrainstormStore(startEditing: false)
        store.setEmoji("🎯")
        #expect(store.root.media.emoji == "🎯")
        // Same emoji again → clear
        store.setEmoji("🎯")
        #expect(store.root.media.emoji == nil)
        // Explicit clear is a no-op when already empty
        store.setEmoji(nil)
        #expect(store.root.media.emoji == nil)

        store.setEmoji("✨")
        store.setEmoji(nil)
        #expect(store.root.media.emoji == nil)

        store.setSticker("star.fill")
        #expect(store.root.media.sticker == "star.fill")
        store.setSticker("star.fill")
        #expect(store.root.media.sticker == nil)
        store.setSticker("heart.fill")
        #expect(store.root.media.sticker == "heart.fill")
        store.setSticker(nil)
        #expect(store.root.media.sticker == nil)
    }

    @Test func mediaKindsAreMutuallyExclusive() {
        let store = BrainstormStore(startEditing: false)
        store.setEmoji("🎉")
        #expect(store.root.media.emoji == "🎉")
        #expect(store.root.media.sticker == nil)
        #expect(store.root.media.imageBase64 == nil)

        store.setSticker("heart.fill")
        #expect(store.root.media.sticker == "heart.fill")
        #expect(store.root.media.emoji == nil)
        #expect(store.root.media.imageBase64 == nil)

        // Tiny 1×1 PNG
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        store.setImagePNGData(png)
        #expect(store.root.media.imageBase64 != nil)
        #expect(store.root.media.emoji == nil)
        #expect(store.root.media.sticker == nil)

        store.setEmoji("🧠")
        #expect(store.root.media.emoji == "🧠")
        #expect(store.root.media.sticker == nil)
        #expect(store.root.media.imageBase64 == nil)
        #expect(store.root.media.activeKind == .emoji("🧠"))
    }

    @Test func documentEmojisListsUniqueFromTree() {
        let store = BrainstormStore(startEditing: false)
        store.setEmoji("🍎")
        let a = store.addChild()!
        store.select(a)
        store.setEmoji("🍌")
        let b = store.addSibling()!
        store.select(b)
        store.setEmoji("🍎")
        let listed = store.documentEmojis()
        #expect(listed.contains("🍎"))
        #expect(listed.contains("🍌"))
        #expect(listed.filter { $0 == "🍎" }.count == 1)
    }

    @Test func searchSelectsMatchesAndFocusModeTracksBranch() {
        let store = BrainstormStore(startEditing: false)
        store.rename(id: store.root.id, to: "Trip")
        let a = store.addChild()!
        store.rename(id: a, to: "Flights")
        let b = store.addSibling()!
        store.rename(id: b, to: "Hotels")
        let detail = store.addChild(of: a)!
        store.rename(id: detail, to: "Flight status")
        let hotelDetail = store.addChild(of: b)!
        store.rename(id: hotelDetail, to: "Booking")

        store.updateSearchQuery("flight")
        #expect(store.searchMatchIDs.count == 2)
        #expect(store.selectedID == a || store.selectedID == detail)

        // Focus on a leaf: ancestors + leaf; uncle branch stays dimmed
        store.select(detail)
        store.toggleFocusMode()
        #expect(store.isFocusMode)
        var visible = store.focusVisibleIDs()
        #expect(visible.contains(store.root.id))
        #expect(visible.contains(a))
        #expect(visible.contains(detail))
        #expect(!visible.contains(b))
        #expect(!visible.contains(hotelDetail))

        // Focus on a top-level topic: siblings stay bright, sibling children dimmed
        store.select(a)
        visible = store.focusVisibleIDs()
        #expect(visible.contains(store.root.id))
        #expect(visible.contains(a))
        #expect(visible.contains(detail)) // own children
        #expect(visible.contains(b)) // peer at same level
        #expect(!visible.contains(hotelDetail)) // not peer's children
    }

    @Test func manualOffsetAffectsLayoutAndResetClears() {
        let store = BrainstormStore(startEditing: false)
        let child = store.addChild()!
        store.rename(id: child, to: "Moved")
        let before = LayoutEngine().layout(root: store.root)
        let y0 = before.nodes.first { $0.id == child }!.frame.midY

        store.setManualOffset(id: child, x: 0, y: 50)
        let after = LayoutEngine().layout(root: store.root)
        let y1 = after.nodes.first { $0.id == child }!.frame.midY
        #expect(y1 == y0 + 50)

        store.resetPosition(id: child)
        #expect(store.node(id: child)?.hasManualPosition == false)
    }

    @Test func manualLineBreaksIncreaseLayoutHeight() {
        let single = LayoutEngine().layout(root: .root(title: "Hello"))
        let multi = LayoutEngine().layout(root: .root(title: "Hello\nWorld\nAgain"))
        #expect(multi.nodes[0].frame.height > single.nodes[0].frame.height)
        #expect(multi.nodes[0].frame.width >= single.nodes[0].frame.width)
    }

    @Test func liveEditPreservesSpacesBetweenWords() {
        let store = BrainstormStore(startEditing: false)
        store.beginEditing(id: store.root.id, selectAll: false)
        store.updateEditingDraft("Open")
        store.applyTitleLive(id: store.root.id, raw: "Open")
        store.updateEditingDraft("Open ")
        store.applyTitleLive(id: store.root.id, raw: "Open ")
        // Space must survive live apply so the next word can be typed.
        #expect(store.root.title == "Open ")
        #expect(store.editingDraft == "Open ")

        store.updateEditingDraft("Open Source")
        store.applyTitleLive(id: store.root.id, raw: "Open Source")
        store.commitEditing()
        #expect(store.root.title == "Open Source")
        #expect(!store.isEditing)
    }

    @Test func beginEditingAtEndKeepsExistingTitle() {
        let store = BrainstormStore(startEditing: false)
        store.rename(id: store.root.id, to: "Brainstorm")
        store.beginEditing(id: store.root.id, selectAll: false)
        #expect(store.editingDraft == "Brainstorm")
        #expect(store.editingSelectAll == false)
        #expect(store.root.title == "Brainstorm")
    }

    @Test func typeToEditSeedReplacesTitle() {
        let store = BrainstormStore(startEditing: false)
        store.rename(id: store.root.id, to: "Old")
        store.beginEditing(id: store.root.id, seed: "N")
        #expect(store.editingDraft == "N")
        #expect(store.root.title == "N")
        #expect(store.editingSelectAll == false)
    }

    @Test func zoomClampedAndTitlesAcceptNewlines() {
        let store = BrainstormStore(startEditing: true)
        store.setZoom(10)
        #expect(store.zoomScale == 3)
        store.setZoom(0.01)
        #expect(store.zoomScale == 0.25)
        store.zoomReset()
        #expect(store.zoomScale == 1)

        store.beginEditing(id: store.root.id, seed: "Hi")
        store.insertNewlineInTitle()
        #expect(store.editingDraft == "Hi\n")
        #expect(store.root.title == "Hi\n")
    }

    @Test func titlesPreserveNewlinesOnLiveApplyAndCommit() {
        let store = BrainstormStore(startEditing: false)
        store.beginEditing(id: store.root.id, seed: "Line one")
        // Live apply preserves the intentional newline while the second line is typed.
        store.applyTitleLive(id: store.root.id, raw: "Line one\n")
        #expect(store.root.title == "Line one\n")
        store.applyTitleLive(id: store.root.id, raw: "Line one\nLine two")
        #expect(store.root.title == "Line one\nLine two")
        // Commit trims ends.
        store.updateEditingDraft("Line one\nLine two")
        store.commitEditing()
        #expect(store.root.title == "Line one\nLine two")
    }

    @Test func shiftReturnWhileEditingDoesNotCreateANode() {
        let store = BrainstormStore(startEditing: false)
        store.beginEditing(id: store.root.id, seed: "Line one")
        let key = BrainstormKeyRouter.Key(
            keyCode: 36,
            characters: "\r",
            isTab: false,
            isReturn: true,
            isEscape: false,
            isUp: false,
            isDown: false,
            isLeft: false,
            isRight: false,
            isDelete: false
        )
        let modifiers = BrainstormKeyRouter.Modifiers(
            command: false,
            option: false,
            shift: true,
            control: false
        )

        let handledByRouter = BrainstormKeyRouter.handle(
            store: store,
            key: key,
            modifiers: modifiers,
            inTextField: true,
            fileActions: nil
        )
        #expect(!handledByRouter)
        #expect(store.root.children.isEmpty)

        let handledWithoutField = BrainstormKeyRouter.handle(
            store: store,
            key: key,
            modifiers: modifiers,
            inTextField: false,
            fileActions: nil
        )
        #expect(handledWithoutField)
        #expect(store.editingDraft == "Line one\n")
        #expect(store.root.children.isEmpty)
    }

    @Test func decodesLegacyVersion1Documents() throws {
        let json = """
        {"version":1,"root":{"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","isExpanded":true,"children":[]}}
        """
        let file = try BrainstormCodec.decode(from: Data(json.utf8))
        #expect(file.root.title == "Legacy")
        #expect(file.root.style.isDefault)
        #expect(file.root.media.isEmpty)
    }

    @Test func undoRedoAddChild() {
        let store = BrainstormStore(startEditing: false)
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
        let store = BrainstormStore(startEditing: false)
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
        let store = BrainstormStore(startEditing: false)
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
        let store = BrainstormStore(startEditing: false)
        store.deselect()
        #expect(store.selectedID == nil)
        let id = store.ensureSelection()
        #expect(id == store.root.id)
        #expect(store.selectedID == store.root.id)
    }

    @Test func continuousReturnWhileEditingCreatesSiblings() {
        // Keyboard-only capture: type → Return → type → Return (no double-Return).
        let store = BrainstormStore(startEditing: false)
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
        let store = BrainstormStore(startEditing: false)
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
        let store = BrainstormStore(startEditing: false)
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
        let store = BrainstormStore(startEditing: false)
        store.deselect()
        store.navigateDown()
        #expect(store.selectedID == store.root.id)
    }
}

@Suite("BrainstormDocumentEditor")
struct BrainstormDocumentEditorTests {
    @Test func addMoveUpdateAndDeleteUseStableIDs() throws {
        let rootID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        var file = BrainstormFile(root: BrainstormNode(id: rootID, title: "Root"))

        _ = try BrainstormDocumentEditor.addNode(
            to: &file, parentID: rootID, id: firstID, title: "First"
        )
        _ = try BrainstormDocumentEditor.addNode(
            to: &file, parentID: rootID, id: secondID, title: "Second", index: 0
        )
        #expect(file.root.children.map(\.id) == [secondID, firstID])

        try BrainstormDocumentEditor.updateNode(in: &file, id: firstID) {
            $0.title = "Updated"
            $0.style.isBold = true
        }
        try BrainstormDocumentEditor.moveNode(
            in: &file, id: firstID, toParent: secondID, index: 0
        )
        #expect(file.root.children.map(\.id) == [secondID])
        #expect(file.root.children[0].children.map(\.id) == [firstID])
        #expect(BrainstormDocumentEditor.node(in: file, id: firstID)?.title == "Updated")

        let removed = try BrainstormDocumentEditor.deleteNode(in: &file, id: firstID)
        #expect(removed.id == firstID)
        #expect(BrainstormDocumentEditor.node(in: file, id: firstID) == nil)
        try BrainstormDocumentEditor.validate(file)
    }

    @Test func moveRejectsCyclesWithoutMutatingDocument() throws {
        let rootID = UUID()
        let parentID = UUID()
        let childID = UUID()
        var file = BrainstormFile(root: BrainstormNode(
            id: rootID,
            title: "Root",
            children: [BrainstormNode(id: parentID, title: "Parent", children: [
                BrainstormNode(id: childID, title: "Child"),
            ])]
        ))
        let before = file

        #expect(throws: BrainstormDocumentEditError.self) {
            try BrainstormDocumentEditor.moveNode(
                in: &file, id: parentID, toParent: childID
            )
        }
        #expect(file == before)
    }

    @Test func validationReportsDuplicateIDsAndInvalidStyle() {
        let duplicateID = UUID()
        var invalidChild = BrainstormNode(id: duplicateID, title: "Child")
        invalidChild.style.fillHex = "orange"
        let file = BrainstormFile(root: BrainstormNode(
            id: duplicateID,
            title: "Root",
            children: [invalidChild]
        ))

        let issues = BrainstormDocumentEditor.validationIssues(in: file)
        #expect(issues.contains { $0.contains("duplicate node id") })
        #expect(issues.contains { $0.contains("invalid fill color") })
    }

    @Test func multilineTitlesNormalizeAndValidate() throws {
        let rootID = UUID()
        var file = BrainstormFile(root: BrainstormNode(id: rootID, title: "Root"))
        let child = try BrainstormDocumentEditor.addNode(
            to: &file,
            parentID: rootID,
            title: "Line one\r\nLine two"
        )

        #expect(child.title == "Line one\nLine two")
        #expect(BrainstormDocumentEditor.validationIssues(in: file).isEmpty)
        try BrainstormDocumentEditor.validate(file)
    }
}

@Suite("BrainstormExporter", .serialized)
@MainActor
struct BrainstormExporterTests {
    @Test func pngExportProducesDecodableHighResolutionImage() throws {
        let data = try BrainstormExporter.data(
            root: sampleMap,
            theme: .vsCodeLight,
            colorScheme: .light,
            format: .png
        )

        #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let image = try #require(NSBitmapImageRep(data: data))
        let logicalSize = LayoutEngine().layout(root: sampleMap).contentSize
        #expect(image.pixelsWide >= Int(logicalSize.width * 1.9))
        #expect(image.pixelsHigh >= Int(logicalSize.height * 1.9))
        try writeSampleIfRequested(data, named: "brainstorm-export.png")
    }

    @Test func pdfExportProducesOneFullMapPage() throws {
        let data = try BrainstormExporter.data(
            root: sampleMap,
            theme: .vsCodeLight,
            colorScheme: .light,
            format: .pdf
        )

        #expect(data.starts(with: Data("%PDF".utf8)))
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages == 1)
        let page = try #require(document.page(at: 1))
        let pageBounds = page.getBoxRect(.mediaBox)
        let logicalSize = LayoutEngine().layout(root: sampleMap).contentSize
        #expect(abs(pageBounds.width - logicalSize.width) < 1)
        #expect(abs(pageBounds.height - logicalSize.height) < 1)
        try writeSampleIfRequested(data, named: "brainstorm-export.pdf")
    }

    private var sampleMap: BrainstormNode {
        var research = BrainstormNode(
            title: "Research",
            style: NodeStyle(
                fillHex: "#D7ECFF",
                branchHex: "#0078D4",
                shape: .capsule,
                isBold: true
            ),
            media: NodeMedia(emoji: "🔎")
        )
        research.children = [
            BrainstormNode(title: "Customer interviews"),
            BrainstormNode(title: "Market signals"),
        ]

        var launch = BrainstormNode(
            title: "Launch plan",
            style: NodeStyle(
                fillHex: "#FFF0C2",
                branchHex: "#B86E00",
                shape: .diamond,
                isBold: true
            ),
            media: NodeMedia(sticker: "paperplane.fill")
        )
        launch.children = [
            BrainstormNode(title: "Beta"),
            BrainstormNode(title: "Release"),
        ]

        return BrainstormNode(
            title: "Product Strategy",
            children: [research, launch],
            style: NodeStyle(fontSize: 20, isBold: true)
        )
    }

    private func writeSampleIfRequested(_ data: Data, named fileName: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["BRAINSTORM_EXPORT_SAMPLE_DIR"] else {
            return
        }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: directoryURL.appendingPathComponent(fileName), options: .atomic)
    }
}

@Suite("EmojiUsageStore")
@MainActor
struct EmojiUsageStoreTests {
    @Test func shortlistIsRecentThenFrequentNotHardcoded() {
        let suite = "Brainstorm.tests.emoji.\(UUID().uuidString)"
        let history = EmojiUsageStore(suiteName: suite)
        #expect(history.shortlist().isEmpty)

        history.record("🔥")
        history.record("💡")
        history.record("🔥")
        // MRU first
        #expect(history.recent.first == "🔥")
        #expect(history.counts["🔥"] == 2)
        #expect(history.counts["💡"] == 1)
        #expect(history.shortlist().contains("🔥"))
        #expect(history.shortlist().contains("💡"))

        // Document-only emojis fill gaps without being hardcoded defaults
        let list = history.shortlist(documentEmojis: ["🎯", "🔥"])
        #expect(list.contains("🎯"))
        #expect(list.contains("💡"))
        #expect(!list.contains("star.fill"))
    }

    @Test func normalizeKeepsEmojiGrapheme() {
        #expect(EmojiUsageStore.normalize("  🎉  ") == "🎉")
        #expect(EmojiUsageStore.normalize("🎯extra") == "🎯")
        #expect(EmojiUsageStore.normalize("") == "")
    }
}

@Suite("LayoutEngine")
struct LayoutEngineTests {
    @Test func layoutPlacesChildrenToTheRight() {
        var root = BrainstormNode.root(title: "Root")
        root.children = [
            BrainstormNode(title: "A"),
            BrainstormNode(title: "B"),
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

    @Test func mediaWidensNodeHorizontallyButKeepsHeight() {
        // Icons must reserve width so the title is not truncated with "…",
        // but must not change vertical padding / height.
        let engine = LayoutEngine()
        var plainRoot = BrainstormNode.root(title: "R")
        plainRoot.children = [BrainstormNode(title: "Open Source")]
        var iconRoot = BrainstormNode.root(title: "R")
        var withIcon = BrainstormNode(title: "Open Source")
        withIcon.media.emoji = "🎉"
        iconRoot.children = [withIcon]

        let plainNode = engine.layout(root: plainRoot).nodes.first { $0.title == "Open Source" }!
        let iconNode = engine.layout(root: iconRoot).nodes.first { $0.title == "Open Source" }!
        #expect(iconNode.frame.width > plainNode.frame.width)
        #expect(iconNode.frame.width >= plainNode.frame.width + engine.mediaSlot)
        #expect(plainNode.frame.height == iconNode.frame.height)
    }

    @Test func rootWithMediaFitsFullTitleWithoutTruncation() {
        // Regression: "Brainstorm app" + logo was laid out title-only-wide → "Brainstorm…".
        let title = "Brainstorm app"
        let plain = LayoutEngine().layout(root: .root(title: title)).nodes[0]
        var withMedia = BrainstormNode.root(title: title)
        withMedia.media.emoji = "🧠"
        let icon = LayoutEngine().layout(root: withMedia).nodes[0]
        #expect(icon.frame.width > plain.frame.width)
        #expect(icon.frame.height == plain.frame.height)
    }

    @Test func negativeManualOffsetShiftsContentSoEdgesStayInBounds() {
        // Free-position upward used to leave frames at y < 0 while EdgeCanvas clipped at 0,
        // so branch lines vanished even though the node still painted via `.position`.
        var root = BrainstormNode.root(title: "Root")
        var child = BrainstormNode(title: "Up")
        child.offsetX = 0
        child.offsetY = -120
        root.children = [child]

        let engine = LayoutEngine()
        let result = engine.layout(root: root)
        #expect(result.nodes.allSatisfy { $0.frame.minX >= 0 && $0.frame.minY >= 0 })
        #expect(result.edges.allSatisfy { edge in
            edge.from.x >= 0 && edge.from.y >= 0 && edge.to.x >= 0 && edge.to.y >= 0
        })
        let up = result.nodes.first { $0.title == "Up" }!
        #expect(up.frame.minY >= engine.canvasPadding - 0.5)
        #expect(result.contentSize.height >= up.frame.maxY)
        #expect(result.contentSize.width >= up.frame.maxX)
    }

    @Test func collapsedHidesDescendants() {
        var root = BrainstormNode.root(title: "Root")
        var child = BrainstormNode(title: "Child", isExpanded: true)
        child.children = [BrainstormNode(title: "Grand")]
        child.isExpanded = false
        root.children = [child]

        let result = LayoutEngine().layout(root: root)
        #expect(result.nodes.map(\.title) == ["Root", "Child"])
        #expect(result.edges.count == 1)
    }

    @Test func foldDoesNotMoveSiblingFrames() {
        // Hide/show must not reflow other branches — positions stay put in the window.
        var root = BrainstormNode.root(title: "Root")
        var branch = BrainstormNode(title: "Branch", isExpanded: true)
        branch.children = [
            BrainstormNode(title: "B1"),
            BrainstormNode(title: "B2"),
            BrainstormNode(title: "B3"),
        ]
        let sibling = BrainstormNode(title: "Sibling")
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
        // Must be wider than a short root; still within the configured cap.
        #expect(longNode.frame.width > shortNode.frame.width)
        #expect(longNode.frame.width <= LayoutEngine().maxNodeWidth)
    }

    @Test func longCommittedTitlesWrapBeforeTruncating() {
        let engine = LayoutEngine()
        let short = engine.layout(root: .root(title: "Short title")).nodes[0]
        let mediumTitle = Array(repeating: "Valencia summer adventure", count: 4).joined(separator: " ")
        let medium = engine.layout(root: .root(title: mediumTitle)).nodes[0]
        let veryLongTitle = Array(repeating: "Valencia summer adventure", count: 20).joined(separator: " ")
        let veryLong = engine.layout(root: .root(title: veryLongTitle)).nodes[0]

        #expect(medium.frame.width <= engine.maxNodeWidth)
        #expect(medium.frame.height > short.frame.height)
        #expect(veryLong.frame.height >= medium.frame.height)
        #expect(veryLong.frame.height <= medium.frame.height * CGFloat(LayoutEngine.displayLineLimit))
    }

    @Test func liveEditingDraftWidensNodeWithoutWaitingForTreeTitle() {
        // Regression: while typing, layout used the old title for ~180ms → "…".
        let engine = LayoutEngine()
        let root = BrainstormNode.root(title: "Hi")
        let committed = engine.layout(root: root).nodes[0]

        let live = engine.layout(
            root: root,
            liveTitle: .init(id: root.id, title: "Highlight single node")
        ).nodes[0]

        #expect(live.frame.width > committed.frame.width)
        // Caret pad only applies while editing.
        #expect(live.frame.width >= committed.frame.width + engine.editingCaretPad - 0.5)

        // Trailing space while typing must also expand the card (past min width).
        let withSpace = engine.layout(
            root: root,
            liveTitle: .init(id: root.id, title: "Keyboard Navigation ")
        ).nodes[0]
        let withoutSpace = engine.layout(
            root: root,
            liveTitle: .init(id: root.id, title: "Keyboard Navigation")
        ).nodes[0]
        #expect(withSpace.frame.width > withoutSpace.frame.width)
    }
}

@Suite("AppTheme")
@MainActor
struct AppThemeTests {
    @Test func catalogHasUniqueIDs() {
        let ids = AppTheme.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(AppTheme.all.count >= 10)
        #expect(AppTheme.theme(id: "dracula").name == "Dracula")
        #expect(AppTheme.theme(id: "missing").id == AppTheme.system.id)
    }

    @Test func systemThemeTracksColorScheme() {
        #expect(AppTheme.system.isSystem)
        #expect(AppTheme.system.resolvesAsDark(in: .dark))
        #expect(!AppTheme.system.resolvesAsDark(in: .light))
        // Fixed palettes ignore the live color scheme.
        #expect(AppTheme.dracula.resolvesAsDark(in: .light))
        #expect(!AppTheme.vsCodeLight.resolvesAsDark(in: .dark))
    }

    @Test func applyThemeIsUndoableAndMarksDirty() {
        let previous = AppTheme.preferredDefaultID
        defer { AppTheme.setPreferredDefault(previous) }
        AppTheme.setPreferredDefault(AppTheme.system.id)

        let store = BrainstormStore(startEditing: false)
        #expect(store.themeID == AppTheme.system.id)
        #expect(!store.isDirty)

        store.applyTheme(AppTheme.oneDark.id)
        #expect(store.themeID == AppTheme.oneDark.id)
        #expect(store.theme.name == "One Dark")
        #expect(store.isDirty)
        #expect(AppTheme.preferredDefaultID == AppTheme.oneDark.id)

        store.undo()
        #expect(store.themeID == AppTheme.system.id)
        // Preference stays on the last selected theme (default for new files).
        #expect(AppTheme.preferredDefaultID == AppTheme.oneDark.id)

        store.redo()
        #expect(store.themeID == AppTheme.oneDark.id)
    }

    @Test func themeSurvivesEncodeDecode() throws {
        let root = BrainstormNode.root(title: "Themed")
        let file = BrainstormFile(root: root, themeID: AppTheme.tokyoNight.id)
        let data = try BrainstormCodec.encode(file)
        let decoded = try BrainstormCodec.decode(from: data)
        #expect(decoded.themeID == AppTheme.tokyoNight.id)
        #expect(decoded.root.title == "Themed")
    }

    @Test func newDocumentKeepsThemePreference() {
        let previous = AppTheme.preferredDefaultID
        defer { AppTheme.setPreferredDefault(previous) }
        AppTheme.setPreferredDefault(AppTheme.system.id)

        let store = BrainstormStore(startEditing: false)
        store.applyTheme(AppTheme.dracula.id)
        store.addChild()
        store.newDocument()
        #expect(store.themeID == AppTheme.dracula.id)
        #expect(store.root.children.isEmpty)
        #expect(AppTheme.preferredDefaultID == AppTheme.dracula.id)
    }

    @Test func selectedThemeBecomesDefaultForNewWindows() throws {
        let previous = AppTheme.preferredDefaultID
        defer { AppTheme.setPreferredDefault(previous) }
        AppTheme.setPreferredDefault(AppTheme.system.id)

        let store = BrainstormStore(startEditing: false)
        store.applyTheme(AppTheme.tokyoNight.id)
        #expect(AppTheme.preferredDefaultID == AppTheme.tokyoNight.id)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainstormThemePref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = DocumentSession(supportDirectory: dir)
        let desc = session.registerNewDocument(displayName: "Fresh")
        let payload = session.restorePayload(for: desc.id)
        #expect(payload.themeID == AppTheme.tokyoNight.id)

        let freshStore = BrainstormStore(startEditing: false)
        #expect(freshStore.themeID == AppTheme.tokyoNight.id)
    }

    @Test func themeResolvesFillTextBranchAndRemapsOverrides() {
        let dark = AppTheme.oneDark
        let next = AppTheme.dracula
        #expect(dark.resolvedFillHex(style: .default, isRoot: true) == dark.rootFill)
        #expect(dark.resolvedFillHex(style: .default, isRoot: false) == dark.nodeFill)
        #expect(dark.resolvedBranchHex(style: .default) == dark.branch)

        // Custom override wins until remapped.
        let styled = NodeStyle(fillHex: dark.rootFill, branchHex: dark.branch)
        #expect(dark.resolvedFillHex(style: styled, isRoot: true) == dark.rootFill)

        let remappedFill = AppTheme.remapLinkedHex(styled.fillHex, from: dark, to: next)
        let remappedBranch = AppTheme.remapLinkedHex(styled.branchHex, from: dark, to: next)
        #expect(remappedFill == next.rootFill)
        #expect(remappedBranch == next.branch)

        // True custom hex is left alone.
        #expect(AppTheme.remapLinkedHex("#FF00AA", from: dark, to: next) == "#FF00AA")

        let store = BrainstormStore(startEditing: false)
        store.applyTheme(AppTheme.oneDark.id)
        store.setFillColor(AppTheme.oneDark.rootFill)
        store.setBranchColor(AppTheme.oneDark.branch)
        store.applyTheme(AppTheme.dracula.id)
        #expect(store.root.style.fillHex == AppTheme.dracula.rootFill)
        #expect(store.root.style.branchHex == AppTheme.dracula.branch)
        #expect(store.themeID == AppTheme.dracula.id)
        // Nil style colors stay nil and resolve from the active theme.
        store.setFillColor(nil)
        store.setBranchColor(nil)
        #expect(store.theme.resolvedFillHex(style: store.root.style, isRoot: true)
                == AppTheme.dracula.rootFill)
        #expect(store.theme.resolvedBranchHex(style: store.root.style)
                == AppTheme.dracula.branch)
    }

    @Test func nonSystemThemesExposePaletteHexes() {
        for theme in AppTheme.all where !theme.isSystem {
            #expect(!theme.canvasBackground.isEmpty)
            #expect(!theme.nodeFill.isEmpty)
            #expect(!theme.edge.isEmpty)
            #expect(theme.defaultFill(isRoot: true) != nil)
            #expect(theme.defaultText(isRoot: false) != nil)
        }
        #expect(AppTheme.system.defaultFill(isRoot: true) == nil)
    }
}

@Suite("DocumentSession")
@MainActor
struct DocumentSessionTests {
    private func tempSession() throws -> (DocumentSession, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainstormSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DocumentSession(supportDirectory: dir), dir)
    }

    @Test func registerNewDocumentWritesAutosaveAndSession() throws {
        let (session, dir) = try tempSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let desc = session.registerNewDocument(displayName: "Trip")
        #expect(session.state.openDocuments.map(\.id) == [desc.id])
        #expect(session.state.activeDocumentID == desc.id)
        #expect(session.hasAutosave(for: desc.id))
        #expect(FileManager.default.fileExists(atPath: session.sessionFileURL.path))

        let reloaded = DocumentSession(supportDirectory: dir)
        #expect(reloaded.state.openDocuments.map(\.id) == [desc.id])
        #expect(reloaded.launchDocumentID() == desc.id)
    }

    @Test func inactiveAutosaveDoesNotReplaceExplicitActiveDocument() throws {
        let (session, dir) = try tempSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = session.registerNewDocument(displayName: "A")
        let b = session.registerNewDocument(displayName: "B")
        session.setActive(a.id)
        #expect(session.launchDocumentID() == a.id)

        session.touch(id: b.id, displayName: "B-newer")
        #expect(session.launchDocumentID() == a.id)

        let backgroundAutosave = BrainstormFile(root: .root(title: "B autosave"))
        try session.writeAutosave(file: backgroundAutosave, for: b.id)
        #expect(session.state.activeDocumentID == a.id)

        let extras = session.additionalDocumentIDsToRestore(primary: a.id)
        #expect(extras == [b.id])
    }

    @Test func repeatedFileOpenResolvesToExistingDocument() throws {
        let (session, dir) = try tempSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("Already Open.bs")
        try Data("{}".utf8).write(to: fileURL)
        let document = session.registerNewDocument(displayName: "Already Open")
        session.updateFileURL(document.id, url: fileURL)

        #expect(session.documentID(forFileURL: fileURL) == document.id)
        #expect(session.documentID(forFileURL: fileURL.standardizedFileURL) == document.id)
        #expect(session.documentID(forFileURL: dir.appendingPathComponent("Different.bs")) == nil)
    }

    @Test func documentOpenLaunchSkipsRestoringOtherSessionWindows() throws {
        let (session, dir) = try tempSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = session.registerNewDocument(displayName: "A")
        let b = session.registerNewDocument(displayName: "B")
        let c = session.registerNewDocument(displayName: "C")
        #expect(session.additionalDocumentIDsToRestore(primary: c.id).count == 2)

        // Finder double-click while launching: only open the requested file.
        session.beginDocumentOpenLaunch()
        #expect(session.suppressSessionWindowRestore)
        #expect(session.consumeReplacePrimaryForExternalOpen())
        #expect(session.additionalDocumentIDsToRestore(primary: c.id).isEmpty)

        session.pruneSession(keeping: [c.id])
        #expect(session.state.openDocuments.map(\.id) == [c.id])
        #expect(session.state.activeDocumentID == c.id)
        // A/B no longer restored on next launch of this session snapshot.
        #expect(!session.state.openDocuments.contains(where: { $0.id == a.id || $0.id == b.id }))
    }

    @Test func autosaveSurvivesUnsavedEditsOnRestore() throws {
        let (session, dir) = try tempSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let desc = session.registerNewDocument()
        var root = BrainstormNode.root(title: "Unsaved Map")
        root.children = [BrainstormNode(title: "Child")]
        let file = BrainstormFile(root: root, themeID: AppTheme.dracula.id)
        try session.writeAutosave(file: file, for: desc.id)

        // Mark dirty revisions like a real edit would after autosave.
        session.updateDirtyState(id: desc.id, isDirty: true, contentRevision: 1, savedRevision: 0)

        let payload = session.restorePayload(for: desc.id)
        #expect(payload.root.title == "Unsaved Map")
        #expect(payload.root.children.map(\.title) == ["Child"])
        #expect(payload.themeID == AppTheme.dracula.id)
        #expect(payload.isDirty)
        #expect(payload.fileURL == nil)
    }

    @Test func freshUntitledRestoreIsNotDirty() throws {
        let (session, dir) = try tempSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let desc = session.registerNewDocument(displayName: "Fresh")
        let payload = session.restorePayload(for: desc.id)
        #expect(!payload.isDirty)
        #expect(payload.fileURL == nil)
        #expect(payload.root.children.isEmpty)
    }

    @Test func storeRestoreAndPerformAutosaveRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainstormStoreAutosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Isolate from shared session by writing through a local DocumentSession,
        // then verify BrainstormStore's snapshot API.
        let session = DocumentSession(supportDirectory: dir)
        let desc = session.registerNewDocument()

        let store = BrainstormStore(documentID: desc.id, startEditing: false)
        store.rename(id: store.root.id, to: "Autosaved")
        let snap = store.autosaveSnapshot()
        try session.writeAutosave(file: snap, for: desc.id)

        let restored = session.restorePayload(for: desc.id)
        #expect(restored.root.title == "Autosaved")

        let store2 = BrainstormStore(
            documentID: desc.id,
            root: restored.root,
            themeID: restored.themeID,
            fileURL: restored.fileURL,
            isDirty: restored.isDirty,
            startEditing: false
        )
        #expect(store2.root.title == "Autosaved")
        #expect(store2.documentID == desc.id)
    }

    @Test func autosaveSnapshotIncludesLiveEditDraft() {
        let store = BrainstormStore(startEditing: true)
        store.updateEditingDraft("Half typed")
        let snap = store.autosaveSnapshot()
        #expect(snap.root.title == "Half typed")
    }

    @Test func recentDocumentsNoteIsMRUAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainstormRecents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storage = dir.appendingPathComponent("recents.json")
        let recents = RecentDocuments(storageURL: storage)
        recents.maxCount = 3

        let a = dir.appendingPathComponent("Alpha.bs")
        let b = dir.appendingPathComponent("Beta.bs")
        let c = dir.appendingPathComponent("Gamma.bs")
        let d = dir.appendingPathComponent("Delta.bs")
        for url in [a, b, c, d] {
            try Data("{}".utf8).write(to: url)
        }

        recents.note(url: a)
        recents.note(url: b)
        recents.note(url: c)
        #expect(recents.items.map(\.menuTitle) == ["Gamma", "Beta", "Alpha"])

        // Re-noting Alpha moves it to front; Delta pushes Alpha out (max 3).
        recents.note(url: a)
        #expect(recents.items.map(\.menuTitle) == ["Alpha", "Gamma", "Beta"])
        recents.note(url: d)
        #expect(recents.items.map(\.menuTitle) == ["Delta", "Alpha", "Gamma"])
        #expect(recents.items.count == 3)

        let reloaded = RecentDocuments(storageURL: storage)
        #expect(reloaded.items.map(\.menuTitle) == ["Delta", "Alpha", "Gamma"])
        #expect(reloaded.resolveURL(for: reloaded.items[0])?.lastPathComponent == "Delta.bs")

        reloaded.clear()
        #expect(reloaded.items.isEmpty)
    }
}

@Suite("Text exports")
struct BrainstormTextExporterTests {
    private var root: BrainstormNode {
        var hidden = BrainstormNode(title: "Hidden [task]")
        hidden.children = [BrainstormNode(title: "Final")]
        return BrainstormNode(
            title: "Roadmap & \"Launch\"",
            isExpanded: true,
            children: [
                BrainstormNode(
                    title: "Write *docs*\nReview <copy>",
                    isExpanded: false,
                    children: [hidden]
                ),
                BrainstormNode(title: "Ship")
            ]
        )
    }

    @Test func markdownRepeatsRootAsHeadingAndTopLevelBullet() {
        let output = BrainstormTextExporter.string(root: root, format: .markdown)

        #expect(output == """
        # Roadmap & "Launch"

        - Roadmap & "Launch"
            - Write \\*docs\\*<br>Review &lt;copy&gt;
                - Hidden \\[task\\]
                    - Final
            - Ship

        """)
    }

    @Test func mermaidUsesQuotedLabelsAndIncludesCollapsedDescendants() {
        let output = BrainstormTextExporter.string(root: root, format: .mermaid)

        #expect(output == """
        mindmap
          n0["Roadmap &amp; &quot;Launch&quot;"]
            n1["Write *docs*<br/>Review &lt;copy&gt;"]
              n2["Hidden [task]"]
                n3["Final"]
            n4["Ship"]

        """)
    }

    @Test func plantUMLUsesNativeMindmapDepthAndIncludesCollapsedDescendants() {
        let output = BrainstormTextExporter.string(root: root, format: .plantuml)

        #expect(output == """
        @startmindmap
        * Roadmap & "Launch"
        ** Write *docs*\\nReview ~<copy~>
        *** Hidden [task]
        **** Final
        ** Ship
        @endmindmap

        """)
    }

    @Test func textFormatsUseExpectedFileExtensions() {
        #expect(BrainstormExportFormat.markdown.fileExtension == "md")
        #expect(BrainstormExportFormat.mermaid.fileExtension == "mmd")
        #expect(BrainstormExportFormat.plantuml.fileExtension == "puml")
    }
}

@Suite("ExternalFileChangePolicy")
struct ExternalFileChangePolicyTests {
    @Test func unchangedBytesDoNothing() {
        let data = Data("same".utf8)
        #expect(ExternalFileChangePolicy.action(
            previousData: data,
            currentData: data,
            hasUnsavedChanges: false
        ) == .unchanged)
    }

    @Test func cleanDocumentReloadsChangedBytes() {
        #expect(ExternalFileChangePolicy.action(
            previousData: Data("old".utf8),
            currentData: Data("new".utf8),
            hasUnsavedChanges: false
        ) == .reload)
    }

    @Test func dirtyDocumentRequiresConfirmation() {
        #expect(ExternalFileChangePolicy.action(
            previousData: Data("old".utf8),
            currentData: Data("new".utf8),
            hasUnsavedChanges: true
        ) == .askBeforeReloading)
    }
}
