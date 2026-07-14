# Brainstorm — Design (2026-07-13)

Native macOS SwiftUI brainstorm with horizontal tree layout and full outliner-style keyboard navigation.

## Goals

- Horizontal tree: root left, children right
- BrainstormNode canvas shortcuts (Tab = child; Return = sibling)
- First-map UX from https://www.mindnode.com/support/guides/create-your-first-mind-map
  - main node starts in edit mode
  - Return / canvas click ends editing
  - node well (+) adds child
  - rewire by drag; delete / option-delete
- Local JSON Open / Save / Save As
- Focused editor chrome (toolbar + canvas)

## Data model

```
BrainstormFile { version: 1, root: BrainstormNode }
BrainstormNode { id, title, isExpanded, children: [BrainstormNode] }
```

## Architecture

| Layer | Role |
|-------|------|
| `BrainstormStore` | Tree mutations, selection, editing, dirty flag, undo |
| `LayoutEngine` | Horizontal frames + bezier edges |
| `BrainstormCanvasView` | Scrollable canvas, nodes, edges, focus |
| `ContentView` | Toolbar, file panels, keyboard routing |
| JSON codec | `.bs` files only |

## Keyboard map (BrainstormNode-aligned)

Source: https://www.mindnode.com/support/guides/keyboard-shortcuts

| Key | Action |
|-----|--------|
| Tab | New **child** |
| Return | New **sibling** |
| ⌥Return | Sibling above |
| ⌥Tab | New parent |
| ⇧Return | New main node (child of root) |
| ⌘Return | Edit title |
| ↑ ↓ ← → | Navigate selection |
| ⌥. | Fold/unfold |
| ⌘↑ / ⌘↓ | Reorder siblings |
| ⌘→ / ⌘← | Indent / outdent |
| ⌫ | Delete subtree |
| ⌥⌫ | Delete single (promote children) |
| Esc | Cancel edit / deselect |
| ⌘R | Go to main node |
| ⌘S / ⌘O / ⌘N | Save / Open / New |

## File format

```json
{
  "version": 1,
  "root": {
    "id": "…",
    "title": "Central Idea",
    "isExpanded": true,
    "children": []
  }
}
```
