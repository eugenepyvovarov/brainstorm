# Pixel-Perfect HTML Export Design

## Goal

Add a read-only HTML export that looks exactly like Brainstorm's existing visual export while
remaining easy to open locally or publish on any static host. The exported file is completely
self-contained: it makes no network requests and carries its vector map, viewer styles, and
interaction code in one `.html` file.

## Rendering Contract

`BrainstormExporter` remains the single export boundary shared by the macOS app and the
`brainstorm` CLI. HTML export runs the same `LayoutEngine` used by the live canvas, then serializes
that layout as an inline vector/DOM scene:

- branch curves are real SVG paths using Brainstorm's control points, width, color, and line caps;
- node cards are positioned HTML elements with the app's exact frames, padding, shapes, borders,
  fills, shadows, typography, and three-line wrapping limit;
- emoji remain text, embedded photos remain local data URLs, and SF Symbol stickers are embedded
  as small per-node assets;
- the selected theme drives the full browser viewport, including a continuous 32-point grid, so
  the map is not presented as a bounded screenshot or page.

The root, visible descendants, manual positions, node styles, media, and collapsed state all come
from the same layout snapshot as Brainstorm. PNG and PDF continue using
`BrainstormExportSurface`; HTML deliberately has its own semantic vector serializer because a
whole-map raster cannot provide a native web map.

The viewer is intentionally read-only. Node text is real browser text, but nodes cannot be edited,
moved, added, deleted, or expanded, and no complete `.bs` document payload is included.

## Viewer Interaction and Safety

The dependency-free viewer uses direct canvas interaction instead of permanently presenting a
floating image toolbar. Pointer-wheel zoom keeps the point beneath the cursor stationary, while
mouse, trackpad, or one-finger dragging pans the map. A two-finger pinch keeps the document point
beneath the live touch midpoint stationary while zooming and translating, and double-tap restores
the fitted view. Keyboard shortcuts provide zoom, reset, and fit. The initial view fits and centers
the complete map and recalculates when the desktop or mobile visual viewport changes size.

Document titles, node labels, identifiers, and attributes are escaped before insertion. Embedded
media is generated locally, and the HTML contains no remote scripts, fonts, analytics, or
resources. This makes the output usable offline and suitable for GitHub Pages or another static
host.

## Product Surfaces and Validation

The app exposes `HTML Viewer` alongside its existing export formats. The CLI accepts
`brainstorm export map.bs --format html --output map.html`, including standard-output streaming.
Tests verify format metadata, escaping, SVG paths, semantic node elements, exact layout
coordinates, shapes, styles, embedded media, collapsed branches, continuous grid behavior, and
the absence of external resources. A regression assertion rejects any whole-map `<img>` or
embedded raster snapshot. Build validation covers the shared Swift package, CLI, and macOS app,
followed by opening a generated export in Safari and comparing it with the native canvas.
