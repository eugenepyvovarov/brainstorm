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

# Export with the same renderer as the macOS app.
brainstorm export launch.bs --format pdf --output launch.pdf
```

Use `brainstorm help` before unfamiliar operations. Available commands include `themes`, `create`, `inspect`, `add`, `update`, `style`, `move`, `delete`, `export`, `validate`, and `apply`.

## Safe automation

- Use only `.bs` documents; Brainstorm does not support `.mindmap` files.
- Start with `inspect` or `validate` before changing an existing file.
- Use `--dry-run` on mutating commands when checking an operation first.
- Prefer `apply` for a single atomic batch of related updates.
- Keep the JSON response from each mutating command: it records the affected node IDs.
