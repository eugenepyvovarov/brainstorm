# MindMap - macOS App

A native macOS mind map editor with horizontal tree layout and **MindNode-style** keyboard and first-map UX ([create your first mind map](https://www.mindnode.com/support/guides/create-your-first-mind-map)).

## Quick start

Open `MindMap.xcworkspace` in Xcode, or:

```bash
xcodebuildmcp macos build-and-run --workspace-path MindMap.xcworkspace --scheme MindMap
```

## Keyboard shortcuts (MindNode-aligned)

Canvas shortcuts follow [MindNode’s keyboard model](https://www.mindnode.com/support/guides/keyboard-shortcuts):

| Key | Action |
|-----|--------|
| **Tab** | New **child** node |
| **Return** | New **sibling** node |
| **⌥Return** | New sibling **above** |
| **⌥Tab** | New **parent** node |
| **⇧Return** | New **main** node (child of root) |
| **⌘Return** | Edit node title |
| **Type / double-click** | Edit (type replaces title) |
| **Esc** | End edit / deselect |
| **↑ ↓ ← →** | Move selection (← parent, → first child) |
| **⌥.** | Fold / unfold branch |
| **⌘↑ / ⌘↓** | Move among siblings |
| **⌘→ / ⌘←** | Indent / outdent |
| **⌫** | Delete node + subtree |
| **⌥⌫** | Delete node only (promote children) |
| **⌘R** | Go to main (root) node |
| **⌘S / ⌘O / ⌘N** | Save / Open / New |
| **⌘Z / ⇧⌘Z** | Undo / Redo |

### First-map UX (from MindNode’s guide)

- New document opens with the **main node already in edit mode** — type the topic immediately
- **Return** or **click the canvas** ends editing
- **Double-click** a node to rename anytime
- **Node well (+)** appears on hover/selection — click to add a child idea (same as Tab)
- **Drag a node onto another** to rewire (change parent)
- **Right-click** for Edit / Add Child / Delete / Delete Node Only
- **⌫** deletes a node and its branch; **⌥⌫** deletes only that node and keeps children

Maps are saved as `.mindmap` JSON files (Open / Save / Save As in the toolbar).

## Architecture

A modern macOS application using a **workspace + SPM package** architecture for clean separation between app shell and feature code.

## Project Architecture

```
MindMap/
├── MindMap.xcworkspace/              # Open this file in Xcode
├── MindMap.xcodeproj/                # App shell project
├── MindMap/                          # App target (minimal)
│   ├── Assets.xcassets/                # App-level assets (icons, colors)
│   ├── MindMapApp.swift              # App entry point
│   ├── MindMap.entitlements          # App sandbox settings
│   └── MindMap.xctestplan            # Test configuration
├── MindMapPackage/                   # 🚀 Primary development area
│   ├── Package.swift                   # Package configuration
│   ├── Sources/MindMapFeature/       # Your feature code
│   └── Tests/MindMapFeatureTests/    # Unit tests
└── MindMapUITests/                   # UI automation tests
```

## Key Architecture Points

### Workspace + SPM Structure
- **App Shell**: `MindMap/` contains minimal app lifecycle code
- **Feature Code**: `MindMapPackage/Sources/MindMapFeature/` is where most development happens
- **Separation**: Business logic lives in the SPM package, app target just imports and displays it

### Buildable Folders (Xcode 16)
- Files added to the filesystem automatically appear in Xcode
- No need to manually add files to project targets
- Reduces project file conflicts in teams

### App Sandbox
The app is sandboxed by default with basic file access permissions. Modify `MindMap.entitlements` to add capabilities as needed.

## Development Notes

### Code Organization
Most development happens in `MindMapPackage/Sources/MindMapFeature/` - organize your code as you prefer.

### Public API Requirements
Types exposed to the app target need `public` access:
```swift
public struct SettingsView: View {
    public init() {}
    
    public var body: some View {
        // Your view code
    }
}
```

### Adding Dependencies
Edit `MindMapPackage/Package.swift` to add SPM dependencies:
```swift
dependencies: [
    .package(url: "https://github.com/example/SomePackage", from: "1.0.0")
],
targets: [
    .target(
        name: "MindMapFeature",
        dependencies: ["SomePackage"]
    ),
]
```

### Test Structure
- **Unit Tests**: `MindMapPackage/Tests/MindMapFeatureTests/` (Swift Testing framework)
- **UI Tests**: `MindMapUITests/` (XCUITest framework)
- **Test Plan**: `MindMap.xctestplan` coordinates all tests

## Configuration

### XCConfig Build Settings
Build settings are managed through **XCConfig files** in `Config/`:
- `Config/Shared.xcconfig` - Common settings (bundle ID, versions, deployment target)
- `Config/Debug.xcconfig` - Debug-specific settings  
- `Config/Release.xcconfig` - Release-specific settings
- `Config/Tests.xcconfig` - Test-specific settings

### App Sandbox & Entitlements
The app is sandboxed by default with basic file access. Edit `MindMap/MindMap.entitlements` to add capabilities:
```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<!-- Add other entitlements as needed -->
```

## macOS-Specific Features

### Window Management
Add multiple windows and settings panels:
```swift
@main
struct MindMapApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        
        Settings {
            SettingsView()
        }
    }
}
```

### Asset Management
- **App-Level Assets**: `MindMap/Assets.xcassets/` (app icon with multiple sizes, accent color)
- **Feature Assets**: Add `Resources/` folder to SPM package if needed

### SPM Package Resources
To include assets in your feature package:
```swift
.target(
    name: "MindMapFeature",
    dependencies: [],
    resources: [.process("Resources")]
)
```

## Notes

### Generated with XcodeBuildMCP
This project was scaffolded using [XcodeBuildMCP](https://github.com/cameroncooke/XcodeBuildMCP), which provides tools for AI-assisted macOS development workflows.