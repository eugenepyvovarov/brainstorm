# MindMap — Design (2026-07-13)

Native macOS SwiftUI mindmap with horizontal tree layout and full outliner-style keyboard navigation.

## Goals

- Horizontal tree: root left, children right
- MindNode canvas shortcuts (Tab = child; Return = sibling)
- First-map UX from https://www.mindnode.com/support/guides/create-your-first-mind-map
  - main node starts in edit mode
  - Return / canvas click ends editing
  - node well (+) adds child
  - rewire by drag; delete / option-delete
- Local JSON Open / Save / Save As
- Focused editor chrome (toolbar + canvas)

## Data model

```
MindMapFile { version: 1, root: MindNode }
MindNode { id, title, isExpanded, children: [MindNode] }
```

## Architecture

| Layer | Role |
|-------|------|
| `MindMapStore` | Tree mutations, selection, editing, dirty flag, undo |
| `LayoutEngine` | Horizontal frames + bezier edges |
| `MindMapCanvasView` | Scrollable canvas, nodes, edges, focus |
| `ContentView` | Toolbar, file panels, keyboard routing |
| JSON codec | `.mindmap` files |

## Keyboard map (MindNode-aligned)

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
