# Brainstorm

**Brainstorm** is a native macOS mind-map editor for turning rough ideas into clear, editable plans. It pairs a fast keyboard-first canvas with rich node styling, native document tabs, portable `.bs` files, and a JSON-first CLI for scripts and AI agents.

![Brainstorm showing a mind map, native tabs, theme controls, icon picker, and style inspector](https://selfhosted.ninja/wp-content/uploads/2026/07/brainstorm-main-screenshot.jpeg)

## Install

Install the latest macOS release with Homebrew:

```sh
brew install --cask eugenepyvovarov/cask/brainstorm

# This works immediately after the cask installation.
brainstorm help
```

## Agent instructions

Install the agent instructions from GitHub:

```sh
npx skills add eugenepyvovarov/brainstorm
```

## Highlights

- Build and explore ideas visually with folding, focus mode, zoom, and a horizontal tree layout.
- Work at keyboard speed: Tab creates a child, Return creates a sibling, and shortcuts cover editing, rearranging, saving, and undo.
- Plain arrow keys navigate the tree. Outside title editing, ⌘+Arrow still reorders or changes node depth; while editing, modifier arrows do not change the tree. Press Space to edit a selected title, use Ctrl+Left/Right for word movement, and Ctrl+Up/Down is disabled while editing.
- Reorganize safely by dragging a node onto another node and confirming the new parent; drag between siblings to reorder or drag aside to change only the visual position.
- Keep working safely with an autosave recovery snapshot after every completed edit, including add, delete, move, reorder, style, rename, undo, and redo actions.
- Style one or many nodes with themes, colors, borders, shapes, typography, emoji, and embedded images.
- Use the app and `brainstorm` CLI on the same portable JSON `.bs` files; the app handles safe external-file changes.
- Export the complete map to high-resolution PNG, single-page PDF, Markdown nested lists, Mermaid, or PlantUML.

## Autosave and recovery

The macOS app writes a recovery snapshot immediately after each completed document action, including adding, deleting, moving, reordering, styling, renaming, undo, and redo. While a title is being typed or a node is being dragged, updates are coalesced briefly so Brainstorm does not write once per keystroke or pointer frame. The normal Save command still writes the `.bs` file to its chosen location.

## In action

<p>
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/node-creation-dracula.gif" alt="Creating child and sibling nodes" width="48%">
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/reorder-dracula.gif" alt="Reordering sibling nodes" width="48%">
</p>
<p>
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/style-dracula.gif" alt="Applying styles to nodes" width="48%">
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/icons-dracula.gif" alt="Adding emoji and media" width="48%">
</p>
<p>
  <img src="https://selfhosted.ninja/wp-content/uploads/2026/07/themes-dracula.gif" alt="Switching app themes" width="48%">
</p>

## CLI

```sh
brainstorm create plan.bs --title "Product launch"
brainstorm add plan.bs --parent root --title "Research"
brainstorm inspect plan.bs --flat --pretty
brainstorm export plan.bs --format pdf --output plan.pdf
brainstorm export plan.bs --format markdown --output plan.md
brainstorm export plan.bs --format mermaid --output plan.mmd
brainstorm export plan.bs --format plantuml --output plan.puml
brainstorm export plan.bs --format markdown --output -
```

Text exports always include the complete tree, including children below collapsed nodes. Markdown
starts with the root as an `#` heading and repeats it as the top-level bullet before its nested list.
Use `--output -` with any format to stream the raw export to stdout instead of writing a file; stdout
mode omits the normal JSON response, so both text and binary exports are safe to pipe or redirect.

Homebrew links the release CLI at `$(brew --prefix)/bin/brainstorm` (`/opt/homebrew/bin/brainstorm` on Apple Silicon and `/usr/local/bin/brainstorm` on Intel Macs). See [`brainstorm-skill/SKILL.md`](brainstorm-skill/SKILL.md) for installation checks, recovery steps, and agent-oriented usage.

For source development, the repository-local `./brainstorm` wrapper builds and runs the CLI with Swift. Open `Brainstorm.xcworkspace` in Xcode to build the macOS app.
