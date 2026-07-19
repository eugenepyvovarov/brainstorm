import AppKit
import Foundation
import Testing
@testable import BrainstormFeature

@Suite("Native presentation regressions")
@MainActor
struct PresentationRegressionTests {
    @Test func everyContextNodeResolvesToItsTitleStep() throws {
        let root = BrainstormNode(
            title: "Root",
            children: [
                BrainstormNode(
                    title: "First branch",
                    children: [
                        BrainstormNode(
                            title: "Deep leaf",
                            note: NodeNote(bodyMarkdown: "Leaf note")
                        ),
                    ],
                    note: NodeNote(bodyMarkdown: "Branch note")
                ),
                BrainstormNode(title: "Far sibling"),
            ],
            note: NodeNote(bodyMarkdown: "Root note")
        )
        let sequence = PresentationSequence(root: root)
        let plan = PresentationNavigationPlan(sequence: sequence)

        for itemIndex in sequence.items.indices {
            let stepIndex = try #require(
                plan.nodeStepIndex(forItem: itemIndex)
            )
            #expect(plan[stepIndex].itemIndex == itemIndex)
            #expect(plan[stepIndex].nodeID == sequence[itemIndex].id)
            #expect(plan[stepIndex].face == .node)
        }

        let farSiblingIndex = sequence.items.index(
            before: sequence.items.endIndex
        )
        #expect(
            plan.nodeStepIndex(
                forAdjacentItem: farSiblingIndex,
                relativeTo: 0
            ) == nil
        )
        #expect(plan.nodeStepIndex(forItem: farSiblingIndex) != nil)
    }

    @Test func cachedNeighborMetadataPreservesZoomPolicy() {
        let rootID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let nodes = [
            PresentationNeighborZoomPolicy.Node(
                id: rootID,
                parentID: nil,
                siblingIndex: 0,
                frame: CGRect(x: 0, y: 80, width: 120, height: 60)
            ),
            PresentationNeighborZoomPolicy.Node(
                id: firstID,
                parentID: rootID,
                siblingIndex: 0,
                frame: CGRect(x: 220, y: 0, width: 100, height: 50)
            ),
            PresentationNeighborZoomPolicy.Node(
                id: secondID,
                parentID: rootID,
                siblingIndex: 1,
                frame: CGRect(x: 220, y: 140, width: 100, height: 50)
            ),
        ]
        let context = PresentationNeighborZoomPolicy.Context(nodes: nodes)
        let viewport = CGSize(width: 1_000, height: 700)

        for node in nodes {
            let uncached = PresentationNeighborZoomPolicy.magnification(
                base: 5,
                currentID: node.id,
                nodes: nodes,
                viewportSize: viewport,
                controlsAtBottom: false
            )
            let cached = PresentationNeighborZoomPolicy.magnification(
                base: 5,
                currentID: node.id,
                context: context,
                viewportSize: viewport,
                controlsAtBottom: false
            )
            #expect(cached == uncached)
        }
    }

    @Test func sequenceCachesIndicesAndLayoutGeometryByNodeID() throws {
        let leaf = BrainstormNode(title: "Leaf")
        let child = BrainstormNode(title: "Child", children: [leaf])
        let root = BrainstormNode(title: "Root", children: [child])
        let layout = LayoutEngine().layout(
            root: root,
            placementPolicy: .allDescendants
        )
        let sequence = PresentationSequence(root: root, layout: layout)

        let leafIndex = try #require(sequence.index(of: leaf.id))
        let layoutNode = try #require(
            layout.nodes.first { $0.id == leaf.id }
        )
        #expect(sequence[leafIndex].id == leaf.id)
        #expect(sequence.layoutFrame(for: leaf.id) == layoutNode.frame)
        #expect(
            sequence.layoutCenter(for: leaf.id)
                == CGPoint(
                    x: layoutNode.frame.midX,
                    y: layoutNode.frame.midY
                )
        )
        #expect(sequence.index(of: UUID()) == nil)
    }

    @Test func inlineWebPlayerKeepsOnlyItsMediaSpaceShortcut() {
        for keyCode: UInt16 in [123, 124, 115, 119, 45, 53] {
            #expect(
                presentationShouldHandleKeyboardAction(
                    keyCode: keyCode,
                    webContentContext: .focusedInline
                )
            )
        }
        #expect(
            !presentationShouldHandleKeyboardAction(
                keyCode: 49,
                webContentContext: .focusedInline
            )
        )
        #expect(
            presentationShouldHandleKeyboardAction(
                keyCode: 49,
                webContentContext: .none
            )
        )
    }

    @Test func fullscreenWebPlayerReceivesEscapeAndNavigationKeys() {
        for keyCode: UInt16 in [123, 124, 115, 119, 45, 53] {
            #expect(
                !presentationShouldHandleKeyboardAction(
                    keyCode: keyCode,
                    webContentContext: .elementFullscreen
                )
            )
        }
    }
}
