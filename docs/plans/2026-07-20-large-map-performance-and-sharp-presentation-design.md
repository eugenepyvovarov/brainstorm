# Large-map performance and sharp presentation design

## Scope

Fix three behaviors exposed by `successful-app-mechanics.bs`:

1. Native canvas pan and zoom must remain responsive on a 100+ node system-theme map.
2. Focused HTML presentation nodes must remain sharp at every tree depth in Safari.
3. Collapsed branches must stop reserving space for hidden descendants on the normal canvas.

The document format and presentation traversal order do not change.

## Native canvas

Repeated layout is not the bottleneck: `LayoutResultCache` already excludes pan
and zoom. The expensive path is a two-step zoom update followed by work for all
109 node views, including off-screen interactive Liquid Glass surfaces,
matched-geometry sources, shadows, and recursive note lookups.

Considered approaches:

- Re-measure or memoize the tree more aggressively: rejected because layout is
  already cached during viewport transforms.
- Rasterize the complete map while zooming: rejected as the primary path
  because it temporarily softens text and can flatten backdrop-dependent glass.
- Apply the viewport transform atomically and render only a generously
  overscanned visible subset: selected. It preserves native text and interaction
  while removing avoidable view and compositor work.

Implementation:

- Compute cursor-preserving pan and the clamped zoom in one nonanimated update.
- Skip assignments at the zoom limits.
- Cull node views outside the viewport with document-space overscan, while
  always retaining selected, edited, dragged, drop-target, and note-transition
  nodes.
- Carry note presence in `LayoutNode` instead of recursively searching the tree
  once per rendered node.
- Keep only one cancellable pan debounce task.
- Register matched geometry only for the selected or hovered note-transition
  candidate.
- Use noninteractive glass and no shadow for ordinary idle nodes; selected,
  hovered, dragged, drop-target, and search states retain interactive emphasis.

## HTML presentation sharpness

The existing renderer sizes each slide at its focus scale, applies an inverse
child transform, and then magnifies the shared parent world. Safari can cache the
downscaled child layer and enlarge it, which is most visible when small
depth-three nodes reach the `4.8×` camera cap.

Considered approaches:

- Raise or lower camera scale caps: rejected because it changes composition and
  does not remove the low-resolution layer.
- Reset only the parent transform or flatten the note flip at rest: rejected
  because the inverse slide transform remains.
- Move the actual focused slide to a fixed screen-space layer after camera
  settling: selected. The world copy participates in travel with its connection
  lines, then the same DOM node is rendered at native screen dimensions with no
  scale transform.

The focused slide is moved rather than cloned so node identity, accessibility,
note-face state, and delegated navigation remain intact. A departing YouTube
player is reset before the node is restored to the world, and an arriving player
loads only after promotion, avoiding duplicate or stale browsing contexts.

## Collapsed layout

`expandedOnly` measurement stops at a collapsed node and treats it as its own
visible cluster. `allDescendants` continues to measure the complete stored tree,
so native and HTML presentation retain fully expanded geometry without changing
the saved expansion state. A folded branch is vertically auto-packed in the
normal map rather than reusing the manual offset chosen for its expanded
subtree; that stored offset returns when the branch is opened and remains part
of all-descendant presentation geometry.

## Verification

- Unit regressions for compact collapsed geometry, full descendant presentation
  geometry, note-presence layout metadata, zoom clamping, and viewport culling.
- Generated-HTML regressions for focus-layer promotion/restoration and the
  absence of a settled inverse scale.
- Full Swift package and macOS build/test pass.
- Only after implementation is complete: open the supplied `.bs` file in the
  built app and exercise native pan/zoom; export it to HTML and verify shallow
  and deep focused nodes in Safari.
