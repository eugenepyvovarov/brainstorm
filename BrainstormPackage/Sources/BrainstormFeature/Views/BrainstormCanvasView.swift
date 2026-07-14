import AppKit
import SwiftUI

struct BrainstormCanvasView: View {
    // MARK: - Inputs
    @Bindable var store: BrainstormStore
    var focusedNodeID: FocusState<UUID?>.Binding

    // MARK: - State
    @State private var dropTargetID: UUID?
    /// Sibling reorder insertion while free-dragging (no ⌘).
    @State private var reorderTarget: SiblingReorderTarget?
    @State private var panOffset: CGSize = .zero
    @State private var panDragOrigin: CGSize = .zero
    @State private var isPanning = false
    @State private var viewportSize: CGSize = .zero
    @State private var didCenterInitially = false
    /// While true, selection changes do not auto-pan. Cleared after gestures end
    /// so keyboard navigation can re-center again.
    @State private var suppressAutoCenter = false
    /// In-flight free-position drag (document points). Store is NOT mutated until end.
    @State private var freeDrag: FreeDragSession?
    @State private var magnificationBaseZoom: CGFloat?
    /// Captured on mouse-down because SwiftUI can deliver the tap after Shift is released.
    @State private var lastClickModifiers: NSEvent.ModifierFlags = []
    /// Reference-type cache so pan/zoom do not re-measure the full tree.
    @State private var layoutCache = LayoutResultCache()

    // MARK: - Body

    var body: some View {
        // Size the editing node from the live draft (not the last committed title)
        // so the card grows every keystroke and never flashes "…".
        let liveTitle: LayoutEngine.LiveTitleOverride? = {
            guard let id = store.editingID else { return nil }
            return LayoutEngine.LiveTitleOverride(id: id, title: store.editingDraft)
        }()
        let layout = layoutCache.layout(
            root: store.root,
            structureEpoch: store.structureEpoch,
            liveTitle: liveTitle
        )
        let focusTarget = store.editingID ?? store.selectedID
        let focusSet = store.isFocusMode ? store.focusVisibleIDs() : nil
        let searchSet = Set(store.searchMatchIDs)
        let zoom = store.zoomScale
        let edges = adjustedEdges(layout.edges, freeDrag: freeDrag)

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                canvasBackground
                documentLayer(
                    layout: layout,
                    edges: edges,
                    focusSet: focusSet,
                    searchSet: searchSet,
                    zoom: zoom
                )
            }
            .clipped()
            .coordinateSpace(name: "brainstormCanvas")
            .background(CanvasBackgroundFill(theme: store.theme))
            .background(
                ScrollWheelMonitor(
                    onScroll: { deltaX, deltaY, isZoom in
                        handleScroll(deltaX: deltaX, deltaY: deltaY, isZoom: isZoom)
                    },
                    onMouseDown: { modifiers in
                        lastClickModifiers = modifiers
                    }
                )
            )
            .gesture(magnificationGesture)
            .onAppear {
                viewportSize = geo.size
                if !didCenterInitially {
                    didCenterInitially = true
                    centerOn(focusTarget, in: layout, viewport: geo.size, zoom: zoom, animated: false)
                }
            }
            .onChange(of: geo.size) { _, newSize in viewportSize = newSize }
            .onChange(of: focusTarget) { _, newID in
                guard freeDrag == nil, !suppressAutoCenter, !isPanning else { return }
                ensureVisible(newID, in: layout, viewport: geo.size, zoom: zoom, animated: true)
            }
        }
        .onChange(of: store.editingID) { _, newID in
            focusedNodeID.wrappedValue = nil
            guard let newID else { return }
            DispatchQueue.main.async { focusedNodeID.wrappedValue = newID }
        }
    }

    // MARK: - Layers

    private var canvasBackground: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(canvasPanGesture)
            .simultaneousGesture(
                TapGesture().onEnded { store.canvasBackgroundClicked() }
            )
            .onHover { hovering in
                guard !isPanning, freeDrag == nil else { return }
                if hovering { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
    }

    private func documentLayer(
        layout: LayoutResult,
        edges: [LayoutEdge],
        focusSet: Set<UUID>?,
        searchSet: Set<UUID>,
        zoom: CGFloat
    ) -> some View {
        // Expand document bounds while free-dragging so live edge previews aren’t clipped
        // when the node is pulled past the current content rect.
        let docSize = expandedContentSize(base: layout.contentSize, edges: edges, freeDrag: freeDrag)

        return ZStack(alignment: .topLeading) {
            EdgeCanvas(edges: edges, theme: store.theme, canvasSize: docSize)
                .frame(width: docSize.width, height: docSize.height)
                .allowsHitTesting(false)

            // Sibling reorder gap indicator (document space).
            if let reorderTarget {
                SiblingReorderIndicator(target: reorderTarget, color: store.theme.selectionColor)
                    .allowsHitTesting(false)
            }

            ForEach(layout.nodes) { node in
                // Focus mode only dims appearance — nodes stay fully interactive.
                nodeView(node, layout: layout, focusSet: focusSet, searchSet: searchSet)
                    .position(displayCenter(for: node))
            }
        }
        .frame(width: docSize.width, height: docSize.height, alignment: .topLeading)
        .scaleEffect(zoom, anchor: .topLeading)
        .offset(x: panOffset.width, y: panOffset.height)
        // Disable implicit animations while free-dragging so edges/nodes don't interpolate jumps.
        .transaction { tx in
            if freeDrag != nil { tx.animation = nil }
        }
    }

    /// Content size large enough for current edges (incl. free-drag preview endpoints).
    private func expandedContentSize(
        base: CGSize,
        edges: [LayoutEdge],
        freeDrag: FreeDragSession?
    ) -> CGSize {
        var width = base.width
        var height = base.height
        let pad: CGFloat = 64
        for edge in edges {
            width = max(width, max(edge.from.x, edge.to.x) + pad)
            height = max(height, max(edge.from.y, edge.to.y) + pad)
        }
        if let freeDrag {
            // Approximate dragged node extent from its edge endpoints / delta alone.
            width = max(width, abs(freeDrag.delta.width) + base.width)
            height = max(height, abs(freeDrag.delta.height) + base.height)
        }
        return CGSize(width: width, height: height)
    }

    private func nodeView(
        _ node: LayoutNode,
        layout: LayoutResult,
        focusSet: Set<UUID>?,
        searchSet: Set<UUID>
    ) -> some View {
        let dimmed = focusSet.map { !$0.contains(node.id) } ?? false
        return BrainstormNodeView(
            layoutNode: node,
            isRoot: node.id == store.root.id,
            isSelected: store.isSelected(node.id),
            isEditing: store.editingID == node.id,
            isDropTarget: dropTargetID == node.id,
            isSearchMatch: searchSet.contains(node.id) && !store.searchQuery.isEmpty,
            isDimmed: dimmed,
            isFreeDragging: freeDrag?.nodeID == node.id,
            isExporting: false,
            editSeed: store.editingID == node.id ? store.editingSeed : nil,
            editSelectAll: store.editingID == node.id ? store.editingSelectAll : true,
            focusToken: focusedNodeID,
            onSelect: {
                store.select(
                    node.id,
                    extending: lastClickModifiers.contains(.shift)
                )
            },
            onBeginEdit: { store.beginEditing(id: node.id, selectAll: true) },
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
            onDeleteEmptyWhileEditing: {
                _ = store.deleteEmptyEditingNode()
            },
            onFreeDragChanged: { translation, location in
                beginOrUpdateFreeDrag(nodeID: node.id, translation: translation, location: location, layout: layout)
            },
            onFreeDragEnded: { translation, location in
                commitFreeDrag(nodeID: node.id, translation: translation, location: location, layout: layout)
            },
            onResetPosition: {
                store.resetPosition(id: node.id)
            }
        )
    }

    // MARK: - Free drag (preview only — no store writes until end)

    private func displayCenter(for node: LayoutNode) -> CGPoint {
        var p = CGPoint(x: node.frame.midX, y: node.frame.midY)
        if let freeDrag, freeDrag.nodeID == node.id {
            p.x += freeDrag.delta.width
            p.y += freeDrag.delta.height
        }
        return p
    }

    private func adjustedEdges(_ edges: [LayoutEdge], freeDrag: FreeDragSession?) -> [LayoutEdge] {
        guard let freeDrag else { return edges }
        return edges.map { edge in
            var e = edge
            if e.fromID == freeDrag.nodeID {
                e = LayoutEdge(
                    fromID: e.fromID,
                    toID: e.toID,
                    from: CGPoint(x: e.from.x + freeDrag.delta.width, y: e.from.y + freeDrag.delta.height),
                    to: e.to,
                    colorHex: e.colorHex
                )
            }
            if e.toID == freeDrag.nodeID {
                e = LayoutEdge(
                    fromID: e.fromID,
                    toID: e.toID,
                    from: e.from,
                    to: CGPoint(x: e.to.x + freeDrag.delta.width, y: e.to.y + freeDrag.delta.height),
                    colorHex: e.colorHex
                )
            }
            return e
        }
    }

    /// Canvas viewport point → document layout coordinates.
    private func documentPoint(fromCanvas location: CGPoint, zoom: CGFloat) -> CGPoint {
        let z = max(zoom, 0.01)
        return CGPoint(
            x: (location.x - panOffset.width) / z,
            y: (location.y - panOffset.height) / z
        )
    }

    /// Hit-test a document point against laid-out nodes (topmost wins). Skips `except`.
    private func hitTestNode(
        at documentPoint: CGPoint,
        layout: LayoutResult,
        except: UUID,
        freeDrag: FreeDragSession?
    ) -> UUID? {
        for node in layout.nodes.reversed() {
            guard node.id != except else { continue }
            var frame = node.frame
            if let freeDrag, freeDrag.nodeID == node.id {
                frame = frame.offsetBy(dx: freeDrag.delta.width, dy: freeDrag.delta.height)
            }
            // Slightly expand hit area for easier drop targeting.
            let hit = frame.insetBy(dx: -6, dy: -6)
            if hit.contains(documentPoint) {
                return node.id
            }
        }
        return nil
    }

    private func beginOrUpdateFreeDrag(
        nodeID: UUID,
        translation: CGSize,
        location: CGPoint,
        layout: LayoutResult
    ) {
        let z = max(store.zoomScale, 0.01)
        // Translation is in canvas viewport points; convert to document space.
        let delta = CGSize(width: translation.width / z, height: translation.height / z)
        if freeDrag == nil {
            let n = store.node(id: nodeID)
            freeDrag = FreeDragSession(
                nodeID: nodeID,
                baseOffset: CGSize(width: n?.offsetX ?? 0, height: n?.offsetY ?? 0),
                delta: delta
            )
            store.select(nodeID)
            suppressAutoCenter = true
            NSCursor.closedHand.set()
        } else if var session = freeDrag, session.nodeID == nodeID {
            session.delta = delta
            freeDrag = session
        }

        let doc = documentPoint(fromCanvas: location, zoom: store.zoomScale)
        let commandHeld = NSEvent.modifierFlags.contains(.command)

        // ⌘ held over another node → reparent highlight (optional secondary action).
        if commandHeld {
            reorderTarget = nil
            let hit = hitTestNode(at: doc, layout: layout, except: nodeID, freeDrag: freeDrag)
            if let hit, !store.isDescendant(hit, of: nodeID) {
                dropTargetID = hit
            } else {
                dropTargetID = nil
            }
        } else {
            dropTargetID = nil
            // Same-level reorder: insertion line among siblings when pointer is in their column.
            reorderTarget = siblingReorderTarget(for: nodeID, at: doc, layout: layout)
        }
    }

    private func commitFreeDrag(
        nodeID: UUID,
        translation: CGSize,
        location: CGPoint,
        layout: LayoutResult
    ) {
        let z = max(store.zoomScale, 0.01)
        let delta = CGSize(width: translation.width / z, height: translation.height / z)
        let base = freeDrag?.baseOffset
            ?? CGSize(
                width: store.node(id: nodeID)?.offsetX ?? 0,
                height: store.node(id: nodeID)?.offsetY ?? 0
            )
        let wantsReparent = NSEvent.modifierFlags.contains(.command)
        let doc = documentPoint(fromCanvas: location, zoom: store.zoomScale)
        let pendingReorder = reorderTarget
        let hit = wantsReparent
            ? hitTestNode(at: doc, layout: layout, except: nodeID, freeDrag: freeDrag)
            : nil

        freeDrag = nil
        dropTargetID = nil
        reorderTarget = nil
        suppressAutoCenter = false

        // 1) ⌘-drop onto another node rewires parent (does not free-position).
        if let hit, wantsReparent, !store.isDescendant(hit, of: nodeID), hit != nodeID {
            store.rewire(nodeID: nodeID, onto: hit)
            NSCursor.arrow.set()
            return
        }

        // 2) Drop on sibling insertion line → reorder among same-level nodes.
        if let pendingReorder, pendingReorder.nodeID == nodeID {
            store.reorderAmongSiblings(nodeID: nodeID, toIndex: pendingReorder.toIndex)
            NSCursor.arrow.set()
            return
        }

        // 3) Otherwise free-position on the canvas.
        let nx = base.width + delta.width
        let ny = base.height + delta.height
        if abs(delta.width) > 0.5 || abs(delta.height) > 0.5 {
            store.setManualOffset(
                id: nodeID,
                x: abs(nx) < 0.5 ? nil : Double(nx),
                y: abs(ny) < 0.5 ? nil : Double(ny)
            )
        }
        NSCursor.arrow.set()
    }

    // MARK: - Sibling reorder

    /// Compute same-level insertion target from pointer position in document space.
    private func siblingReorderTarget(
        for nodeID: UUID,
        at documentPoint: CGPoint,
        layout: LayoutResult
    ) -> SiblingReorderTarget? {
        guard nodeID != store.root.id else { return nil }
        let siblingIDs = store.siblingIDs(of: nodeID)
        guard siblingIDs.count >= 2, let fromIndex = store.siblingIndex(of: nodeID) else { return nil }

        // Frames for all siblings at rest (dragged node uses original layout frame for column).
        let framesByID = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.frame) })
        let siblingFrames: [(id: UUID, frame: CGRect)] = siblingIDs.compactMap { id in
            guard let frame = framesByID[id] else { return nil }
            return (id, frame)
        }
        guard siblingFrames.count >= 2 else { return nil }

        let minX = siblingFrames.map(\.frame.minX).min() ?? 0
        let maxX = siblingFrames.map(\.frame.maxX).max() ?? 0
        let minY = siblingFrames.map(\.frame.minY).min() ?? 0
        let maxY = siblingFrames.map(\.frame.maxY).max() ?? 0
        // Horizontal “column” band — outside this = free-position, not reorder.
        let column = CGRect(
            x: minX - 36,
            y: minY - 48,
            width: (maxX - minX) + 120,
            height: (maxY - minY) + 96
        )
        guard column.contains(documentPoint) else { return nil }

        // Insertion index among remaining siblings (after removing the dragged node).
        let others = siblingFrames.filter { $0.id != nodeID }
        var insertAt = others.count
        for (i, entry) in others.enumerated() {
            if documentPoint.y < entry.frame.midY {
                insertAt = i
                break
            }
        }

        // Map to final index in the full children array (remove-then-insert semantics).
        let toIndex = insertAt
        // No-op when dropping back into the same slot.
        guard toIndex != fromIndex else { return nil }

        // Line geometry between neighbors.
        let lineMinX = minX
        let lineMaxX = max(maxX, minX + 80)
        let lineY: CGFloat
        if insertAt == 0, let first = others.first {
            lineY = first.frame.minY - 8
        } else if insertAt >= others.count, let last = others.last {
            lineY = last.frame.maxY + 8
        } else {
            let above = others[insertAt - 1].frame
            let below = others[insertAt].frame
            lineY = (above.maxY + below.minY) / 2
        }

        return SiblingReorderTarget(
            nodeID: nodeID,
            toIndex: toIndex,
            lineY: lineY,
            lineMinX: lineMinX,
            lineMaxX: lineMaxX
        )
    }

    // MARK: - Scroll / zoom / pan

    private func handleScroll(deltaX: CGFloat, deltaY: CGFloat, isZoom: Bool) {
        guard store.editingID == nil, freeDrag == nil else { return }
        if isZoom {
            store.setZoom(store.zoomScale * (1 + deltaY * 0.01))
        } else {
            panOffset.width += deltaX
            panOffset.height += deltaY
            panDragOrigin = panOffset
            // Transient — keyboard selection should re-center after the user stops panning.
            suppressAutoCenter = true
            scheduleClearSuppressAutoCenter()
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard freeDrag == nil else { return }
                // Capture start scale once per gesture; multiply (not compound on mutated zoom).
                if magnificationBaseZoom == nil {
                    magnificationBaseZoom = store.zoomScale
                }
                let base = magnificationBaseZoom ?? store.zoomScale
                store.setZoom(base * value)
            }
            .onEnded { _ in
                magnificationBaseZoom = nil
            }
    }

    private var canvasPanGesture: some Gesture {
        // Only pans empty canvas; node free-drag is handled on each node.
        DragGesture(minimumDistance: 3, coordinateSpace: .named("brainstormCanvas"))
            .onChanged { value in
                if freeDrag != nil { return }
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
                suppressAutoCenter = false
                NSCursor.openHand.set()
            }
    }

    /// After trackpad/scroll pan, re-enable selection auto-center shortly.
    private func scheduleClearSuppressAutoCenter() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if freeDrag == nil, !isPanning {
                suppressAutoCenter = false
            }
        }
    }

    private func centerOn(
        _ nodeID: UUID?,
        in layout: LayoutResult,
        viewport: CGSize,
        zoom: CGFloat,
        animated: Bool
    ) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        guard let nodeID, let node = layout.nodes.first(where: { $0.id == nodeID }) else { return }
        let target = CGSize(
            width: viewport.width / 2 - node.frame.midX * zoom,
            height: viewport.height / 2 - node.frame.midY * zoom
        )
        applyPan(target, animated: animated)
    }

    private func ensureVisible(
        _ nodeID: UUID?,
        in layout: LayoutResult,
        viewport: CGSize,
        zoom: CGFloat,
        animated: Bool
    ) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        guard let nodeID, let node = layout.nodes.first(where: { $0.id == nodeID }) else { return }
        let screenX = node.frame.midX * zoom + panOffset.width
        let screenY = node.frame.midY * zoom + panOffset.height
        let margin: CGFloat = 48
        var next = panOffset
        if screenX < margin { next.width += margin - screenX }
        else if screenX > viewport.width - margin { next.width -= screenX - (viewport.width - margin) }
        if screenY < margin { next.height += margin - screenY }
        else if screenY > viewport.height - margin { next.height -= screenY - (viewport.height - margin) }
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

// MARK: - Free-drag session

private struct FreeDragSession {
    let nodeID: UUID
    let baseOffset: CGSize
    var delta: CGSize
}

/// Where a dragged node will land among its siblings.
private struct SiblingReorderTarget: Equatable {
    let nodeID: UUID
    /// Final index in parent.children after the move.
    let toIndex: Int
    let lineY: CGFloat
    let lineMinX: CGFloat
    let lineMaxX: CGFloat
}

/// Horizontal gap marker shown between same-level nodes while reordering.
private struct SiblingReorderIndicator: View {
    let target: SiblingReorderTarget
    let color: Color

    var body: some View {
        let width = max(40, target.lineMaxX - target.lineMinX)
        HStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Capsule()
                .fill(color)
                .frame(width: width, height: 3)
                .shadow(color: color.opacity(0.55), radius: 4, y: 0)
        }
        .position(
            x: target.lineMinX + width / 2 - 4,
            y: target.lineY
        )
        .opacity(0.95)
    }
}

// MARK: - Background

struct CanvasBackgroundFill: View {
    let theme: AppTheme

    var body: some View {
        ZStack {
            theme.canvasBackgroundColor
            Canvas { context, size in
                let step: CGFloat = 32
                var path = Path()
                var x: CGFloat = 0
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(path, with: .color(theme.gridColor), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Scroll wheel (canvas-only)

/// Local monitor: only consumes scroll when the pointer is over *this* view.
/// Lets the inspector / other chrome scroll with the mouse wheel.
private struct ScrollWheelMonitor: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, Bool) -> Void
    var onMouseDown: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> CanvasScrollHost {
        let view = CanvasScrollHost()
        view.onScroll = onScroll
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ nsView: CanvasScrollHost, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMouseDown = onMouseDown
    }
}

private final class CanvasScrollHost: NSView {
    var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
    var onMouseDown: ((NSEvent.ModifierFlags) -> Void)?
    nonisolated(unsafe) private var monitor: Any?

    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { install() } else { remove() }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window == window else { return event }
            // Only when pointer is over the canvas host — not the inspector.
            let locInView = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(locInView) else { return event }

            if event.type == .leftMouseDown {
                self.onMouseDown?(event.modifierFlags)
                return event
            }

            if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
                return event
            }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return event }
            let zoom = event.modifierFlags.contains(.command)
            if Thread.isMainThread {
                self.onScroll?(dx, dy, zoom)
            } else {
                DispatchQueue.main.async { self.onScroll?(dx, dy, zoom) }
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

// MARK: - Edges

struct EdgeCanvas: View {
    let edges: [LayoutEdge]
    let theme: AppTheme
    let canvasSize: CGSize

    var body: some View {
        // `Canvas` always clips to its bounds — size must cover every control point.
        // Include `canvasSize` in the identity so buffer invalidates when the document grows.
        Canvas { context, size in
            let drawSize = CGSize(
                width: max(size.width, canvasSize.width),
                height: max(size.height, canvasSize.height)
            )
            _ = drawSize
            for edge in edges {
                var path = Path()
                let midX = (edge.from.x + edge.to.x) / 2
                path.move(to: edge.from)
                path.addCurve(
                    to: edge.to,
                    control1: CGPoint(x: midX, y: edge.from.y),
                    control2: CGPoint(x: midX, y: edge.to.y)
                )
                let color: Color = {
                    // Per-edge override, else theme branch (falls back to edge).
                    if let hex = edge.colorHex, let c = Color(hex: hex) { return c.opacity(0.9) }
                    return theme.branchColor.opacity(0.9)
                }()
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
            }
        }
        // Do not use a changing `.id` — that tears down Canvas every free-drag pixel.
        // SwiftUI redraws when `edges` / frame inputs change.
        .animation(nil, value: edges.count)
    }
}

// MARK: - Layout cache

/// Caches full-tree measure/place results. Pan/zoom only transform the snapshot;
/// recompute when `structureEpoch` or the live edit title changes.
@MainActor
final class LayoutResultCache {
    private let engine = LayoutEngine()
    private var structureEpoch: UInt64 = .max
    private var liveID: UUID?
    private var liveTitle: String?
    private var result: LayoutResult?

    func layout(
        root: BrainstormNode,
        structureEpoch: UInt64,
        liveTitle: LayoutEngine.LiveTitleOverride?
    ) -> LayoutResult {
        if structureEpoch == self.structureEpoch,
           liveTitle?.id == liveID,
           liveTitle?.title == self.liveTitle,
           let result
        {
            return result
        }
        let next = engine.layout(root: root, liveTitle: liveTitle)
        self.structureEpoch = structureEpoch
        self.liveID = liveTitle?.id
        self.liveTitle = liveTitle?.title
        self.result = next
        return next
    }
}
