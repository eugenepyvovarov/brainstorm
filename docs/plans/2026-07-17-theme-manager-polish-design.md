# Theme Manager Polish and Caching Design

## Experience

The Theme Manager fills its window from edge to edge and uses three stable
columns: a compact installed-theme library, a compact searchable Zed registry,
and a flexible preview. Both collections use dense native rows instead of large
cards. Selection is obvious, but repeated labels and decorative surfaces are
removed. Liquid Glass is reserved for the selected surface and primary actions
on macOS 26; macOS 14–25 keep material-backed fallbacks. The preview itself
never uses glass because that would distort the palette being evaluated.

## Preview

The preview renders a real miniature Brainstorm map, not a generic node chart.
It paints the selected theme’s canvas and grid across the full preview bounds,
places one root and two children using the app’s left-to-right hierarchy, and
draws the same cubic Bézier branches used by `EdgeCanvas`. Node radii, type,
borders, shadows, and semantic theme colors follow `BrainstormNodeView`. The
map has no artificial inner canvas padding, while node positions retain a small
safety inset so shadows are not clipped.

## Data and caching

The public Zed registry is cached on disk with a freshness timestamp. A fresh
catalog opens immediately without a request; a stale catalog remains available
offline when refresh fails. Selected extension archives are cached by extension
ID, version, and compatibility versions, so repeat previews and app relaunches
do not download them again. Network responses are validated before atomically
replacing cached data. Manual and registry imports continue to preserve the
original Zed JSON bytes unchanged.

## Palette derivation and verification

Imported Zed palettes are converted into opaque Brainstorm roles without
discarding alpha. Translucent Zed overlays are composited against the correct
base surface. Canvas, node, and root fills are kept visually distinct; root and
node labels must remain readable; branches retain the source accent; grid and
edge colors stay restrained. Curated built-in themes remain unchanged.

Verification covers cache persistence and freshness, archive version keys,
offline fallback, alpha compositing, palette role contrast, original-byte
preservation, and safe archive extraction. The final gate is a full Swift
package test run followed by a fresh macOS build and visual inspection of both a
light and dark Zed theme.

## Zed JSON5 compatibility

Zed theme files may use JSON5 syntax even when their extension is `.json`,
including line comments and trailing commas. Brainstorm parses these files with
Foundation's native JSON5 option instead of rewriting or manually stripping
their contents. Imported files still retain their exact original bytes. Parser
failures are translated into `ZedThemeImportError.invalidThemeFile`, so a
genuinely malformed extension produces a specific Brainstorm error instead of a
generic Cocoa decoding message.
