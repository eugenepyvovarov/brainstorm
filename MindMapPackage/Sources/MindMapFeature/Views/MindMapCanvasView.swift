import AppKit
import SwiftUI

struct MindMapCanvasView: View {
    @Bindable var store: MindMapStore
    var focusedNodeID: FocusState<UUID?>.Binding

    @State private var dropTargetID: UUID?
    /// Canvas pan (content offset). Drag empty space or use the scroll wheel / trackpad.
    @State private var panOffset: CGSize = .zero
    @State private var panDragOrigin: CGSize = .zero
    @State private var isPanning = false
    @State private var viewportSize: CGSize = .zero
    @State private var didCenterInitially = false
    /// When true, selection changes won't auto-pan (user is dragging the canvas).
    @State private var suppressAutoCenter = false

    private let engine = LayoutEngine()

    var body: some View {
        let layout = engine.layout(root: store.root)
        // Prefer the node being edited, else the selection — keeps keyboard focus on-screen.
        let focusTarget = store.editingID ?? store.selectedID

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Full-viewport layer: drag empty space to pan; click ends editing.
                Color(nsColor: .textBackgroundColor)
                    .contentShape(Rectangle())
                    .gesture(canvasPanGesture)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            store.canvasBackgroundClicked()
                        }
                    )
                    .onHover { hovering in
                        guard !isPanning else { return }
                        if hovering {
                            NSCursor.openHand.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }

                // Document layer: no full-size frame, so empty space hits the pan background.
                // `.position` places nodes in document coords; offset pans the whole map.
                EdgeCanvas(edges: layout.edges)
                    .frame(width: layout.contentSize.width, height: layout.contentSize.height)
                    .allowsHitTesting(false)
                    .offset(x: panOffset.width, y: panOffset.height)

                ForEach(layout.nodes) { node in
                    MindNodeView(
                        layoutNode: node,
                        isRoot: node.id == store.root.id,
                        isSelected: store.selectedID == node.id,
                        isEditing: store.editingID == node.id,
                        isDropTarget: dropTargetID == node.id,
                        editSeed: store.editingID == node.id ? store.editingSeed : nil,
                        focusToken: focusedNodeID,
                        onSelect: { store.select(node.id) },
                        onBeginEdit: { store.beginEditing(id: node.id) },
                        onCommitEdit: { store.commitEditing() },
                        onCancelEdit: { store.cancelEditing() },
                        onDraftChange: { store.updateEditingDraft($0) },
                        onLiveTitle: { store.applyTitleLive(id: node.id, raw: $0) },
                        onToggleExpand: { store.toggleExpanded(id: node.id) },
                        onAddChild: {
                            store.select(node.id)
                            _ = store.addChild(of: node.id)
                        },
                        onDelete: {
                            store.select(node.id)
                            store.deleteSelected()
                        },
                        onDeleteSingle: {
                            store.select(node.id)
                            store.deleteSingleNode()
                        },
                        onDropNode: { draggedID in
                            guard draggedID != node.id else { return false }
                            guard !store.isDescendant(node.id, of: draggedID) else { return false }
                            store.rewire(nodeID: draggedID, onto: node.id)
                            return true
                        },
                        onDropTargeted: { targeted in
                            if targeted {
                                dropTargetID = node.id
                            } else if dropTargetID == node.id {
                                dropTargetID = nil
                            }
                        }
                    )
                    .position(
                        x: node.frame.midX + panOffset.width,
                        y: node.frame.midY + panOffset.height
                    )
                }
            }
            .clipped()
            .background(Color(nsColor: .textBackgroundColor))
            .background(
                ScrollWheelMonitor { deltaX, deltaY in
                    // Don't pan while typing a title.
                    guard store.editingID == nil else { return }
                    panOffset.width += deltaX
                    panOffset.height += deltaY
                    panDragOrigin = panOffset
                    suppressAutoCenter = true
                }
            )
            .onAppear {
                viewportSize = geo.size
                if !didCenterInitially {
                    didCenterInitially = true
                    centerOn(focusTarget, in: layout, viewport: geo.size, animated: false)
                }
            }
            .onChange(of: geo.size) { _, newSize in
                viewportSize = newSize
            }
            .onChange(of: focusTarget) { _, newID in
                // Keyboard selection / new nodes: gently keep focus on-screen.
                // Fold/unfold does NOT change focusTarget and must not re-pan the map.
                guard !suppressAutoCenter, !isPanning else { return }
                ensureVisible(newID, in: layout, viewport: geo.size, animated: true)
            }
        }
        // Keep FocusState in sync; AppKit field in MindNodeView owns real first-responder.
        .onChange(of: store.editingID) { _, newID in
            focusedNodeID.wrappedValue = nil
            guard let newID else { return }
            DispatchQueue.main.async {
                focusedNodeID.wrappedValue = newID
            }
        }
    }

    // MARK: - Pan

    private var canvasPanGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if !isPanning {
                    isPanning = true
                    suppressAutoCenter = true
                    panDragOrigin = panOffset
                    NSCursor.closedHand.set()
                }
                panOffset = CGSize(
                    width: panDragOrigin.width + value.translation.width,
                    height: panDragOrigin.height + value.translation.height
                )
            }
            .onEnded { _ in
                isPanning = false
                panDragOrigin = panOffset
                NSCursor.openHand.set()
            }
    }

    /// Center a node in the viewport (initial open only).
    private func centerOn(
        _ nodeID: UUID?,
        in layout: LayoutResult,
        viewport: CGSize,
        animated: Bool
    ) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        guard let nodeID,
              let node = layout.nodes.first(where: { $0.id == nodeID })
        else { return }

        let target = CGSize(
            width: viewport.width / 2 - node.frame.midX,
            height: viewport.height / 2 - node.frame.midY
        )
        applyPan(target, animated: animated)
    }

    /// Only pan if the node is outside a comfortable margin — never jump the whole map on fold.
    private func ensureVisible(
        _ nodeID: UUID?,
        in layout: LayoutResult,
        viewport: CGSize,
        animated: Bool
    ) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        guard let nodeID,
              let node = layout.nodes.first(where: { $0.id == nodeID })
        else { return }

        let screenX = node.frame.midX + panOffset.width
        let screenY = node.frame.midY + panOffset.height
        let margin: CGFloat = 48
        var next = panOffset

        if screenX < margin {
            next.width += margin - screenX
        } else if screenX > viewport.width - margin {
            next.width -= screenX - (viewport.width - margin)
        }
        if screenY < margin {
            next.height += margin - screenY
        } else if screenY > viewport.height - margin {
            next.height -= screenY - (viewport.height - margin)
        }

        guard next != panOffset else { return }
        applyPan(next, animated: animated)
    }

    private func applyPan(_ target: CGSize, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                panOffset = target
                panDragOrigin = target
            }
        } else {
            panOffset = target
            panDragOrigin = target
        }
    }
}

// MARK: - Trackpad / mouse-wheel → pan

/// Local scroll-wheel monitor so trackpad/mouse wheel pans even when SwiftUI owns hit-testing.
private struct ScrollWheelMonitor: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        nsView.onScroll = onScroll
    }
}

private final class ScrollWheelView: NSView {
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    nonisolated(unsafe) private var monitor: Any?

    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            install()
        } else {
            remove()
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window == self.window else { return event }
            // Let the title field keep its own scroll/gesture behavior while editing.
            if self.window?.firstResponder is NSTextView
                || self.window?.firstResponder is NSTextField
            {
                return event
            }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return event }
            if Thread.isMainThread {
                self.onScroll?(dx, dy)
            } else {
                DispatchQueue.main.async { self.onScroll?(dx, dy) }
            }
            return nil
        }
    }

    private func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private struct EdgeCanvas: View, Equatable {
    let edges: [LayoutEdge]

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                var path = Path()
                let midX = (edge.from.x + edge.to.x) / 2
                path.move(to: edge.from)
                path.addCurve(
                    to: edge.to,
                    control1: CGPoint(x: midX, y: edge.from.y),
                    control2: CGPoint(x: midX, y: edge.to.y)
                )
                context.stroke(
                    path,
                    with: .color(Color.secondary.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
            }
        }
    }
}
