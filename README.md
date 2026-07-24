# Brainstorm

**Brainstorm** is a native macOS mind-map editor for turning rough ideas into
clear, editable plans. It combines a fast keyboard-first canvas, portable `.bs`
files, and a JSON-first CLI for scripts and AI agents.

![Brainstorm showing a mind map, native tabs, theme controls, icon picker, and style inspector](https://selfhosted.ninja/wp-content/uploads/2026/07/brainstorm-main-screenshot.jpeg)

## Install

Install the latest macOS release with Homebrew:

```sh
brew install --cask eugenepyvovarov/cask/brainstorm
brainstorm help
```

## Agent instructions

Install the agent instructions from GitHub:

```sh
npx skills add eugenepyvovarov/brainstorm
```

## Highlights

- Build, organize, and style ideas on a fast native canvas with folding, focus
  mode, themes, images, keyboard navigation, drag-and-drop, undo, and autosave
  recovery. Collapsing a branch immediately compacts the visible map instead
  of leaving space—or an expanded-layout vertical offset—for hidden
  descendants; reopening it restores its saved position.
- Work at keyboard speed: Tab creates a child, Return creates a sibling, and
  arrow keys navigate the tree.
- Keep context on the map with optional node notes. The native WYSIWYG editor
  supports formatted text, links, images, and YouTube links without exposing
  Markdown syntax.
- Present the real mind map in depth-first order. The camera follows branches
  and connections; a note flips the current node to its back face.
- Use the app and `brainstorm` CLI on the same portable `.bs` files.

## New: presentation mode

Present the mind map itself—not a deck of separate slides. Start from the
selected node with **Presentation → Start Presentation** or ⌥⌘Return, then
navigate with the arrow keys, Space, touch controls, or nearby nodes. The
camera follows the real map through each branch while connections remain
visible. Notes become the next step after their node and flip that node in
place.

The same presentation mode is included in every self-contained HTML export:
share one file, then switch between **Map** and **Present** in the browser.
In presentation you can pan and zoom the map, then click any visible node to
continue from there. Focused nodes render at native screen resolution, including
deep branches in Safari.

## Node notes

Nodes with notes always show a small note marker. Hover or select any node to
reveal **+ Note** / **Note**, or press ⌥⌘N to create or open the selected
node’s note. Notes support bold, italic, ordered and unordered lists, links,
pasted or dragged images, and YouTube links.

## Files and export

Brainstorm saves human-readable JSON `.bs` files. Existing v1/v2 files remain
readable; new saves use v3 so node notes are preserved.

Click the window title for document actions: **Save**, **Save As…**, **Export**,
**Open…**, and **Open Recent**. After a map is saved on disk, the title also
shows the standard macOS file proxy icon—⌘-click or click-and-hold for the
folder path, and use **Reveal in Finder** or **Copy Path** from the title menu.

The **Sidebar** toolbar control toggles a solid trailing style column. Map theme
stays at the top; collapsible **Colors**, **Type**, **Emoji**, and **Reset**
blocks follow. **Colors** uses a Fill / Text / Border / Branch segmented control
with one shared swatch grid; **Type** holds shape, weight, size, and border
width; **Reset** offers map-wide **Reset Positions** and **Reset Styles**
(clears every node’s style overrides so the active theme drives appearance
again). The column resizes the canvas instead of sliding over it as a drawer.

Use the toolbar **Tasks** control (after **Present**) to show or hide task
checkboxes on nodes. That chrome choice is remembered **per map file**;
completion itself still lives in the `.bs` file. Checking a node marks it done
and marks every descendant done; a parent with some finished children shows a
half-filled state. Done titles use strikethrough. Markdown export writes GFM
task items (`- [ ]` / `- [x]`) from that stored progress.

Style **Sidebar** visibility and which inspector blocks are expanded (Colors,
Type, Emoji, Reset) are remembered app-wide across launches.

Export a map as self-contained interactive HTML, PNG, PDF, Markdown, Mermaid,
or PlantUML. Every export includes the complete tree with all branches expanded;
fold state is kept only in the live `.bs` canvas. HTML export suggests a portable
filename (spaces become underscores; special characters are removed) and offers
**Open in presentation mode** in the save panel. Notes are always embedded in
HTML and can be turned on or off live with the viewer’s **Notes** checkbox
(off by default). Markdown still chooses shown / all / no notes. Markdown
exports with notes are ZIP bundles containing the outline, separate note files,
and image assets. PNG and PDF always stay clean, without notes.

## CLI

```sh
brainstorm create plan.bs --title "Product launch"
brainstorm add plan.bs --parent root --title "Research"
brainstorm update plan.bs --node root --note-text "Key context"
brainstorm export plan.bs --format html --notes all --presentation --output plan.html
brainstorm export plan.bs --format markdown --notes all --output plan.zip
```

See [`brainstorm-skill/SKILL.md`](brainstorm-skill/SKILL.md) for the full CLI
reference, automation guidance, and export options. For source development,
run the repository-local `./brainstorm` wrapper or open
`Brainstorm.xcworkspace` in Xcode.
