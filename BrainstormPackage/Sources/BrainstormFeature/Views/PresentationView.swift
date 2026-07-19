import AppKit
import SwiftUI
import WebKit

private struct PresentationInteractiveControlFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var presentationInteractiveControlFocused: Bool? {
        get { self[PresentationInteractiveControlFocusedKey.self] }
        set { self[PresentationInteractiveControlFocusedKey.self] = newValue }
    }
}

extension View {
    func marksPresentationInteractiveControl() -> some View {
        focusedValue(\.presentationInteractiveControlFocused, true)
    }
}

enum PresentationNavigationFace: Equatable, Sendable {
    case node
    case note
}

struct PresentationNavigationStep: Identifiable, Equatable, Sendable {
    let itemIndex: Int
    let nodeID: UUID
    let face: PresentationNavigationFace

    var id: String {
        "\(nodeID.uuidString)-\(face == .node ? "node" : "note")"
    }
}

struct PresentationNavigationPlan: Equatable, Sendable {
    let steps: [PresentationNavigationStep]
    private let nodeStepIndicesByItemIndex: [Int: Int]
    private let noteStepIndicesByItemIndex: [Int: Int]
    private let nodeStepIndicesByNodeID: [UUID: Int]

    init(sequence: PresentationSequence) {
        var resolvedSteps: [PresentationNavigationStep] = []
        var resolvedNodeIndices: [Int: Int] = [:]
        var resolvedNoteIndices: [Int: Int] = [:]
        var resolvedNodeIDIndices: [UUID: Int] = [:]
        resolvedSteps.reserveCapacity(sequence.items.count * 2)

        for itemIndex in sequence.items.indices {
            let item = sequence[itemIndex]
            resolvedNodeIndices[itemIndex] = resolvedSteps.count
            resolvedNodeIDIndices[item.id] = resolvedSteps.count
            resolvedSteps.append(
                PresentationNavigationStep(
                    itemIndex: itemIndex,
                    nodeID: item.id,
                    face: .node
                )
            )
            if let note = item.node.note, !note.isEmpty {
                resolvedNoteIndices[itemIndex] = resolvedSteps.count
                resolvedSteps.append(
                    PresentationNavigationStep(
                        itemIndex: itemIndex,
                        nodeID: item.id,
                        face: .note
                    )
                )
            }
        }

        steps = resolvedSteps
        nodeStepIndicesByItemIndex = resolvedNodeIndices
        noteStepIndicesByItemIndex = resolvedNoteIndices
        nodeStepIndicesByNodeID = resolvedNodeIDIndices
    }

    var count: Int { steps.count }

    subscript(index: Int) -> PresentationNavigationStep {
        steps[index]
    }

    func index(
        itemIndex: Int,
        face: PresentationNavigationFace
    ) -> Int? {
        switch face {
        case .node:
            nodeStepIndicesByItemIndex[itemIndex]
        case .note:
            noteStepIndicesByItemIndex[itemIndex]
        }
    }

    func nodeStepIndex(forItem itemIndex: Int) -> Int? {
        nodeStepIndicesByItemIndex[itemIndex]
    }

    func nodeStepIndex(
        forAdjacentItem itemIndex: Int,
        relativeTo currentItemIndex: Int
    ) -> Int? {
        guard abs(itemIndex - currentItemIndex) == 1 else {
            return nil
        }
        return nodeStepIndex(forItem: itemIndex)
    }

    func initialNodeStepIndex(for nodeID: UUID?) -> Int {
        guard let nodeID else { return 0 }
        return nodeStepIndicesByNodeID[nodeID] ?? 0
    }
}

/// Full-window presentation of a frozen, fully expanded map snapshot.
///
/// Navigation follows the root-first depth-first sequence, with each non-empty
/// note immediately following its node as a second face. Entry may begin on a
/// selected node while preserving the complete sequence in both directions.
/// The visual surface remains the real map, and the camera follows the
/// hierarchy route only when the node changes.
struct PresentationView<NoteContent: View>: View {
    // MARK: - Environment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var backingScale
    @AccessibilityFocusState private var accessibilityFocusedNodeID: UUID?
    @FocusedValue(\.presentationInteractiveControlFocused)
    private var presentationInteractiveControlFocused

    // MARK: - Inputs

    let sequence: PresentationSequence
    let navigationPlan: PresentationNavigationPlan
    let layoutSnapshot: LayoutResult
    let layoutNodesByID: [UUID: LayoutNode]
    let sequenceIndicesByID: [UUID: Int]
    let neighborZoomContext: PresentationNeighborZoomPolicy.Context
    let theme: AppTheme
    let noteContent: (NodeNote) -> NoteContent
    let onExit: () -> Void

    // MARK: - State

    @State private var currentIndex = 0
    @State private var currentStepIndex = 0
    @State private var viewportSize: CGSize = .zero
    @State private var cameraMapCenter: CGPoint
    @State private var cameraZoomOverride: CGFloat?
    @State private var pendingIndex: Int?
    @State private var isNavigating = false
    @State private var navigationTask: Task<Void, Never>?

    @State private var noteFaceNodeID: UUID?
    @State private var noteFlipAngle: Double = 0
    @State private var isFlippingNote = false
    @State private var noteFlipTask: Task<Void, Never>?

    // MARK: - Init

    init(
        root: BrainstormNode,
        initialNodeID: UUID? = nil,
        theme: AppTheme,
        @ViewBuilder noteContent: @escaping (NodeNote) -> NoteContent,
        onExit: @escaping () -> Void
    ) {
        let presentationLayout = LayoutEngine().layout(
            root: root,
            placementPolicy: .allDescendants
        )
        let sequence = PresentationSequence(
            root: root,
            layout: presentationLayout
        )
        let navigationPlan = PresentationNavigationPlan(sequence: sequence)
        let initialStepIndex = navigationPlan.initialNodeStepIndex(
            for: initialNodeID
        )
        let initialItemIndex =
            navigationPlan.steps[safe: initialStepIndex]?.itemIndex ?? 0
        self.sequence = sequence
        self.navigationPlan = navigationPlan
        layoutSnapshot = presentationLayout
        layoutNodesByID = Dictionary(
            uniqueKeysWithValues: presentationLayout.nodes.map {
                ($0.id, $0)
            }
        )
        sequenceIndicesByID = Dictionary(
            uniqueKeysWithValues: sequence.items.indices.map {
                (sequence[$0].id, $0)
            }
        )
        neighborZoomContext = PresentationNeighborZoomPolicy.Context(
            nodes: sequence.items.compactMap {
                PresentationNeighborZoomPolicy.Node(item: $0)
            }
        )
        self.theme = theme
        self.noteContent = noteContent
        self.onExit = onExit
        _currentIndex = State(initialValue: initialItemIndex)
        _currentStepIndex = State(initialValue: initialStepIndex)
        _cameraMapCenter = State(
            initialValue:
                sequence.items[safe: initialItemIndex]?.layoutCenter ?? .zero
        )
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let spatialLayout = PresentationSpatialLayout(size: proxy.size)
            let zoom = effectiveZoom(layout: spatialLayout)

            ZStack {
                presentationBackground(
                    cameraCenter: cameraMapCenter,
                    zoom: zoom
                )
                mapWorld(layout: spatialLayout, zoom: zoom)
                controls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear {
                viewportSize = proxy.size
                resetCameraToCurrentNode()
            }
            .onChange(of: proxy.size) { _, newSize in
                viewportSize = newSize
                if !isNavigating {
                    cameraZoomOverride = nil
                    resetCameraToCurrentNode()
                }
            }
        }
        .background(
            PresentationKeyboardMonitor(
                shouldHandleSpace: {
                    presentationInteractiveControlFocused != true
                },
                onPrevious: previous,
                onNext: next,
                onFirst: first,
                onLast: last,
                onToggleNote: toggleCurrentNoteFace,
                onExit: onExit
            )
        )
        .onAppear {
            accessibilityFocusedNodeID = currentItem?.id
        }
        .onDisappear {
            navigationTask?.cancel()
            noteFlipTask?.cancel()
            resetNoteFace()
        }
        .accessibilityIdentifier("presentationMode")
    }

    // MARK: - Derived

    private var currentItem: PresentationItem? {
        guard sequence.items.indices.contains(currentIndex) else { return nil }
        return sequence[currentIndex]
    }

    private var currentFace: PresentationNavigationFace {
        guard navigationPlan.steps.indices.contains(currentStepIndex) else {
            return .node
        }
        return navigationPlan[currentStepIndex].face
    }

    private var canGoBack: Bool { currentStepIndex > 0 }
    private var canGoForward: Bool {
        currentStepIndex + 1 < navigationPlan.count
    }

    private var currentNote: NodeNote? {
        guard let note = currentItem?.node.note, !note.isEmpty else { return nil }
        return note
    }

    private func effectiveZoom(layout: PresentationSpatialLayout) -> CGFloat {
        if let cameraZoomOverride {
            return cameraZoomOverride
        }
        return presentationZoom(for: currentIndex, layout: layout)
    }

    private func presentationZoom(
        for itemIndex: Int,
        layout: PresentationSpatialLayout
    ) -> CGFloat {
        guard sequence.items.indices.contains(itemIndex) else { return 1 }
        let item = sequence[itemIndex]
        let base = layout.magnification(for: item.layoutFrame)
        return PresentationNeighborZoomPolicy.magnification(
            base: base,
            currentID: item.id,
            context: neighborZoomContext,
            viewportSize: layout.size,
            controlsAtBottom: false
        )
    }

    private func presentationBackground(
        cameraCenter: CGPoint,
        zoom: CGFloat
    ) -> some View {
        return ZStack {
            Color(hex: theme.canvasBackground)
                ?? Color(nsColor: theme.isDark ? .black : .windowBackgroundColor)
            CanvasGrid(
                theme: theme,
                cameraCenter: cameraCenter,
                zoom: zoom
            )
                .opacity(0.42)
            LinearGradient(
                colors: [
                    theme.selectionColor.opacity(0.11),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Expanded map world

    private func mapWorld(
        layout: PresentationSpatialLayout,
        zoom: CGFloat
    ) -> some View {
        let worldSize = CGSize(
            width: max(1, layoutSnapshot.contentSize.width),
            height: max(1, layoutSnapshot.contentSize.height)
        )

        return Color.clear
            .frame(width: layout.size.width, height: layout.size.height)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    PresentationMapConnectorLayer(
                        edges: layoutSnapshot.edges,
                        worldSize: worldSize,
                        theme: theme,
                        reduceTransparency: reduceTransparency
                    )
                    .zIndex(0)

                    // Keep the frozen presentation map mounted for the whole
                    // camera route. Culling from the destination camera state
                    // removes source/ancestor nodes before an animation has
                    // visually reached that state and makes branch travel pop.
                    ForEach(layoutSnapshot.nodes) { layoutNode in
                        if layoutNode.id != currentItem?.id {
                            worldNode(
                                layoutNode,
                                layout: layout
                            )
                            .zIndex(
                                pendingIndex.flatMap {
                                    sequence.items[safe: $0]?.id
                                } == layoutNode.id ? 2 : 1
                            )
                        }
                    }

                    if let item = currentItem,
                       let layoutNode = layoutNodesByID[item.id]
                    {
                        currentStage(
                            item: item,
                            layoutNode: layoutNode,
                            layout: layout,
                            zoom: zoom
                        )
                        .zIndex(3)
                    }
                }
                .frame(
                    width: worldSize.width,
                    height: worldSize.height,
                    alignment: .topLeading
                )
                // Connectors, node chrome, text, media, and the current face
                // share this one projection. Nothing inside the map computes
                // or animates its own screen-space offset.
                .modifier(
                    PresentationSharedCameraModifier(
                        viewportCenter: layout.center,
                        cameraCenter: cameraMapCenter,
                        zoom: zoom,
                        pixelAlignmentReference:
                            currentItem?.layoutFrame?.origin,
                        backingScale: backingScale,
                        alignsToPixels: PresentationNodeAnimationPolicy
                            .shouldPixelAlign(isNavigating: isNavigating)
                    )
                )
            }
            .allowsHitTesting(!isNavigating && !isFlippingNote)
    }

    @ViewBuilder
    private func worldNode(
        _ layoutNode: LayoutNode,
        layout: PresentationSpatialLayout
    ) -> some View {
        let nodeIndex = sequenceIndicesByID[layoutNode.id]
        let renderScale = nodeIndex.map {
            presentationZoom(for: $0, layout: layout)
        } ?? 1
        let renderedSize = CGSize(
            width: layoutNode.frame.width * renderScale,
            height: layoutNode.frame.height * renderScale
        )
        let mapSize = layoutNode.frame.size
        let navigationStepIndex = nodeIndex.flatMap(
            navigationPlan.nodeStepIndex(forItem:)
        )
        let mapCenter = CGPoint(
            x: layoutNode.frame.midX,
            y: layoutNode.frame.midY
        )

        Group {
            if let navigationStepIndex, let nodeIndex {
                Button {
                    navigate(toStep: navigationStepIndex)
                } label: {
                    PresentationReadOnlyNodeSurface(
                        layoutNode: layoutNode,
                        theme: theme,
                        isCurrent: pendingIndex == nodeIndex,
                        presentationScale: renderScale
                    )
                }
                .buttonStyle(.plain)
                .marksPresentationInteractiveControl()
                .accessibilityLabel(
                    navigationNeighborAccessibilityLabel(
                        item: sequence[nodeIndex],
                        targetIndex: nodeIndex,
                        targetStepIndex: navigationStepIndex
                    )
                )
                .accessibilityIdentifier(
                    nodeIndex < currentIndex
                        ? "presentationPreviousNode"
                        : "presentationNextNode"
                )
            } else {
                PresentationReadOnlyNodeSurface(
                    layoutNode: layoutNode,
                    theme: theme,
                    isCurrent: pendingIndex == nodeIndex,
                    presentationScale: renderScale
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(width: renderedSize.width, height: renderedSize.height)
        // Lay text and chrome out at the node's eventual focused resolution,
        // then return the complete surface to its real map-space frame. The
        // one shared camera transform below magnifies that vector surface and
        // its connector together.
        .scaleEffect(1 / max(0.01, renderScale))
        .frame(width: mapSize.width, height: mapSize.height)
        .position(mapCenter)
        .opacity(worldNodeOpacity(layoutNode.id))
    }

    private func currentStage(
        item: PresentationItem,
        layoutNode: LayoutNode,
        layout: PresentationSpatialLayout,
        zoom: CGFloat
    ) -> some View {
        let isShowingNote = noteFaceNodeID == item.id
        let mapCenter = CGPoint(
            x: layoutNode.frame.midX,
            y: layoutNode.frame.midY
        )
        let frontSize = CGSize(
            width: layoutNode.frame.width,
            height: layoutNode.frame.height
        )
        let renderScale = presentationZoom(
            for: currentIndex,
            layout: layout
        )
        let renderedFrontSize = CGSize(
            width: layoutNode.frame.width * renderScale,
            height: layoutNode.frame.height * renderScale
        )
        let noteScreenSize = layout.noteCardSize
        let inverseCameraScale = 1 / max(0.01, zoom)
        let noteMapSize = CGSize(
            width: noteScreenSize.width * inverseCameraScale,
            height: noteScreenSize.height * inverseCameraScale
        )
        let stageSize = isShowingNote ? noteMapSize : frontSize
        let noteIndicatorRenderScale = min(
            2,
            max(1.25, max(1, renderScale).squareRoot())
        )

        return ZStack(alignment: .topTrailing) {
            if isShowingNote, let note = item.node.note, !note.isEmpty {
                PresentationNoteBack(
                    item: item,
                    note: note,
                    size: noteScreenSize,
                    theme: theme,
                    noteContent: noteContent
                )
                .id("presentation-note-\(item.id.uuidString)")
                .scaleEffect(inverseCameraScale)
                .frame(
                    width: noteMapSize.width,
                    height: noteMapSize.height
                )
            } else {
                ZStack(alignment: .topTrailing) {
                    PresentationReadOnlyNodeSurface(
                        layoutNode: layoutNode,
                        theme: theme,
                        isCurrent: true,
                        presentationScale: renderScale
                    )
                    .frame(
                        width: renderedFrontSize.width,
                        height: renderedFrontSize.height
                    )

                    if currentNote != nil {
                        PresentationNoteIndicator(
                            theme: theme,
                            scale: noteIndicatorRenderScale
                        )
                        .position(
                            noteIndicatorPosition(
                                in: renderedFrontSize,
                                shape: layoutNode.style.shape,
                                indicatorScale: noteIndicatorRenderScale
                            )
                        )
                    }
                }
                .frame(
                    width: renderedFrontSize.width,
                    height: renderedFrontSize.height
                )
                .scaleEffect(1 / max(0.01, renderScale))
                .frame(width: frontSize.width, height: frontSize.height)
            }
        }
        .frame(width: stageSize.width, height: stageSize.height)
        .rotation3DEffect(
            .degrees(noteFlipAngle),
            axis: (x: 0, y: 1, z: 0),
            perspective: reduceMotion ? 0.28 : 0.72
        )
        .position(mapCenter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            currentStageAccessibilityLabel(item: item)
        )
        .accessibilityFocused(
            $accessibilityFocusedNodeID,
            equals: item.id
        )
        .accessibilityIdentifier("presentationCurrentNode")
    }

    private func worldNodeOpacity(_ nodeID: UUID) -> Double {
        if let pendingIndex, sequence.items.indices.contains(pendingIndex),
           sequence[pendingIndex].id == nodeID
        {
            return 1
        }
        return isNavigating ? 0.9 : 0.82
    }

    private func noteIndicatorPosition(
        in size: CGSize,
        shape: NodeShape,
        indicatorScale: CGFloat
    ) -> CGPoint {
        if shape == .diamond {
            return CGPoint(x: size.width * 0.66, y: size.height * 0.30)
        }
        let frameSize = PresentationNoteIndicator.frameSize(
            scale: indicatorScale
        )
        let halfFrame = frameSize / 2
        let edgeInset = 4 * indicatorScale
        if shape == .capsule || shape == .roundedRect {
            // A bounding-box corner is outside a capsule and can also cross a
            // large presentation-scaled rounded corner. Track the real shape
            // inward while retaining a clear upper-right reading.
            let shapeInset = max(
                halfFrame + edgeInset,
                size.height * 0.30
            )
            return CGPoint(
                x: max(halfFrame, size.width - shapeInset),
                y: min(
                    max(halfFrame, shapeInset),
                    max(halfFrame, size.height - halfFrame)
                )
            )
        }
        return CGPoint(
            x: max(halfFrame, size.width - edgeInset - halfFrame),
            y: min(
                max(halfFrame, edgeInset + halfFrame),
                max(halfFrame, size.height - halfFrame)
            )
        )
    }

    private func navigationNeighborAccessibilityLabel(
        item: PresentationItem,
        targetIndex: Int,
        targetStepIndex: Int
    ) -> String {
        let direction = targetIndex < currentIndex ? "Previous" : "Next"
        let destination = navigationPlan[targetStepIndex]
        let title = displayTitle(item.node)
        let target = destination.face == .note
            ? "note for \(title)"
            : title
        let base = "\(direction): \(target)"
        // Every visible context node is interactive. Preserve detailed route
        // wording for the two sequential peeks without walking ancestor paths
        // for every mounted node during every SwiftUI render.
        guard abs(targetIndex - currentIndex) == 1 else {
            return base
        }
        guard let relationship = sequence.relationship(
            from: currentIndex,
            to: targetIndex
        ) else {
            return base
        }
        return "\(base), \(relationship.accessibilityDescription)"
    }

    private func currentStageAccessibilityLabel(
        item: PresentationItem
    ) -> String {
        let position = "Step \(currentStepIndex + 1) of \(navigationPlan.count)"
        let title = displayTitle(item.node)
        if currentFace == .note {
            return "\(position), note for \(title)"
        }
        return currentNote == nil
            ? "\(position), \(title)"
            : "\(position), \(title), note available as the next step"
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack {
            HStack {
                presentationControlGroup {
                    Button("Exit Presentation", systemImage: "xmark") {
                        onExit()
                    }
                    .presentationControlButton(
                        reduceTransparency: reduceTransparency
                    )
                    .marksPresentationInteractiveControl()
                    .accessibilityIdentifier("presentationExit")
                }

                Spacer()

                presentationControlGroup {
                    HStack(spacing: 10) {
                        Button("Previous", action: previous)
                            .disabled(
                                !canGoBack || isNavigating || isFlippingNote
                            )
                            .presentationControlButton(
                                reduceTransparency: reduceTransparency
                            )
                            .marksPresentationInteractiveControl()
                            .accessibilityIdentifier("presentationPrevious")

                        Text(
                            "\(min(currentStepIndex + 1, navigationPlan.count)) of \(navigationPlan.count)"
                        )
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .frame(minWidth: 68)
                            .accessibilityIdentifier("presentationProgress")

                        Button("Next", action: next)
                            .disabled(
                                !canGoForward || isNavigating || isFlippingNote
                            )
                            .presentationControlButton(
                                reduceTransparency: reduceTransparency
                            )
                            .marksPresentationInteractiveControl()
                            .accessibilityIdentifier("presentationNext")
                    }
                }

                Spacer()

                Color.clear
                    .frame(width: 112, height: 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            Spacer()
        }
    }

    @ViewBuilder
    private func presentationControlGroup<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if reduceTransparency {
            content()
                .padding(7)
                .background(
                    Color(nsColor: theme.isDark ? .black : .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18))
                )
        } else if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                content()
            }
        } else {
            content()
                .padding(7)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }

    // MARK: - Navigation

    private func previous() {
        navigate(toStep: currentStepIndex - 1)
    }

    private func next() {
        navigate(toStep: currentStepIndex + 1)
    }

    private func first() {
        navigate(toStep: 0)
    }

    private func last() {
        navigate(toStep: navigationPlan.count - 1)
    }

    private func navigate(toStep stepIndex: Int) {
        guard navigationPlan.steps.indices.contains(stepIndex),
              stepIndex != currentStepIndex,
              !isNavigating,
              !isFlippingNote
        else {
            return
        }

        let destination = navigationPlan[stepIndex]
        if destination.itemIndex == currentIndex {
            setCurrentNoteFace(destination.face == .note)
            return
        }

        if noteFaceNodeID == currentItem?.id {
            // A note is the physical back of its node. Turn that same surface
            // back to its title before moving the map; destroying the back at
            // camera start makes the note (and any active WebKit player) pop
            // out of existence while its connectors remain on screen.
            setCurrentNoteFace(
                false,
                updatesNavigationStep: false
            ) {
                navigateCamera(to: destination)
            }
        } else {
            navigateCamera(to: destination)
        }
    }

    private func navigateCamera(
        to destination: PresentationNavigationStep
    ) {
        let destinationIndex = destination.itemIndex
        guard sequence.items.indices.contains(destinationIndex) else {
            return
        }

        // Cross-node travel may begin only after a visible note back has
        // completed its turn to the title face. This also guarantees that a
        // WebKit player is torn down before the shared map camera moves.
        guard noteFaceNodeID == nil, !isFlippingNote else { return }
        navigationTask?.cancel()

        guard viewportSize.width > 0,
              viewportSize.height > 0,
              let destinationCenter = sequence[destinationIndex].layoutCenter
        else {
            completeNavigation(to: destination)
            return
        }

        let spatialLayout = PresentationSpatialLayout(size: viewportSize)
        let sourceZoom = presentationZoom(
            for: currentIndex,
            layout: spatialLayout
        )
        let destinationZoom = presentationZoom(
            for: destinationIndex,
            layout: spatialLayout
        )
        let sourceCenter = currentItem?.layoutCenter ?? cameraMapCenter
        let cameraStops = presentationCameraStops(
            sourceCenter: sourceCenter,
            sourceZoom: sourceZoom,
            destinationIndex: destinationIndex,
            destinationCenter: destinationCenter,
            destinationZoom: destinationZoom,
            layout: spatialLayout
        )
        let durations = reduceMotion
            ? Array(
                repeating: 0.16,
                count: max(0, cameraStops.count - 1)
            )
            : PresentationSpatialLayout.segmentDurations(
                for: cameraStops.map(\.center)
            )

        pendingIndex = destinationIndex
        isNavigating = true
        cameraZoomOverride = sourceZoom
        navigationTask = Task { @MainActor in
            for (stop, duration) in zip(cameraStops.dropFirst(), durations) {
                guard !Task.isCancelled else { return }
                withAnimation(
                    reduceMotion
                        ? .easeOut(duration: duration)
                        : .easeInOut(duration: duration)
                ) {
                    cameraMapCenter = stop.center
                    cameraZoomOverride = stop.zoom
                }
                try? await Task.sleep(
                    nanoseconds: UInt64(duration * 1_000_000_000)
                )
            }
            guard !Task.isCancelled else { return }
            completeNavigation(to: destination)
        }
    }

    private func presentationCameraStops(
        sourceCenter: CGPoint,
        sourceZoom: CGFloat,
        destinationIndex: Int,
        destinationCenter: CGPoint,
        destinationZoom: CGFloat,
        layout: PresentationSpatialLayout
    ) -> [PresentationCameraStop] {
        let direct = [
            PresentationCameraStop(center: sourceCenter, zoom: sourceZoom),
            PresentationCameraStop(
                center: destinationCenter,
                zoom: destinationZoom
            ),
        ]
        guard !reduceMotion,
              let route = sequence.traversalRoute(
                  from: currentIndex,
                  to: destinationIndex
              ),
              let points = route.points,
              points.count == route.nodeIDs.count,
              points.count >= 2
        else {
            return direct
        }

        return points.indices.map { routeIndex in
            if routeIndex == 0 {
                return direct[0]
            }
            if routeIndex == points.index(before: points.endIndex) {
                return direct[1]
            }

            let nodeID = route.nodeIDs[routeIndex]
            let itemIndex = sequenceIndicesByID[nodeID]
            let baseZoom = itemIndex.map {
                presentationZoom(for: $0, layout: layout)
            } ?? min(sourceZoom, destinationZoom)
            let neighboringRoutePoints = [
                points[routeIndex - 1],
                points[routeIndex + 1],
            ]
            return PresentationCameraStop(
                center: points[routeIndex],
                zoom: layout.routeContextMagnification(
                    base: baseZoom,
                    center: points[routeIndex],
                    neighboringPoints: neighboringRoutePoints
                )
            )
        }
    }

    private func completeNavigation(
        to destination: PresentationNavigationStep
    ) {
        let destinationIndex = destination.itemIndex
        guard sequence.items.indices.contains(destinationIndex),
              let nodeStepIndex = navigationPlan.index(
                  itemIndex: destinationIndex,
                  face: .node
              )
        else {
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentIndex = destinationIndex
            currentStepIndex = nodeStepIndex
            cameraMapCenter = sequence[destinationIndex].layoutCenter
                ?? cameraMapCenter
            cameraZoomOverride = nil
            pendingIndex = nil
            isNavigating = false
            noteFaceNodeID = nil
            noteFlipAngle = 0
        }
        navigationTask = nil
        if destination.face == .note {
            setCurrentNoteFace(true)
        }
        DispatchQueue.main.async {
            accessibilityFocusedNodeID = sequence[destinationIndex].id
        }
    }

    private func resetCameraToCurrentNode() {
        guard let center = currentItem?.layoutCenter else { return }
        cameraMapCenter = center
    }

    // MARK: - Note face

    private func toggleCurrentNoteFace() {
        let destinationFace: PresentationNavigationFace =
            currentFace == .note ? .node : .note
        guard let stepIndex = navigationPlan.index(
            itemIndex: currentIndex,
            face: destinationFace
        ) else {
            return
        }
        navigate(toStep: stepIndex)
    }

    private func setCurrentNoteFace(
        _ shouldShowNote: Bool,
        updatesNavigationStep: Bool = true,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        let resolvedStepIndex = updatesNavigationStep
            ? navigationPlan.index(
                itemIndex: currentIndex,
                face: shouldShowNote ? .note : .node
            )
            : currentStepIndex
        guard let item = currentItem,
              currentNote != nil,
              !isNavigating,
              !isFlippingNote,
              let destinationStepIndex = resolvedStepIndex,
              (noteFaceNodeID == item.id) != shouldShowNote
        else {
            return
        }

        noteFlipTask?.cancel()

        let turnAwayDuration = reduceMotion ? 0.07 : 0.16
        let turnTowardDuration = reduceMotion ? 0.09 : 0.20
        isFlippingNote = true
        noteFlipTask = Task { @MainActor in
            withAnimation(.easeIn(duration: turnAwayDuration)) {
                noteFlipAngle = 90
            }
            try? await Task.sleep(
                nanoseconds: UInt64(turnAwayDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                noteFaceNodeID = shouldShowNote ? item.id : nil
                if updatesNavigationStep {
                    currentStepIndex = destinationStepIndex
                }
                noteFlipAngle = -90
            }

            withAnimation(.easeOut(duration: turnTowardDuration)) {
                noteFlipAngle = 0
            }
            try? await Task.sleep(
                nanoseconds: UInt64(turnTowardDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            isFlippingNote = false
            noteFlipTask = nil
            completion()
        }
    }

    private func resetNoteFace() {
        noteFlipTask?.cancel()
        noteFlipTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            noteFaceNodeID = nil
            noteFlipAngle = 0
            isFlippingNote = false
        }
    }

    private func displayTitle(_ node: BrainstormNode) -> String {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return node.id == sequence.items.first?.id
            ? BrainstormNode.mainPlaceholder
            : BrainstormNode.nodePlaceholder
    }
}

enum PresentationNodeAnimationPolicy {
    /// Keeps the node's internal TextKit/SwiftUI layout at one focused
    /// resolution while the camera applies one uniform visual transform to
    /// its complete surface.
    static func surfaceScale(
        cameraZoom: CGFloat,
        focusedRenderScale: CGFloat
    ) -> CGFloat {
        cameraZoom / max(0.01, focusedRenderScale)
    }

    /// Pixel rounding is a settled-state sharpness optimization. Applying it
    /// on every animation frame makes nodes step independently from the
    /// unrounded connector canvas.
    static func shouldPixelAlign(isNavigating: Bool) -> Bool {
        !isNavigating
    }

    /// Reference projection matching the affine transform applied to the
    /// complete map world. Kept as a pure geometry seam for verification.
    static func screenPoint(
        for mapPoint: CGPoint,
        viewportCenter: CGPoint,
        cameraCenter: CGPoint,
        zoom: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: viewportCenter.x + (mapPoint.x - cameraCenter.x) * zoom,
            y: viewportCenter.y + (mapPoint.y - cameraCenter.y) * zoom
        )
    }
}

// MARK: - Read-only map node

/// Presentation-only rendering of a real layout node. It deliberately does not
/// instantiate BrainstormNodeView because presentation has no editor, drag,
/// delete, focus, or mutation handlers to supply.
private struct PresentationReadOnlyNodeSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let layoutNode: LayoutNode
    let theme: AppTheme
    let isCurrent: Bool
    let presentationScale: CGFloat

    private var isRoot: Bool { layoutNode.depth == 0 }
    private var renderScale: CGFloat { max(0.01, presentationScale) }

    private var shape: PresentationNodeShape {
        PresentationNodeShape(
            kind: layoutNode.style.shape,
            isRoot: isRoot,
            scale: renderScale
        )
    }

    var body: some View {
        HStack(
            alignment: .center,
            spacing: layoutNode.media.isEmpty ? 0 : 6 * renderScale
        ) {
            PresentationNodeMedia(
                media: layoutNode.media,
                isRoot: isRoot,
                theme: theme,
                presentationScale: renderScale
            )
            Text(displayTitle)
                .font(titleFont)
                .foregroundStyle(textColor)
                .lineLimit(LayoutEngine.displayLineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(1)
                .allowsTightening(false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16 * renderScale)
        .padding(.vertical, (isRoot ? 12 : 10) * renderScale)
        .frame(
            width: layoutNode.frame.width * renderScale,
            height: layoutNode.frame.height * renderScale,
            alignment: .leading
        )
        .background { nodeBackground }
        .overlay(
            shape.stroke(
                borderColor,
                lineWidth: borderWidth
            )
        )
        .shadow(
            color: isCurrent
                ? theme.selectionColor.opacity(0.38)
                : Color.black.opacity(theme.isDark ? 0.42 : 0.12),
            radius: (isCurrent ? 8 : 3) * renderScale,
            y: (isCurrent ? 3 : 1) * renderScale
        )
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayTitle)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityAddTraits(isCurrent ? .isHeader : [])
    }

    private var displayTitle: String {
        let title = layoutNode.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !title.isEmpty {
            return layoutNode.title
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\t", with: " ")
        }
        return isRoot
            ? BrainstormNode.mainPlaceholder
            : BrainstormNode.nodePlaceholder
    }

    private var titleFont: Font {
        let size = (layoutNode.style.fontSize ?? (isRoot ? 16 : 14))
            * renderScale
        let weight: Font.Weight = layoutNode.style.isBold
            ? .semibold
            : (isRoot ? .semibold : .medium)
        var font = Font.system(size: size, weight: weight)
        if layoutNode.style.isItalic {
            font = font.italic()
        }
        return font
    }

    @ViewBuilder
    private var nodeBackground: some View {
        if let hex = theme.resolvedFillHex(
            style: layoutNode.style,
            isRoot: isRoot
        ), let color = Color(hex: hex)
        {
            shape.fill(color)
        } else if reduceTransparency {
            shape.fill(Color(nsColor: .controlBackgroundColor))
        } else {
            shape.fill(.regularMaterial)
        }
    }

    private var textColor: Color {
        theme.resolvedTextColor(
            style: layoutNode.style,
            isRoot: isRoot,
            isPlaceholder: layoutNode.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    private var borderColor: Color {
        if isCurrent {
            return theme.selectionColor
        }
        if let hex = layoutNode.style.borderHex,
           let color = Color(hex: hex)
        {
            return color
        }
        return Color.primary.opacity(theme.isDark ? 0.22 : 0.12)
    }

    private var borderWidth: CGFloat {
        let styledWidth = CGFloat(
            layoutNode.style.borderWidth ?? (isRoot ? 1.5 : 1)
        ) * renderScale
        return isCurrent ? max(2 * renderScale, styledWidth) : styledWidth
    }
}

private struct PresentationNoteIndicator: View {
    static let baseFrameSize: CGFloat = 24

    let theme: AppTheme
    let scale: CGFloat

    static func frameSize(scale: CGFloat) -> CGFloat {
        baseFrameSize * scale
    }

    var body: some View {
        PresentationFoldedNoteGlyph(theme: theme)
            .frame(width: 18 * scale, height: 18 * scale)
            .shadow(
                color: theme.selectionColor.opacity(
                    theme.isDark ? 0.20 : 0.12
                ),
                radius: 1.25 * scale
            )
            .frame(
                width: Self.frameSize(scale: scale),
                height: Self.frameSize(scale: scale)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A compact, theme-tinted folded note. It deliberately has no circular
/// backplate or glass treatment: the indicator is passive map metadata, not a
/// button. The translucent paper and two text strokes remain legible at large
/// presentation magnifications without competing with the node title.
private struct PresentationFoldedNoteGlyph: View {
    let theme: AppTheme

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let origin = CGPoint(
                x: (size.width - 24 * scale) / 2,
                y: (size.height - 24 * scale) / 2
            )
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(
                    x: origin.x + x * scale,
                    y: origin.y + y * scale
                )
            }

            var paper = Path()
            paper.move(to: point(5, 3))
            paper.addLine(to: point(14, 3))
            paper.addLine(to: point(21, 10))
            paper.addLine(to: point(21, 19))
            paper.addQuadCurve(
                to: point(19, 21),
                control: point(21, 21)
            )
            paper.addLine(to: point(5, 21))
            paper.addQuadCurve(
                to: point(3, 19),
                control: point(3, 21)
            )
            paper.addLine(to: point(3, 5))
            paper.addQuadCurve(
                to: point(5, 3),
                control: point(3, 3)
            )
            paper.closeSubpath()

            let accent = theme.selectionColor
            let stroke = accent.opacity(theme.isDark ? 0.84 : 0.76)
            let lineWidth = max(1.2, 1.65 * scale)
            let strokeStyle = StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round
            )

            context.fill(
                paper,
                with: .color(
                    accent.opacity(theme.isDark ? 0.16 : 0.11)
                )
            )
            context.stroke(
                paper,
                with: .color(stroke),
                style: strokeStyle
            )

            var details = Path()
            details.move(to: point(14, 3))
            details.addLine(to: point(14, 9))
            details.addQuadCurve(
                to: point(15, 10),
                control: point(14, 10)
            )
            details.addLine(to: point(21, 10))
            details.move(to: point(7, 14))
            details.addLine(to: point(17, 14))
            details.move(to: point(7, 18))
            details.addLine(to: point(14, 18))
            context.stroke(
                details,
                with: .color(stroke),
                style: strokeStyle
            )
        }
    }
}

private struct PresentationNodeMedia: View {
    let media: NodeMedia
    let isRoot: Bool
    let theme: AppTheme
    let presentationScale: CGFloat

    private var mediaFrame: CGFloat {
        (isRoot ? 22 : 20) * presentationScale
    }

    var body: some View {
        switch media.activeKind {
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: mediaFrame - 4))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: mediaFrame, height: mediaFrame)
                .accessibilityLabel("Emoji \(emoji)")
        case .sticker(let symbol):
            Image(systemName: symbol)
                .font(.system(size: mediaFrame - 6, weight: .semibold))
                .foregroundStyle(theme.selectionColor)
                .frame(width: mediaFrame, height: mediaFrame)
                .accessibilityLabel("Icon \(symbol)")
        case .image(let base64):
            if let data = Data(base64Encoded: base64),
               let image = NSImage(data: data)
            {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: mediaFrame, height: mediaFrame)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 5 * presentationScale,
                            style: .continuous
                        )
                    )
                    .accessibilityLabel("Node image")
            }
        case .none:
            EmptyView()
        }
    }
}

private struct PresentationNodeShape: Shape {
    let kind: NodeShape
    let isRoot: Bool
    let scale: CGFloat

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .roundedRect:
            return RoundedRectangle(
                cornerRadius: isRoot
                    ? BrainstormChrome.rootCorner * scale
                    : BrainstormChrome.nodeCorner * scale,
                style: .continuous
            ).path(in: rect)
        case .capsule:
            return Capsule(style: .continuous).path(in: rect)
        case .rectangle:
            return RoundedRectangle(
                cornerRadius: 4 * scale,
                style: .continuous
            ).path(in: rect)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - Note back

private struct PresentationNoteBack<NoteContent: View>: View {
    let item: PresentationItem
    let note: NodeNote
    let size: CGSize
    let theme: AppTheme
    let noteContent: (NodeNote) -> NoteContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(displayTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(
                        theme.color(theme.chromeForeground, fallback: .primary)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                Divider()
                    .overlay(theme.edgeColor.opacity(0.45))

                noteContent(note)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
        }
        .scrollIndicators(.automatic)
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(theme.chromeBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(
                    theme.selectionColor.opacity(0.72),
                    lineWidth: 2
                )
        )
        .shadow(
            color: Color.black.opacity(theme.isDark ? 0.48 : 0.2),
            radius: 32,
            y: 16
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note for \(displayTitle)")
    }

    private var displayTitle: String {
        let title = item.node.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return title.isEmpty
            ? (item.depth == 0
                ? BrainstormNode.mainPlaceholder
                : BrainstormNode.nodePlaceholder)
            : title
    }
}

// MARK: - Neighbor-aware presentation scale

/// Caps the focused-node magnification just enough to preserve a real glimpse
/// of the map around it. Candidates always come from the stored tree and DFS
/// order; the policy never fabricates screen-edge cards.
struct PresentationNeighborZoomPolicy {
    struct Node: Equatable, Sendable {
        let id: UUID
        let parentID: UUID?
        let siblingIndex: Int
        let frame: CGRect

        init(
            id: UUID,
            parentID: UUID?,
            siblingIndex: Int,
            frame: CGRect
        ) {
            self.id = id
            self.parentID = parentID
            self.siblingIndex = siblingIndex
            self.frame = frame
        }

        init?(item: PresentationItem) {
            guard let frame = item.layoutFrame else { return nil }
            self.init(
                id: item.id,
                parentID: item.parentID,
                siblingIndex: item.siblingIndex,
                frame: frame
            )
        }
    }

    /// Immutable lookup data shared by every node rendered in one frozen
    /// presentation snapshot. Building this once avoids repeatedly scanning
    /// and sorting the full DFS sequence while SwiftUI evaluates map nodes.
    struct Context: Equatable, Sendable {
        let nodes: [Node]
        fileprivate let indicesByID: [UUID: Int]
        fileprivate let nodesByID: [UUID: Node]
        fileprivate let sequentialIDsByNodeID: [UUID: [UUID]]
        fileprivate let candidateIDsByNodeID: [UUID: [UUID]]

        init(nodes: [Node]) {
            self.nodes = nodes
            indicesByID = Dictionary(
                uniqueKeysWithValues: nodes.indices.map {
                    (nodes[$0].id, $0)
                }
            )
            nodesByID = Dictionary(
                uniqueKeysWithValues: nodes.map { ($0.id, $0) }
            )

            var childrenByParentID: [UUID: [Node]] = [:]
            for node in nodes {
                guard let parentID = node.parentID else { continue }
                childrenByParentID[parentID, default: []].append(node)
            }
            for parentID in Array(childrenByParentID.keys) {
                childrenByParentID[parentID]?.sort {
                    $0.siblingIndex < $1.siblingIndex
                }
            }

            var siblingPositionByNodeID: [UUID: Int] = [:]
            for children in childrenByParentID.values {
                for (position, child) in children.enumerated() {
                    siblingPositionByNodeID[child.id] = position
                }
            }

            var resolvedSequentialIDs: [UUID: [UUID]] = [:]
            var resolvedCandidateIDs: [UUID: [UUID]] = [:]
            resolvedSequentialIDs.reserveCapacity(nodes.count)
            resolvedCandidateIDs.reserveCapacity(nodes.count)

            for (currentIndex, current) in nodes.enumerated() {
                let nextID = nodes[safe: currentIndex + 1]?.id
                let previousID = nodes[safe: currentIndex - 1]?.id
                resolvedSequentialIDs[current.id] = [
                    nextID,
                    previousID,
                ].compactMap { $0 }

                var candidates: [UUID] = []
                var seen: Set<UUID> = [current.id]
                func append(_ id: UUID?) {
                    guard let id, seen.insert(id).inserted else { return }
                    candidates.append(id)
                }

                // Tie priority remains next DFS, previous DFS, parent,
                // previous sibling, next sibling, then direct children.
                append(nextID)
                append(previousID)
                append(current.parentID)

                if let parentID = current.parentID,
                   let siblings = childrenByParentID[parentID],
                   let siblingPosition = siblingPositionByNodeID[current.id]
                {
                    append(siblings[safe: siblingPosition - 1]?.id)
                    append(siblings[safe: siblingPosition + 1]?.id)
                }
                childrenByParentID[current.id]?.forEach {
                    append($0.id)
                }
                resolvedCandidateIDs[current.id] = candidates
            }

            sequentialIDsByNodeID = resolvedSequentialIDs
            candidateIDsByNodeID = resolvedCandidateIDs
        }
    }

    static let minimumFocusedScaleRatio: CGFloat = 0.68

    static func magnification(
        base: CGFloat,
        currentID: UUID,
        nodes: [Node],
        viewportSize: CGSize,
        controlsAtBottom: Bool
    ) -> CGFloat {
        magnification(
            base: base,
            currentID: currentID,
            context: Context(nodes: nodes),
            viewportSize: viewportSize,
            controlsAtBottom: controlsAtBottom
        )
    }

    static func magnification(
        base: CGFloat,
        currentID: UUID,
        context: Context,
        viewportSize: CGSize,
        controlsAtBottom: Bool
    ) -> CGFloat {
        let safeBase = max(0.01, base)
        guard context.indicesByID[currentID] != nil,
              let current = context.nodesByID[currentID]
        else {
            return safeBase
        }

        let sequentialIDs = context.sequentialIDsByNodeID[currentID] ?? []
        let candidateIDs = context.candidateIDsByNodeID[currentID] ?? []
        guard !candidateIDs.isEmpty else { return safeBase }

        let viewportCenter = CGPoint(
            x: viewportSize.width / 2,
            y: viewportSize.height / 2
        )
        let visibleRect = safeRect(
            viewportSize: viewportSize,
            controlsAtBottom: controlsAtBottom
        )
        let floor = min(
            safeBase,
            max(1, safeBase * minimumFocusedScaleRatio)
        )

        func cap(for id: UUID) -> CGFloat? {
            guard let candidate = context.nodesByID[id] else { return nil }
            return peekCap(
                currentCenter: CGPoint(
                    x: current.frame.midX,
                    y: current.frame.midY
                ),
                candidateFrame: candidate.frame,
                viewportCenter: viewportCenter,
                safeRect: visibleRect
            )
        }

        let sequentialCaps = sequentialIDs.compactMap(cap)
        if !sequentialCaps.isEmpty,
           sequentialCaps.count == sequentialIDs.count,
           sequentialCaps.allSatisfy({ $0 >= floor })
        {
            return min(safeBase, sequentialCaps.min() ?? safeBase)
        }

        var bestCap: CGFloat?
        for id in candidateIDs {
            guard let candidateCap = cap(for: id),
                  candidateCap >= floor
            else {
                continue
            }
            if bestCap == nil || candidateCap > bestCap! {
                // Strict comparison intentionally preserves candidate priority
                // when two nodes have the same geometric cap.
                bestCap = candidateCap
            }
        }
        return min(safeBase, bestCap ?? floor)
    }

    static func safeRect(
        viewportSize: CGSize,
        controlsAtBottom: Bool
    ) -> CGRect {
        let width = max(0, viewportSize.width)
        let height = max(0, viewportSize.height)
        let peek = min(28, max(16, min(width, height) * 0.03))
        let top = controlsAtBottom ? peek : max(peek, 64)
        let bottom = controlsAtBottom ? max(peek, 64) : peek
        return CGRect(
            x: peek,
            y: top,
            width: max(0, width - peek * 2),
            height: max(0, height - top - bottom)
        )
    }

    static func peekCap(
        currentCenter: CGPoint,
        candidateFrame: CGRect,
        viewportCenter: CGPoint,
        safeRect: CGRect
    ) -> CGFloat {
        let horizontalCap: CGFloat
        if candidateFrame.minX > currentCenter.x {
            horizontalCap = positiveRatio(
                safeRect.maxX - viewportCenter.x,
                candidateFrame.minX - currentCenter.x
            )
        } else if candidateFrame.maxX < currentCenter.x {
            horizontalCap = positiveRatio(
                viewportCenter.x - safeRect.minX,
                currentCenter.x - candidateFrame.maxX
            )
        } else {
            horizontalCap = .infinity
        }

        let verticalCap: CGFloat
        if candidateFrame.minY > currentCenter.y {
            verticalCap = positiveRatio(
                safeRect.maxY - viewportCenter.y,
                candidateFrame.minY - currentCenter.y
            )
        } else if candidateFrame.maxY < currentCenter.y {
            verticalCap = positiveRatio(
                viewportCenter.y - safeRect.minY,
                currentCenter.y - candidateFrame.maxY
            )
        } else {
            verticalCap = .infinity
        }

        return max(0, min(horizontalCap, verticalCap))
    }

    private static func positiveRatio(
        _ numerator: CGFloat,
        _ denominator: CGFloat
    ) -> CGFloat {
        guard denominator > 0 else { return .infinity }
        return max(0, numerator) / denominator
    }
}

// MARK: - Spatial projection

private struct PresentationCameraStop {
    let center: CGPoint
    let zoom: CGFloat
}

private struct PresentationSpatialLayout {
    let size: CGSize

    var center: CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    var noteCardSize: CGSize {
        let side = min(
            760,
            max(360, min(size.width - 180, size.height - 150) * 0.74)
        )
        return CGSize(width: side, height: side)
    }

    /// Uniformly magnifies the exact node frame while keeping enough context
    /// visible around it to read the connected map.
    func magnification(for frame: CGRect?) -> CGFloat {
        guard let frame, frame.width > 0, frame.height > 0 else {
            return 1
        }
        let widthScale = max(1, size.width * 0.48 / frame.width)
        let heightScale = max(1, size.height * 0.29 / frame.height)
        return min(6.5, min(widthScale, heightScale))
    }

    /// Interior hierarchy stops widen just enough to reveal the direction the
    /// camera arrived from and the branch it will enter next. This produces an
    /// actual "back out through the ancestor" move instead of sliding past the
    /// ancestor at the leaf's close-up magnification.
    func routeContextMagnification(
        base: CGFloat,
        center: CGPoint,
        neighboringPoints: [CGPoint]
    ) -> CGFloat {
        let safe = PresentationNeighborZoomPolicy.safeRect(
            viewportSize: size,
            controlsAtBottom: false
        )
        let viewportCenter = self.center
        let horizontalRadius = max(
            1,
            min(
                viewportCenter.x - safe.minX,
                safe.maxX - viewportCenter.x
            ) * 0.86
        )
        let verticalRadius = max(
            1,
            min(
                viewportCenter.y - safe.minY,
                safe.maxY - viewportCenter.y
            ) * 0.82
        )
        var contextualCap = max(0.01, base)
        for point in neighboringPoints {
            let dx = abs(point.x - center.x)
            let dy = abs(point.y - center.y)
            if dx > 0.5 {
                contextualCap = min(contextualCap, horizontalRadius / dx)
            }
            if dy > 0.5 {
                contextualCap = min(contextualCap, verticalRadius / dy)
            }
        }
        return min(max(0.55, contextualCap), max(0.01, base))
    }

    static func segmentDurations(for stops: [CGPoint]) -> [Double] {
        guard stops.count >= 2 else { return [] }
        let lengths = zip(stops, stops.dropFirst()).map {
            distance($0.0, $0.1)
        }
        let totalLength = lengths.reduce(0, +)
        guard totalLength > 0.5 else {
            return Array(repeating: 0.12, count: lengths.count)
        }
        let totalDuration = min(0.9, max(0.42, Double(totalLength / 1_050)))
        return lengths.map { length in
            min(
                0.36,
                max(0.11, totalDuration * Double(length / totalLength))
            )
        }
    }

    private static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}

// MARK: - Map connections

/// One affine camera for the complete frozen map. Connectors and every part of
/// every node are descendants of this modifier, so SwiftUI cannot interpolate
/// their positions on independent timelines.
private struct PresentationSharedCameraModifier: AnimatableModifier {
    let viewportCenter: CGPoint
    var cameraCenter: CGPoint
    var zoom: CGFloat
    let pixelAlignmentReference: CGPoint?
    let backingScale: CGFloat
    let alignsToPixels: Bool

    nonisolated var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        CGFloat
    > {
        get {
            AnimatablePair(
                AnimatablePair(cameraCenter.x, cameraCenter.y),
                zoom
            )
        }
        set {
            cameraCenter = CGPoint(
                x: newValue.first.first,
                y: newValue.first.second
            )
            zoom = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let translation = cameraTranslation
        let transform = CGAffineTransform(
            a: zoom,
            b: 0,
            c: 0,
            d: zoom,
            tx: translation.x,
            ty: translation.y
        )
        return content.projectionEffect(ProjectionTransform(transform))
    }

    private var cameraTranslation: CGPoint {
        var x = viewportCenter.x - cameraCenter.x * zoom
        var y = viewportCenter.y - cameraCenter.y * zoom
        guard alignsToPixels, let reference = pixelAlignmentReference else {
            return CGPoint(x: x, y: y)
        }

        // Align the focused node's map-frame origin by nudging the one shared
        // transform. Per-node rounding would reintroduce connector drift.
        let pixelScale = max(1, backingScale)
        let referenceX = reference.x * zoom + x
        let referenceY = reference.y * zoom + y
        x += (referenceX * pixelScale).rounded() / pixelScale - referenceX
        y += (referenceY * pixelScale).rounded() / pixelScale - referenceY
        return CGPoint(x: x, y: y)
    }
}

private struct PresentationMapConnectorLayer: View {
    let edges: [LayoutEdge]
    let worldSize: CGSize
    let theme: AppTheme
    let reduceTransparency: Bool

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                let start = edge.from
                let end = edge.to
                let midX = (start.x + end.x) / 2
                var path = Path()
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: midX, y: start.y),
                    control2: CGPoint(x: midX, y: end.y)
                )
                let color = edge.colorHex.flatMap(Color.init(hex:))
                    ?? theme.branchColor
                let lineWidth: CGFloat = 1.4

                if !reduceTransparency {
                    context.stroke(
                        path,
                        with: .color(
                            color.opacity(theme.isDark ? 0.24 : 0.16)
                        ),
                        style: StrokeStyle(
                            lineWidth: lineWidth + 1.8,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
                context.stroke(
                    path,
                    with: .color(
                        color.opacity(reduceTransparency ? 1 : 0.92)
                    ),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .frame(width: worldSize.width, height: worldSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Background and controls

private struct CanvasGrid: View, Animatable {
    let theme: AppTheme
    var cameraCenter: CGPoint
    var zoom: CGFloat

    nonisolated var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        CGFloat
    > {
        get {
            AnimatablePair(
                AnimatablePair(cameraCenter.x, cameraCenter.y),
                zoom
            )
        }
        set {
            cameraCenter = CGPoint(
                x: newValue.first.first,
                y: newValue.first.second
            )
            zoom = newValue.second
        }
    }

    var body: some View {
        Canvas { context, size in
            let phase = CGSize(
                width: cameraCenter.x * zoom,
                height: cameraCenter.y * zoom
            )
            var path = Path()
            let step = min(64, max(28, 24 * sqrt(max(1, zoom))))
            let startX = (-phase.width).truncatingRemainder(
                dividingBy: step
            ) - step
            let startY = (-phase.height).truncatingRemainder(
                dividingBy: step
            ) - step
            stride(
                from: startX,
                through: size.width + step,
                by: step
            ).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(
                from: startY,
                through: size.height + step,
                by: step
            ).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(
                path,
                with: .color(
                    Color(hex: theme.grid) ?? .secondary.opacity(0.2)
                ),
                lineWidth: 1
            )
        }
        .allowsHitTesting(false)
    }
}

private struct PresentationControlButtonModifier: ViewModifier {
    let reduceTransparency: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.buttonStyle(.bordered)
        } else {
            content.brainstormGlassButton()
        }
    }
}

private extension View {
    func presentationControlButton(
        reduceTransparency: Bool
    ) -> some View {
        modifier(
            PresentationControlButtonModifier(
                reduceTransparency: reduceTransparency
            )
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Keyboard handling

/// Presentation owns its event monitor while visible and swallows only the
/// navigation keys it handles. A focused media player retains Space, and
/// WebKit receives every key while an element is entering, showing, or exiting
/// fullscreen. Once the player returns inline, presentation keys work again.
private struct PresentationKeyboardMonitor: NSViewRepresentable {
    let shouldHandleSpace: () -> Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onFirst: () -> Void
    let onLast: () -> Void
    let onToggleNote: () -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> PresentationKeyCatcherView {
        let view = PresentationKeyCatcherView()
        update(view)
        return view
    }

    func updateNSView(
        _ nsView: PresentationKeyCatcherView,
        context: Context
    ) {
        update(nsView)
    }

    private func update(_ view: PresentationKeyCatcherView) {
        view.shouldHandleSpace = shouldHandleSpace
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onFirst = onFirst
        view.onLast = onLast
        view.onToggleNote = onToggleNote
        view.onExit = onExit
    }
}

enum PresentationKeyboardAction: Equatable {
    case previous
    case next
    case first
    case last
    case toggleNote
    case exit
}

enum PresentationWebContentKeyboardContext: Equatable {
    case none
    case focusedInline
    case elementFullscreen
}

func presentationShouldHandleKeyboardAction(
    keyCode: UInt16,
    webContentContext: PresentationWebContentKeyboardContext
) -> Bool {
    switch webContentContext {
    case .none:
        true
    case .focusedInline:
        // Keep the conventional play/pause key inside the player. Arrow,
        // paging, Home, End, N, and Escape remain presentation commands.
        keyCode != 49
    case .elementFullscreen:
        // In particular, WebKit must receive Escape to dismiss HTML
        // fullscreen before Brainstorm considers exiting presentation.
        false
    }
}

func presentationKeyboardAction(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    handlesSpace: Bool
) -> PresentationKeyboardAction? {
    let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !flags.contains(.command),
          !flags.contains(.option),
          !flags.contains(.control)
    else {
        return nil
    }

    switch keyCode {
    case 123, 126, 116:
        return .previous
    case 124, 125, 121:
        return .next
    case 49:
        return handlesSpace ? .next : nil
    case 115:
        return .first
    case 119:
        return .last
    case 45:
        return .toggleNote
    case 53:
        return .exit
    default:
        return nil
    }
}

private final class PresentationKeyCatcherView: NSView {
    var shouldHandleSpace: (() -> Bool)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onFirst: (() -> Void)?
    var onLast: (() -> Void)?
    var onToggleNote: (() -> Void)?
    var onExit: (() -> Void)?
    nonisolated(unsafe) private var monitor: Any?

    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitor()
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self,
                  event.window == self.window || event.window == nil
            else {
                return event
            }
            guard let action = presentationKeyboardAction(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                handlesSpace: self.shouldHandleSpace?() ?? true
            ) else {
                return event
            }
            let responder = (event.window ?? self.window)?.firstResponder
            guard presentationShouldHandleKeyboardAction(
                keyCode: event.keyCode,
                webContentContext: self.webContentKeyboardContext(responder)
            ) else {
                return event
            }
            switch action {
            case .previous:
                self.onPrevious?()
            case .next:
                self.onNext?()
            case .first:
                self.onFirst?()
            case .last:
                self.onLast?()
            case .toggleNote:
                self.onToggleNote?()
            case .exit:
                self.onExit?()
            }
            return nil
        }
    }

    private func webContentKeyboardContext(
        _ responder: NSResponder?
    ) -> PresentationWebContentKeyboardContext {
        var view = responder as? NSView
        while let candidate = view {
            if let webView = candidate as? WKWebView {
                return webView.fullscreenState == .notInFullscreen
                    ? .focusedInline
                    : .elementFullscreen
            }
            view = candidate.superview
        }
        return .none
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
