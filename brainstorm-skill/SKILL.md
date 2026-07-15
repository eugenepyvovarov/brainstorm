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
- Start with `inspect` or `validate` before changing an existing file.
- Use `--dry-run` on mutating commands when checking an operation first.
- Prefer `apply` for a single atomic batch of related updates.
- Keep the JSON response from each mutating command: it records the affected node IDs.
- The app and CLI share the same parent-changing operation. In the app, drag a node directly onto another node and confirm the new parent; the CLI performs the validated move immediately and rejects root/cycle moves.
- The macOS app writes its recovery autosave immediately after each completed document action, including undo and redo. Live title typing and drag previews remain coalesced so the app does not write once per keystroke or pointer frame.
- In the macOS app, plain arrows navigate the tree and ⌘+Arrow still reorders or changes depth outside title editing. While editing a title, modifier arrows do not change the tree; Ctrl+Left/Right remains native word/caret navigation and Ctrl+Up/Down is ignored.
- Text export preserves node order, titles, and the full hierarchy, but not canvas styling, media,
  expanded state, or manual positions. Markdown repeats the root as both the `#` heading and the
  top-level list item.
- Pass `--output -` for any export format to receive only the raw exported bytes on stdout. Do not
  expect the normal JSON response in stdout mode; redirect binary PNG/PDF output to a file or pipe.
- The app lists export choices alphabetically with plain labels; CLI format names remain lowercase.
