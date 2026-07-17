---
name: brainstorm
description: Create, inspect, edit, validate, and export Brainstorm `.bs` mind-map files with the installed `brainstorm` CLI. Use when an agent needs to automate a Brainstorm document without driving the macOS app UI.
---

# Brainstorm CLI

Use the installed `brainstorm` command to work with portable JSON `.bs` files. It prints JSON to standard output and returns a non-zero status with JSON error details when a command fails.

## Locate the installed CLI

The Homebrew cask links the CLI at:

```sh
$(brew --prefix)/bin/brainstorm
```

That is normally `/opt/homebrew/bin/brainstorm` on Apple Silicon Macs and `/usr/local/bin/brainstorm` on Intel Macs. Confirm it is available before use:

```sh
command -v brainstorm
brainstorm help
```

## Install or repair the Homebrew installation

Install Brainstorm and its CLI from the self-owned cask:

```sh
brew install --cask eugenepyvovarov/cask/brainstorm
```

If the app is installed but `command -v brainstorm` returns nothing, update to a release that includes the CLI:

```sh
brew update
brew upgrade --cask eugenepyvovarov/cask/brainstorm
```

If the link is still absent, reinstall the cask:

```sh
brew uninstall --cask eugenepyvovarov/cask/brainstorm
brew install --cask eugenepyvovarov/cask/brainstorm
```

The macOS app is installed at `/Applications/Brainstorm.app`. The CLI and app safely share the same `.bs` files; save GUI edits before an automated edit.

## Common commands

```sh
# Create and inspect a map.
brainstorm create launch.bs --title "Product launch"
brainstorm inspect launch.bs --flat --pretty

# Add a child to the root and validate the document.
brainstorm add launch.bs --parent root --title "Research"
brainstorm validate launch.bs

# Export images/documents with the same renderer as the macOS app.
brainstorm export launch.bs --format pdf --output launch.pdf

# Export the complete tree as text, including descendants of collapsed nodes.
brainstorm export launch.bs --format markdown --output launch.md
brainstorm export launch.bs --format mermaid --output launch.mmd
brainstorm export launch.bs --format plantuml --output launch.puml

# Stream any text or binary export to stdout (no JSON envelope).
brainstorm export launch.bs --format markdown --output -

# Move an existing node under a different parent (optionally at a specific index).
brainstorm move launch.bs --node <uuid> --parent <uuid-or-root> --index 0
```

Use `brainstorm help` before unfamiliar operations. Available commands include `themes`, `create`, `inspect`, `add`, `update`, `style`, `move`, `delete`, `export`, `validate`, and `apply`.

## Safe automation

- Use only `.bs` documents; Brainstorm does not support `.mindmap` files.
- `.bs` files are human-readable sparse JSON. New saves omit empty/default fields, while existing verbose v1/v2 files remain readable and are compacted on the next save; stable node UUIDs and explicit style/media/position values are preserved.
- Start with `inspect` or `validate` before changing an existing file.
- Use `--dry-run` on mutating commands when checking an operation first.
- Prefer `apply` for a single atomic batch of related updates.
- Keep the JSON response from each mutating command: it records the affected node IDs.
- The app and CLI share the same parent-changing operation. In the app, drag a node directly onto another node and confirm the new parent; the CLI performs the validated move immediately and rejects root/cycle moves.
- The macOS app writes its recovery autosave immediately after each completed document action, including undo and redo. Live title typing and drag previews remain coalesced so the app does not write once per keystroke or pointer frame.
- On every normal app launch, Brainstorm shows a welcome screen with **New Mind Map**, **Open…**, and up to five recent `.bs` files. Finder/Dock opens still load the requested `.bs` document directly; recovery snapshots remain available for document recovery but never replace the welcome screen.
- Closing a saved map records its standalone window size and location in that map's Recent entry. Reopening it from Recent restores that geometry, clamped to the currently visible displays; tab opens retain their parent window geometry.
- Use the toolbar’s **Theme** menu → **Manage Themes…** to browse the compact native Zed Theme Registry inside Brainstorm. The catalog is cached on disk for fast launches and stale offline fallback; a selected extension archive is cached by extension version. After choosing a registry result, Up/Down selects the previous or next result. Brainstorm reads only safe `themes/*.json` files, including native Zed JSON5 comments and trailing commas, and renders a real one-root, two-child map from the selected palette. Import retains every selected source file unchanged in Application Support/Brainstorm/Zed Themes; manual import accepts the same format. An imported source can expose multiple variants: remove variants individually, with the unchanged source deleted only after its final variant is removed; importing the source again restores all variants. Built-in themes cannot be deleted. Theme imports, removals, and default changes refresh open editors immediately.
- Canvas zoom keeps the map point beneath the pointer fixed for Command-scroll and trackpad magnification. Toolbar and keyboard zoom use the most recent pointer location when available, falling back to the viewport center.
- The macOS app remembers inspector visibility and focus mode as app-wide workspace preferences across launches and `.bs` files. These settings are UI state, not document content, so changing them never dirties a map.
- In the macOS app, plain arrows navigate the tree and ⌘+Arrow still reorders or changes depth outside title editing. While editing a title, modifier arrows do not change the tree; Ctrl+Left/Right remains native word/caret navigation and Ctrl+Up/Down is ignored.
- Text export preserves node order, titles, and the full hierarchy, but not canvas styling, media,
  expanded state, or manual positions. Markdown repeats the root as both the `#` heading and the
  top-level list item.
- Pass `--output -` for any export format to receive only the raw exported bytes on stdout. Do not
  expect the normal JSON response in stdout mode; redirect binary PNG/PDF output to a file or pipe.
- The app lists export choices alphabetically with plain labels; CLI format names remain lowercase.
