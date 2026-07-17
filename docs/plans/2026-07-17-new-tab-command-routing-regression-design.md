# New Tab Command Routing Regression

## Intended behavior

`New Tab` and Command-T create exactly one new Brainstorm document and attach
it to the native tab group of the active map window. `New Window` and Command-N
remain the only commands that create a separate top-level map window.

## Cause

Brainstorm broadcasts File-menu commands so the active document view can
handle them. A configured standalone map window still has an `NSWindowTabGroup`.
The command-target check accepted every window that was the selected member of
its own group, even when another map window was the application key window.
With multiple separate map windows, one Command-T notification could therefore
be handled more than once. The resulting child-window requests raced and could
remain visible as separate windows.

## Fix

When a map is key, only that exact `NSApp.keyWindow` may handle a shared document
command, and it must also be its native group's selected window. When an
auxiliary Brainstorm window is key, the command routes to the single last-active
map instead of broadcasting to every map group. Immediately before creating a
tab, Brainstorm refreshes that map window's document-to-window registration;
this prevents SwiftUI view churn from leaving the child request waiting on a
stale weak window reference.

## Verification

Unit tests cover selected-tab and key-window identity independently. The macOS
UI regression starts with one two-tab group plus a second standalone map
window, invokes Command-T in the second window, and requires exactly two
top-level windows with two tabs in each group. The existing rapid Command-T,
tab-bar-plus, and Command-N test continues to protect the normal path.
