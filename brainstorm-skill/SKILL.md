---
name: brainstorm
description: Create, inspect, edit, validate, and export Brainstorm `.bs` mind-map files, including node notes and HTML presentation mode, with the installed `brainstorm` CLI. Use when an agent needs to automate a Brainstorm document without driving the macOS app UI.
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

# Add a focused Markdown note, an embedded image, and a YouTube reference.
brainstorm update launch.bs --node root \
  --note-text $'Launch context with **priority**.\n\n- Confirm scope\n- Confirm owner' \
  --note-visible shown
brainstorm update launch.bs --node root \
  --note-image launch-diagram.png --note-image-alt "Launch dependency diagram" \
  --note-image-caption "Current launch sequence"
brainstorm update launch.bs --node root \
  --note-youtube "https://youtu.be/M7lc1UVf-VE?t=30" \
  --note-youtube-caption "Reference walkthrough"

# Export a vector web viewer that opens in presentation mode with every note.
brainstorm export launch.bs --format html --notes all --presentation --output launch.html

# PNG/PDF always export a note-free map; Markdown can explicitly omit note bytes.
brainstorm export launch.bs --format pdf --output launch.pdf
brainstorm export launch.bs --format markdown --notes none --output public-outline.md

# Every export includes the complete tree (descendants under folded canvas
# branches). Fold state is live-canvas only and is not applied to exports.
brainstorm export launch.bs --format markdown --output launch.zip
brainstorm export launch.bs --format mermaid --output launch.mmd
brainstorm export launch.bs --format plantuml --output launch.puml
brainstorm export launch.bs --format html --output launch.html
brainstorm export launch.bs --format png --output launch.png

# Stream any text or binary export to stdout (this example emits ZIP bytes).
brainstorm export launch.bs --format markdown --output -

# Move an existing node under a different parent (optionally at a specific index).
brainstorm move launch.bs --node <uuid> --parent <uuid-or-root> --index 0
```

Use `brainstorm help` before unfamiliar operations. Available commands include `themes`, `create`, `inspect`, `add`, `update`, `style`, `move`, `delete`, `export`, `validate`, and `apply`.

## App quit safety

Closing a dirty native map window or quitting Brainstorm presents the standard **Save**, **Don’t
Save**, and **Cancel** review. Quit reviews every live dirty map, with the active map first, and
Cancel keeps the application and every map open. A successful Save/Save As checkpoints the `.bs`
file before termination. **Don’t Save** removes an untitled recovery document or resets a saved
map’s recovery snapshot to its last saved file content, preventing explicitly discarded edits from
reappearing on the next launch.

## App note workflow

In the macOS app, notes are not edited in the inspector. Turn on the default-off Notes layer, then
hover or select a node to reveal its transient **+ Note**/**Note** action. The note context-menu
command and ⌥⌘N remain available with the visual layer off. The node lifts into a centered native
composer while the map is dimmed and locked. The production composer uses Brainstorm's
Apple-native AppKit/TextKit attributed surface. Its visible storage contains rich text rather than
Markdown source, so caret movement and image selection cannot reveal syntax markers. Brainstorm
converts attributed content to Markdown only for `.bs` persistence and enables only paragraphs, line breaks,
bold, italic, ordered/unordered lists, and safe HTTP(S) links; unsupported syntax remains literal.
No headings, code, tables, tasks, wiki links, or LaTeX are enabled. ⌘B/⌘I apply
emphasis and ⇧⌘8/⇧⌘7 apply bulleted or numbered lists. A YouTube URL anywhere in the note,
including a labeled Markdown link, remains clickable in the editor and also becomes a typed video
attachment. An ordinary URL remains a clickable link. Pasted or dropped images become validated
embedded PNG blocks, bounded to 320×220 points, and render inside the editing surface. Finder
file-URL drops accept one or several images in one gesture, preserving their pasteboard order, and
raw image drops are also supported. Clicking an image leaves it rendered and
typing remains available in the text surface. The WYSIWYG composer shows neither attachment chips nor image-embed
Markdown source; there are no Image/YouTube buttons, players, descriptions, or
media-configuration forms in the composer. Choose **Done**, press
Escape, or press ⌥⌘N again to return to the map. Outside this composer, Tab and Return retain their
normal child/sibling creation behavior. The Notes workspace control affects only the transient
visual action and compact presence markers, starts off for a fresh installation, and never changes
or dirties the `.bs` file. A
marker is a very small, low-emphasis,
non-interactive SF Symbol `note.text` inside the node’s top-right corner. It uses an active-theme
tint with no circle or button chrome and never becomes an inline note preview.

## Automate node notes

Use `inspect --flat --pretty` to obtain stable node UUIDs, each node's typed `note` object, and
attachment UUIDs before an edit:

```sh
brainstorm inspect launch.bs --flat --pretty
```

Set note text directly, read UTF-8 Markdown from a file, or stream it from stdin. Use only one of
`--note-text` and `--note-file`:

```sh
brainstorm update launch.bs --node <uuid> \
  --note-text $'A paragraph with **bold** and _italic_.\n\n1. First\n2. Second'
brainstorm update launch.bs --node <uuid> --note-file note.md
printf '%s\n' '- First' '- Second' \
  | brainstorm update launch.bs --node <uuid> --note-file -
```

The supported body syntax is deliberately limited to paragraphs, line breaks, `**bold**`,
`_italic_`, `-`/`*`/`+` unordered lists, positive-number-plus-dot ordered lists such as `1.`, and
validated HTTP(S) links such as `[reference](https://example.com)`. Lists are flat. Unsafe link
schemes, raw HTML, and unsupported Markdown are treated as literal text. The macOS app edits this
same portable subset through an attributed TextKit 2 surface whose visible storage contains no
Markdown delimiters and has no raw-source mode.

Set the note's saved visibility independently from its content, or clear the complete note:

```sh
brainstorm update launch.bs --node <uuid> --note-visible hidden
brainstorm update launch.bs --node <uuid> --note-visible shown
brainstorm update launch.bs --node <uuid> --note-clear
```

`shown`/`hidden` are canonical; the CLI also accepts the boolean-style aliases reported by
`brainstorm help`. Saved visibility controls the default canvas/static-export treatment. It is not
access control and does not remove content from `.bs`.

Add ordered attachments with these commands:

```sh
# Alternative text is required; caption is optional.
brainstorm update launch.bs --node <uuid> \
  --note-image diagram.jpg --note-image-alt "Dependency diagram" \
  --note-image-caption "Proposed sequence"

# Accepts a validated 11-character ID or supported YouTube URL.
brainstorm update launch.bs --node <uuid> \
  --note-youtube "https://www.youtube.com/watch?v=M7lc1UVf-VE&t=30s" \
  --note-youtube-caption "Demo"
```

Brainstorm decodes an imported image, strips metadata, bounds it to a 2,048-pixel long edge and
4,194,304 pixels, and embeds one normalized PNG frame. Inputs may be at most 50 MB; normalized PNG
data may be at most 5,000,000 bytes per image and 20,000,000 bytes across the document. Alternative
text is required and limited to 1,000 characters. Captions are limited to 2,000 characters. Each
note accepts at most 32 attachments, and note text is limited to 100,000 characters.

YouTube parsing accepts `youtu.be` and common `youtube.com` watch/embed/shorts/live URLs, including
an optional `t`, `start`, or `time_continue` value. Brainstorm stores only the validated video ID,
an optional start time of at most 604,800 seconds, and the optional caption.

Use attachment UUIDs from `inspect --flat` to remove or reorder an attachment:

```sh
brainstorm update launch.bs --node <uuid> --note-remove <attachment-uuid>
brainstorm update launch.bs --node <uuid> \
  --note-move <attachment-uuid> --note-index 0
```

For one atomic group, `apply` supports `note.set`, `note.clear`, `note.image`, `note.youtube`,
`note.remove`, and `note.move`:

```json
{
  "operations": [
    {
      "op": "note.set",
      "node": "root",
      "bodyMarkdown": "Context with **priority**.",
      "visibility": "shown"
    },
    {
      "op": "note.image",
      "node": "root",
      "imagePath": "diagram.png",
      "altText": "Dependency diagram",
      "caption": "Current sequence"
    },
    {
      "op": "note.youtube",
      "node": "root",
      "youtube": "M7lc1UVf-VE",
      "caption": "Reference walkthrough"
    }
  ]
}
```

```sh
brainstorm apply launch.bs --input note-operations.json --dry-run --pretty
brainstorm apply launch.bs --input note-operations.json --pretty
brainstorm validate launch.bs
```

Batch attachment operations use `attachmentID` and zero-based `attachmentIndex`. Successful
`note.image` and `note.youtube` results include the new `attachmentID`.

## Export notes and presentations

HTML and Markdown exports accept one note inclusion policy. PNG and PDF always export the clean
mind map without note markers, note cards, text, or attachments:

```sh
# Default: include notes whose saved visibility is shown.
brainstorm export launch.bs --format html --notes visible --output launch.html

# PNG/PDF are always note-free; the note flag cannot add note content.
brainstorm export launch.bs --format png --output map.png
brainstorm export launch.bs --format pdf --output public.pdf

# Remove note text and attachments from note-capable exports.
brainstorm export launch.bs --format markdown --notes none --output public.md
```

`--notes visible` is the default and excludes saved-hidden notes. With `--notes all`, HTML includes
their presence markers and presentation steps, and Markdown links them from the map outline.
Saved-hidden is never a secrecy boundary; use `--notes none` when an HTML or Markdown output must
contain no note payload. PNG, PDF, Mermaid, and PlantUML remain hierarchy-only.

Markdown with no included notes writes one `.md` outline. Each included node appends a **Note**
link to its separate document. If at least one note is included, use a
`.zip` destination: the archive contains `map.md`, one
`notes/<safe-title>--<node-uuid>.md` document per included node note, and normalized
`assets/*.png` files referenced by image attachments. Each linked note document starts with its
node title, preserves the safe formatted body, and renders YouTube attachments as canonical links.
The CLI rejects a `.md` destination when a bundle is required and rejects a `.zip` destination when
the result is only one Markdown file. `--output -` remains available and emits raw ZIP bytes for a
bundle.

HTML contains both an interactive map and a one-node-at-a-time presentation. Use `--presentation`
only with `--format html` to choose presentation as the initial scene:

```sh
brainstorm export launch.bs --format html --notes all --presentation \
  --output launch-presentation.html
```

Every export (HTML map, HTML presentation, PNG, PDF, Markdown, Mermaid, PlantUML) lays out or
walks the complete stored tree. Folded branches remain a live-canvas detail of the `.bs` file and
do not hide descendants from any export. The presentation starts with root-first depth-first node
preorder over that complete tree. Every non-empty note included by the export policy adds a
separate step immediately after its node, producing `node → note back → next depth-first node`;
previous navigation retraces the same steps exactly—`next node → previous note back → previous
node title`—and progress counts both node and note steps.
In the native app, starting presentation uses the currently selected node’s title step as the
initial position, with root as the fallback when no valid selection exists. The navigation plan is
not sliced or reordered: Previous still reaches earlier steps, Home reaches root, and Next
continues through the remaining depth-first sequence.
Presentation reuses the fully expanded map as a world. The current node keeps its natural aspect,
shape, style, and media; surrounding nodes and solid curved connections—with no arrowheads—remain
partially visible at real map positions. Moving between different nodes drives the magnified camera,
including travel back through the lowest common ancestor before entering the next branch. Moving
between a node and its note keeps the camera fixed and performs an in-place 3D flip to or from a
bounded rounded-square note back. The note is part of the node, not a modal, AJAX window, or
floating overlay. A node without content has no note step and never becomes a square slide.
The HTML viewer preserves a readable focused-node zoom at rest and uses a temporary overview zoom
only while crossing a long branch route. Its camera, grid, nodes, and connectors advance on one
animation-frame timeline; focus moves to the destination so successive arrow-key steps continue.
Normal motion uses the full 3D flip. Reduce Motion preserves the title/note relationship with a
quick crossfade without perspective. At rest, HTML uses a device-pixel aligned 2D camera, removes
permanent compositor hints, and moves the actual focused DOM node into a fixed screen-space focus
layer at its final pixel dimensions. This avoids inverse child scaling and keeps deep focused text
sharp in Safari. Before node-to-node travel, the same element returns to the map world so both the
native app and HTML viewer animate connector lines and each complete rendered node surface through
one shared camera timeline; text, shape, media, and shadow do not re-layout on independent
animation clocks. Pixel alignment resumes only after the camera settles. The note back is counter-scaled to a
fixed readable viewport and scrolls its own overflow.

A node with an upcoming note step carries a compact, readable, non-interactive note outline in its
top-right corner. Native and HTML use the same folded-note design with a translucent theme-tinted
paper, folded edge, and two quiet text strokes. Its scale is bounded against the current camera
magnification, with no circle, button chrome, or interactive glass treatment. It is not a
conditional **Show note** button,
so the presentation toolbar keeps the same layout on every step. Arrows, Space, Page Up/Page Down,
Home, End, and the on-screen controls navigate the step sequence; Escape returns to the map.
In HTML presentation mode, safe-area-aware Previous and Next chevrons appear midway along the left
and right edges only when that direction has another node or note step. Their 52-point compact-screen
touch targets support iPhone navigation without a keyboard, and the unavailable direction is hidden
at the sequence boundary. Drag to pan, mouse-wheel or pinch to zoom, and use `+`/`-` or `0`/`F` to
zoom or re-focus the current step. Any visible node is a direct click/tap jump target after free
look; navigation then continues from its ordinary place in the complete node/note step sequence.
Sequential next/previous steps pan in a straight line between node centers. The passive note marker
uses a bounded zoom-aware size and inset so it stays legible and clear of the node corner at every
focused scale. `#node=<uuid>` opens that node’s presentation step.

HTML is self-contained except for optional video playback. Images, theme, layout, CSS, and
JavaScript are embedded. A compact fixed inline SVG uses the Brainstorm app icon’s mosaic and
mind-map geometry, recolored from the active theme’s accent and a computed contrasting foreground.
It shares the bottom controls’ centerline on compact screens and links to the public Brainstorm
project page without loading a remote asset; its accessible name is **Made with Brainstorm**. The map always shows compact note-presence icons for every note included
by the export policy; there is no marker visibility switch and the map never renders full note
cards or media beneath nodes. Clicking or tapping a noted node, or focusing it and pressing
Return/Space, flips that map node itself to a bounded note back; Back or Escape restores its title
without a modal or mode switch. In presentation mode the
active note step renders
the complete formatted description, links, and inline images plus a real inline
`youtube-nocookie.com` player without
autoplay on the node’s back. Advancing, reversing away from that step, or returning to the map
removes the player so off-screen content cannot continue playing. Playback requires network access,
an HTTP(S) origin, and the privacy-enhanced player still connects the reader to YouTube. Native
presentation supplies the Brainstorm project’s stable HTTPS origin as YouTube’s required client
identity. When a
reader opens the export directly through `file://`, the note keeps its ordinary YouTube fallback
link; serving the same file unchanged activates the embedded player.

## Safe automation

- Use only `.bs` documents; Brainstorm does not support `.mindmap` files.
- `.bs` files are human-readable sparse JSON. New writes use format v3, which adds typed node notes and prevents older note-unaware apps from silently resaving them away. Existing v1/v2 files remain readable and are upgraded on the next save; stable node UUIDs and explicit style/media/position values are preserved.
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
- The native canvas renders an overscanned visible working set instead of instantiating every off-screen node during pan and zoom. Collapsing a branch compacts visible sibling geometry and canvas bounds, temporarily auto-packing the folded card vertically instead of retaining an expanded-layout offset; reopening it restores that saved offset. All exports (HTML, PNG, PDF, Markdown, Mermaid, PlantUML) always use the complete stored tree through the all-descendants layout policy; fold state is not applied outside the live `.bs` canvas.
- The macOS app remembers inspector visibility, focus mode, and the Notes layer as app-wide workspace preferences across launches and `.bs` files. It defaults off. When on, every non-empty note receives a very small, low-emphasis, non-interactive SF Symbol `note.text` inside its node’s top-right corner and hover/selection may reveal the transient **+ Note**/**Note** action, all without adding preview cards beneath nodes or changing layout spacing, regardless of the note's legacy saved export visibility. The symbol uses the active theme tint with no circle or button chrome. These settings are UI state, not document content, so changing them never dirties a map. The node context menu and ⌥⌘N remain available with the visual layer off; notes are never edited from the presence symbol or inspector.
- The recurring native **Support Brainstorm** sheet is app-wide rather than document content. It waits for a ready key map window and never competes with another sheet, alert, restoration flow, note editor, or presentation. **Maybe later**, closing, and ordinary dismissal store the next eligible date 14 calendar days later. **Don’t show this again** permanently suppresses it until preferences are reset. Opening the X, GitHub Sponsors, Patreon, or Buy Me a Coffee URL has no effect on presentation, recurrence, or opt-out state. A single main-actor coordinator owns the active document claim, so automation or tests must not model the reminder independently per window. The standard **About Brainstorm** panel also contains a **Support Brainstorm** link to GitHub Sponsors; opening it is always available and never mutates reminder state.
- In the macOS app, plain arrows navigate the tree and ⌘+Arrow still reorders or changes depth outside title editing. While editing a title, modifier arrows do not change the tree; Ctrl+Left/Right remains native word/caret navigation and Ctrl+Up/Down is ignored.
- Text export preserves node order, titles, and the full hierarchy, but not canvas styling, media,
  expanded state, or manual positions. Markdown repeats the root as both the `#` heading and the
  top-level list item. Included notes become relative links to separate Markdown documents; the
  exporter packages those documents and extracted note-image assets in a ZIP.
- HTML export is a self-contained, read-only vector/DOM viewer. It writes branches as inline SVG
  paths and nodes as HTML elements at their exact Brainstorm layout positions on a continuous themed
  canvas and grid; it does not embed a full-map screenshot or PNG. Node-local media stays embedded,
  and the export preserves the document theme, manual positions, fully expanded map geometry for
  every stored node, selected note layer, and full presentation sequence. Folded canvas state from
  the `.bs` file is not applied. It provides cursor-anchored wheel zoom, one-finger or mouse
  drag-to-pan, and midpoint-anchored two-finger pinch zoom. Double-click, double-tap, or press `F` to
  fit the map, press `0` to restore 100%, and use `+`/`-` to zoom from the keyboard. It contains no
  `.bs` source JSON and has no remote code/styling dependency. YouTube playback is the only optional
  network load; the compact map never loads note media, while an active presentation note step
  loads its non-autoplay player immediately and tears it down when navigation leaves that step.
  Open it locally or upload the unchanged file to a
  static host; treat every included note in a publicly hosted map as public information.
- Pass `--output -` for any export format to receive only the raw exported bytes on stdout. Do not
  expect the normal JSON response in stdout mode; Markdown bundles stream ZIP bytes.
- The app lists export choices alphabetically with plain labels; CLI format names remain lowercase.

## Validation and recovery

Run validation after automated changes and before distributing a file:

```sh
brainstorm validate launch.bs
brainstorm inspect launch.bs --flat --pretty
```

Validation failures are JSON on stderr with a non-zero exit status. Note validation messages include
a stable code such as `note.alt_text_required` or `note.document_image_budget` and a JSON-style path
to the invalid node/attachment. Fix the reported field and validate again; do not hand-edit embedded
base64 image data.

Before a risky multi-node change, keep the original `.bs` file and preview the exact operation:

```sh
cp launch.bs launch.before-notes.bs
brainstorm apply launch.bs --input changes.json --dry-run --pretty
brainstorm apply launch.bs --input changes.json --pretty
brainstorm validate launch.bs
```

Mutations save atomically. If an update is rejected, the original document remains unchanged. If
an older Brainstorm app reports that version 3 is unsupported, update Brainstorm; do not downgrade
the envelope or open and resave the map with a note-unaware release. For an accidental successful
change, restore the backup or use the macOS app's undo/recovery snapshot workflow.
