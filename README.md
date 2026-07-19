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

- Build and explore ideas visually with folding, focus mode, zoom, and a horizontal tree layout. Mouse-wheel, trackpad, toolbar, and keyboard zoom stay anchored beneath the pointer, while inspector visibility and focus mode are remembered across launches and files.
- Work at keyboard speed: Tab creates a child, Return creates a sibling, and shortcuts cover editing, rearranging, saving, and undo.
- Plain arrow keys navigate the tree. Outside title editing, ⌘+Arrow still reorders or changes node depth; while editing, modifier arrows do not change the tree. Press Space to edit a selected title, use Ctrl+Left/Right for word movement, and Ctrl+Up/Down is disabled while editing.
- Reorganize safely by dragging a node onto another node and confirming the new parent; drag between siblings to reorder or drag aside to change only the visual position.
- Keep working safely with an autosave recovery snapshot after every completed edit, including add, delete, move, reorder, style, rename, undo, and redo actions.
- On every normal launch, choose **New Mind Map**, **Open…**, or one of your five most recent `.bs` files. Opening a `.bs` file from Finder or the Dock goes straight to that map.
- When you reopen a saved map from Recent, Brainstorm restores the window's last size and location, adjusting it to remain visible after monitor changes.
- Style one or many nodes with themes, colors, borders, shapes, typography, emoji, and embedded images.
- Add a second layer of context to any node. Select or hover a node to reveal its transient **+ Note**/**Note** action, or press ⌥⌘N. The node lifts into a centered Apple-native, live-styled composer for formatted text, clickable web links, pasted images, and pasted YouTube links; there is no separate raw-Markdown or media-configuration form. The Notes control shows only small note-presence markers, never full previews beneath nodes, so the map remains readable.
- Present a map as a root-first, depth-first sequence of node and note steps. Brainstorm follows each branch to its leaf before continuing with the next branch, including descendants hidden by a collapsed canvas branch, and inserts every included non-empty note immediately after its node. Presentation is the real expanded mind map viewed through a moving, magnified camera: the active node keeps its natural shape, nearby nodes remain partially visible, and curved connections stay on screen. Moving from a node to its note flips that same node in place; camera travel happens only when navigation moves to a different node.
- Use the toolbar’s **Theme** menu → **Manage Themes…** to browse a compact native Zed Theme Registry inside Brainstorm. The catalog is cached on disk for fast launches and offline fallback; selected extension archives are cached by version. Select an extension, then use Up/Down to move through the results and preview each original Zed palette as a real one-root, two-child Brainstorm map. Import keeps its `themes/*.json` source unchanged, including native Zed JSON5 comments and trailing commas. You can also import a local Zed theme file, set a default for new maps, or remove one imported variant at a time; removing the final variant deletes the unchanged source, and reimporting restores every variant. Theme additions, removals, and default changes appear immediately in open map windows.
- Use the app and `brainstorm` CLI on the same portable JSON `.bs` files; the app handles safe external-file changes.
- Export the complete map to a self-contained, read-only HTML viewer, high-resolution PNG,
  single-page PDF, Markdown nested lists, Mermaid, or PlantUML.
- Choose export formats from a concise alphabetical menu without trailing punctuation.

## Autosave and recovery

The macOS app writes a recovery snapshot immediately after each completed document action, including adding, deleting, moving, reordering, styling, renaming, undo, and redo. While a title is being typed or a node is being dragged, updates are coalesced briefly so Brainstorm does not write once per keystroke or pointer frame. The normal Save command still writes the `.bs` file to its chosen location.

Closing a dirty tab/window or quitting Brainstorm opens the native **Save**, **Don’t Save**, and
**Cancel** review. Application Quit reviews every live dirty map, starting with the active map.
Cancel keeps Brainstorm and all of its maps open. **Don’t Save** removes untitled recovery work or
resets a saved map’s recovery snapshot to the last saved `.bs` bytes, so discarded edits do not
return after relaunch.

Inspector visibility, focus mode, and note-marker visibility are app-wide workspace preferences. Brainstorm restores these choices when it launches and keeps them when you open or switch between `.bs` files; they never modify the map contents or make a document dirty.

## `.bs` file format

`.bs` files are human-readable JSON. New saves use format v3 and sparse encoding: empty child lists, empty media and notes, default styles, and default expanded state are omitted, while custom styling, media, typed notes, manual positions, stable UUIDs, and document themes remain explicit. Existing v1/v2 files remain readable and are upgraded to v3 the next time Brainstorm or the CLI saves them. Format v3 prevents an older Brainstorm release that does not understand notes from silently discarding them.

## Node notes

The map never reserves permanent space for note controls. Turn on the default-off Notes layer,
then hover or select a node to reveal a transient **+ Note** action beneath it; a node with content
shows **Note** instead. Click the action, use the node’s **Add Note**/**Open Note** context-menu
command, or press ⌥⌘N for the selected node. The context menu and shortcut remain available while
the visual Notes layer is off.
The node animates into a centered foreground composer and the map becomes a dimmed,
non-interactive backdrop until you choose **Done**, press Escape, or use ⌥⌘N again. This does not
change the normal map workflow: with the composer closed, Tab still creates a child and Return
still creates a sibling.

Brainstorm uses an Apple-native AppKit/TextKit attributed editor for a strict WYSIWYG contract. It
is not a web view, live-Markdown surface, or raw-source panel: the visible TextKit storage contains
only rich text, so moving the caret or clicking an image never reveals Markdown punctuation.
Brainstorm converts that attributed content to portable Markdown only at the `.bs` persistence
boundary and deliberately exposes and persists only
paragraphs, line breaks, bold, italic, bulleted lists, numbered lists, and clickable HTTP(S) links;
unsupported Markdown remains literal text. No headings, code,
tables, tasks, wiki links, or LaTeX features are enabled. Brainstorm continues to store this small,
deterministic Markdown subset underneath so `.bs` files, the CLI, and Markdown export remain
portable. Use ⌘B/⌘I for emphasis and ⇧⌘8/⇧⌘7 for bulleted or numbered lists. Paste or type a
YouTube URL anywhere in the note, including as a labeled Markdown link: the clickable link stays
visible in the editor and Brainstorm also prepares its embedded presentation player. Paste images
or drag one or several image files from Finder into the composer and every accepted image appears
inline in insertion order while Brainstorm stores the validated images. Image blocks are bounded
to 320×220 points, remain images when clicked,
and do not take text focus away from the editor. The editor never shows attachment chips or
image-embed Markdown source—there are no Image/YouTube buttons, players, description fields, or
other media-configuration panels in the composer.

An image requires alternative text and may have a description in the file/CLI model. Brainstorm
uses the pasted filename or a safe generic label in the app, while the CLI can set explicit
alternative text and captions. Brainstorm decodes the pasted or dropped file,
strips metadata, bounds it to a 2,048-pixel long edge and 4,194,304 pixels, then stores a normalized
PNG inside the `.bs` document. A normalized image may be at most 5 MB; all note images in one
document may total at most 20 MB. A note may contain up to 32 ordered attachments. YouTube accepts
an 11-character video ID or a supported `youtube.com`/`youtu.be` URL and stores only the validated
ID, optional start time, and description.

The Notes button on the canvas starts off for a fresh installation. Turning it on reveals the
transient **+ Note**/**Note** action when a node is selected or hovered and shows a very small,
low-emphasis, non-interactive SF Symbol `note.text` inside the top-right corner of every node with
a non-empty note, without changing layout spacing. Its tint comes from the active Brainstorm theme
and it has no circle or button chrome. The symbol is a presence indicator only, and the map never
places full note previews under nodes. The context menu and ⌥⌘N remain available when the visual
note layer is off. The app does not expose per-note show/hide UI: if the Notes layer is on, note
presence is visible. Older files and the CLI can still carry the legacy shown/hidden export value
for compatibility, but it no longer suppresses the native map marker. A hidden export value is not
a privacy feature: its content remains in the `.bs` file, and an “all notes” export can include it.

HTML and Markdown export panels offer **Shown notes only**, **All notes**, and **No notes**. The
CLI equivalents are `--notes visible`, `--notes all`, and `--notes none`; `visible` is the default.
PNG and PDF always export the clean mind map without note markers, note cards, text, or attachments,
regardless of the selected note policy. For HTML and Markdown, use `none` when the exported bytes
must not contain note text or attachments. Markdown with no included notes remains one `.md`
outline. If at least one note is included, Brainstorm
writes a `.zip` containing `map.md`, one linked `notes/*.md` file per node note, and extracted
`assets/*.png` files for note images. Notes are not added to Mermaid or PlantUML output.

## Presentation mode

Choose **Presentation → Start Presentation**, press ⌥⌘Return, or use the toolbar’s **Present**
button. Brainstorm begins on the currently selected node’s title face; if there is no valid
selection, it begins at the root. This changes only the entry point: the complete sequence remains
available, so Previous can reach earlier steps and Home always returns to the root. Brainstorm
enters full screen and freezes the current map as a deterministic sequence: each node appears in
root-first depth-first preorder, and every included non-empty note is a separate step immediately
after its node. Progress counts both kinds of step, so a route is
`node → note back → next depth-first node`, with previous navigation retracing that sequence
exactly: from the next node, Previous first restores the earlier node’s note back, then restores
that node’s title face. The presentation surface is the real fully expanded map, not a stack of generic slide
cards. The current node is magnified while preserving its natural aspect, shape, fill, typography,
and media; nearby nodes remain partially visible at their real map positions. After reaching a
branch leaf, the camera visibly travels back through the lowest common ancestor before entering
the next branch. Normal motion uses the full 3D turn; Reduce Motion keeps the relationship legible
with a shorter, restrained turn instead of removing the transition. Reduce Transparency is also
respected. Solid curved connection lines—with no arrowheads—remain visible throughout the scene.

Use Left/Up/Page Up for the previous step; Right/Down/Space/Page Down for the next step; Home/End
for the first/last step; and Escape or the on-screen control to exit. Click a visible nearby node
to jump to its node step. A node with an upcoming note step carries a compact, readable,
theme-tinted folded-note glyph inside its top-right corner. Its translucent paper, folded edge,
and two quiet text strokes scale with presentation magnification within restrained bounds. It has
no circle, button chrome, or interactive glass treatment;
there is no conditional **Show note** button, so the presentation toolbar keeps a stable footprint.
Advancing from that node performs an in-place 3D flip to its bounded rounded-square note back
without moving the camera. Advancing again flips the note away and starts spatial camera travel to
the next node. The note is literally the reverse side of the presented node, never a modal, AJAX
window, or floating overlay. Nodes without notes never acquire a square slide container or an
extra step. Formatted text, links, images, and descriptions remain normal content; a YouTube
attachment remains inline on that same note back and shows the real
`youtube-nocookie.com` player at 16:9 on the active note step, with the canonical YouTube link as
a fallback. The native player identifies Brainstorm with the project’s HTTPS origin so YouTube
receives its required referrer without exposing document content. Leaving that step tears the
player down so audio cannot continue off screen.

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
brainstorm update plan.bs --node root \
  --note-text $'Context with **emphasis**.\n\n1. First step\n2. Second step' \
  --note-visible shown
brainstorm update plan.bs --node root \
  --note-image diagram.jpg --note-image-alt "Launch dependency diagram"
brainstorm update plan.bs --node root \
  --note-youtube "https://youtu.be/M7lc1UVf-VE?t=42" \
  --note-youtube-caption "Reference walkthrough"
brainstorm export plan.bs --format html --notes visible --output plan.html
brainstorm export plan.bs --format html --notes all --presentation --output slides.html
brainstorm export plan.bs --format pdf --notes none --output plan.pdf
brainstorm export plan.bs --format markdown --notes all --output plan.zip
brainstorm export plan.bs --format mermaid --output plan.mmd
brainstorm export plan.bs --format plantuml --output plan.puml
brainstorm export plan.bs --format markdown --output -
```

Text exports always include the complete tree, including children below collapsed nodes. Markdown
starts with the root as an `#` heading and repeats it as the top-level bullet before its nested list.
Nodes with included notes append a relative **Note** link to a separate Markdown file. Repeated or
filesystem-unsafe titles remain safe because each note filename includes the node UUID. With `--notes none`,
or when the selected policy finds no notes, the result is one `.md`; otherwise the result is a ZIP.
Use `--output -` with any format to stream the raw export to stdout instead of writing a file; stdout
mode omits the normal JSON response, so both text and binary exports are safe to pipe or redirect.
For Markdown this means UTF-8 Markdown bytes for a single-file result and ZIP bytes for a bundle.

### HTML viewer and sharing

HTML export writes a true vector/DOM map into one `.html` file: branches are inline SVG paths,
nodes are HTML elements at their exact Brainstorm layout positions, and the themed canvas and grid
continue across the browser viewport. It is not a screenshot or a full-map PNG. The result
preserves the selected theme, node-local embedded media, emoji, SF Symbols, manual positions, and
collapsed state. Drag with a mouse or one finger to pan. Use the mouse wheel, trackpad, or a
two-finger pinch to zoom beneath the pointer or live touch midpoint. Double-click, double-tap, or
press `F` to fit the map, press `0` to restore 100%, and use `+`/`-` to zoom.

Use the viewer’s **Map** and **Present** controls without regenerating the file. Note icons are
always visible for every note included by the export policy; there is no separate marker switch.
Click or tap a noted node—or focus it and press Return/Space—to flip that map node itself to its
screen-bounded note back. Use **Back** or Escape to turn it back to the title; the viewer does not
open a modal or switch modes.
The map stays compact: each node whose included note is present can show a very small,
low-emphasis, inline Tabler note outline in its top-right corner, tinted from the active Brainstorm
theme with no circle or button chrome and never a full preview beneath the node. The outline is not
interactive. Presentation uses the same complete depth-first node order as the app and inserts
each included non-empty note as the step immediately after its node. Progress includes both node
and note steps. Node-to-note navigation flips the same element in place with a full 3D CSS
transition during normal motion; Reduce Motion uses a quick crossfade without perspective.
Navigation between different nodes performs the spatial branch-return camera travel.
Cross-branch travel bends continuously toward the common ancestor instead of briefly landing on
each intermediate parent and rebounding.
The focused HTML node keeps a readable minimum zoom at rest; a long branch return
temporarily pulls back to show the route, then zooms into the destination. Safari advances the
world and grid from one animation-frame timeline, and keyboard focus follows the newly current
node so repeated arrow navigation never stalls. In both the app and HTML viewer, connection lines
and each node's complete rendered
surface—shape, text, media, and shadow—share that single camera animation and easing, so no layer
lags or arrives early. Pixel alignment is applied only after travel settles. The viewer then
returns to a pixel-aligned 2D camera and applies
shadow compositing only to the node shape, keeping Safari node text as sharp as normal map mode.
Partial neighboring nodes remain at their real fully expanded map coordinates, and solid
connection lines stay visible without arrowheads. Note backs remain a fixed readable card size,
with overflow scrolling inside the card. The toolbar does not add or remove a
**Show note** action between steps, so it never jumps. Navigate with arrow keys, Space, Page
Up/Page Down, Home/End, or by clicking a nearby node. Presentation also shows safe-area-aware
Previous and Next chevrons at the left and right edges whenever that direction has another node
or note step. Their 52-point touch targets make the complete sequence usable on iPhone without a
keyboard; the unavailable edge control disappears at the beginning or end. Any visible node in
the presentation world is also a jump target: click or tap it to continue the same complete
node/note sequence from that node. Note markers keep a bounded proportional size and inset across
focused-node zoom levels instead of looking tiny or crowding the rounded corner. Escape returns to the map. Use
`--presentation` to make an HTML export open in presentation mode. A `#node=<uuid>` URL fragment
opens that node’s presentation step.

The viewer has no code or styling dependencies and does not contain the source `.bs` JSON.
Every HTML export includes the Brainstorm app-icon mark as a compact inline SVG at the bottom,
using the same mosaic and mind-map geometry as the app itself but recolored from the active theme’s
accent and a computed contrasting foreground. It links to the Brainstorm project page without
loading any remote asset. On compact screens it shares the bottom controls’ centerline. Its
accessible name remains **Made with Brainstorm**.
Embedded note images stay in the file. In presentation mode, the active visible slide instantiates
the real `youtube-nocookie.com` player without autoplay on its note back; moving to another step or
returning to the map removes that iframe so off-screen playback cannot continue. Note content is
rendered on the flipping node itself, not in a modal or AJAX overlay, and the compact map never
loads note media. Video playback requires a network connection and an HTTP(S) origin, and
“privacy-enhanced” mode still connects the reader’s browser to YouTube. A directly opened
`file://` export keeps the ordinary YouTube fallback link; serve or publish the unchanged file to
activate the embedded player. The rest of the viewer remains fully functional when opened locally.
Publish through a static host such as
[GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages).
Anything included in a file published on a public static site should be treated as public. Use
`--notes none` when the published file must contain no note payload.

Homebrew links the release CLI at `$(brew --prefix)/bin/brainstorm` (`/opt/homebrew/bin/brainstorm` on Apple Silicon and `/usr/local/bin/brainstorm` on Intel Macs). See [`brainstorm-skill/SKILL.md`](brainstorm-skill/SKILL.md) for installation checks, recovery steps, and agent-oriented usage.

For source development, the repository-local `./brainstorm` wrapper builds and runs the CLI with Swift. Open `Brainstorm.xcworkspace` in Xcode to build the macOS app.
