# Pixel-Perfect HTML Export Design

## Goal

Add a read-only HTML export that looks exactly like Brainstorm's existing visual export while
remaining easy to open locally or publish on any static host. The exported file is completely
self-contained: it makes no network requests and carries its rendered map, viewer styles, and
viewer controls in one `.html` file.

## Rendering Contract

`BrainstormExporter` remains the single export boundary shared by the macOS app and the
`brainstorm` CLI. HTML export runs the same `LayoutEngine` and `BrainstormExportSurface` used by
PNG and PDF, then embeds the resulting PNG as a base64 data URL. The image is displayed at the
layout's logical canvas dimensions, preserving Brainstorm's theme, nodes, edges, embedded media,
emoji, SF Symbols, manual positions, and collapsed state without maintaining a second renderer.

The viewer is intentionally read-only. Text is not separately selectable, nodes cannot be edited
or expanded, and no `.bs` document data is included. Large maps inherit the PNG export's existing
dimension and pixel-count safeguards.

## Viewer Interaction and Safety

The dependency-free viewer provides Fit, Zoom Out, Zoom In, 100%, and Full Screen controls.
Pointer-wheel zoom keeps the point beneath the cursor stationary, while mouse or trackpad dragging
pans the map. The initial view fits the complete map and recalculates when the browser window
changes size.

The document title is HTML-escaped before insertion. The embedded image is generated locally, and
the HTML contains no remote scripts, fonts, analytics, or resources. This makes the output usable
offline and suitable for GitHub Pages or another static host.

## Product Surfaces and Validation

The app exposes `HTML Viewer` alongside its existing export formats. The CLI accepts
`brainstorm export map.bs --format html --output map.html`, including standard-output streaming.
Tests verify format metadata, HTML escaping, the embedded PNG signature and logical dimensions,
the absence of external resources, and the expected viewer controls. Build validation covers the
shared Swift package, CLI, and macOS app, followed by opening a generated export in a browser.
