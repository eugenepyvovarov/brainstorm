# Theme Manager Keyboard Navigation and Subtheme Removal

## Interaction

The Zed registry uses native macOS list selection. Clicking a registry row gives
the list focus; Up and Down move through the currently visible results, keep the
selected row in view, and load its preview. Registry search continues to define
the visible result set. The installed-theme search field is removed because the
installed library is deliberately small and already presented as a compact
list.

## Imported variants

Every imported variant has its own remove action. Removing one variant keeps
the other variants from the same Zed file installed. Removing the final visible
variant deletes the imported source file, matching the existing whole-file
behavior.

Brainstorm never rewrites an imported Zed JSON or JSON5 file. Individual
variant removal is persisted in a hidden sidecar next to the managed source
files. The sidecar stores only source filenames and generated variant IDs.
Re-importing an identical source clears its exclusions and restores every
variant. If the removed variant was the preferred default, Brainstorm falls
back to the System theme.

## Verification

Tests cover sidecar persistence across library reloads, preservation of original
source bytes, restoration on re-import, final-variant file deletion, and default
theme fallback. Runtime verification selects a registry row, presses Up and
Down, and confirms the preview follows the highlighted row.
