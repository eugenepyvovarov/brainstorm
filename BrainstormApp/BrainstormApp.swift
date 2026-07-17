import AppKit
import SwiftUI
import BrainstormFeature

@main
struct BrainstormApp: App {
    /// Receives Finder double-clicks / Dock drops for `.bs` documents.
    @NSApplicationDelegateAdaptor(BrainstormAppDelegate.self) private var appDelegate
    /// Observed so File → Open Recent rebuilds when the list changes.
    @State private var recentDocuments = RecentDocuments.shared

    var body: some Scene {
        Window("Welcome to Brainstorm", id: BrainstormWindowID.welcome) {
            BrainstormWelcomeView()
                .frame(minWidth: 620, minHeight: 480)
        }
        .defaultSize(width: 720, height: 560)

        Window("Theme Manager", id: BrainstormWindowID.themeManager) {
            ThemeManagerView()
                .frame(
                    minWidth: 1_020,
                    maxWidth: .infinity,
                    minHeight: 620,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        }
        .defaultSize(width: 1_280, height: 780)

        WindowGroup(id: BrainstormWindowID.map, for: UUID.self) { $documentID in
            if let documentID {
                ContentView(documentID: documentID)
                    .frame(minWidth: 720, minHeight: 480)
            }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            FileMenuCommands(recents: recentDocuments)

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .brainstormUndo, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    NotificationCenter.default.post(name: .brainstormRedo, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .brainstormShowKeyboardHelp, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}

/// Bridges Launch Services document opens into `ExternalDocumentRouter`.
@MainActor
final class BrainstormAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must be set before the first scene is displayed so ⌘N cannot be
        // auto-grouped by the user's system tabbing preference.
        DocumentWindowTabbing.configureApplicationTabbing()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalDocumentRouter.shared.receive(urls: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Document opens can arrive before the first window; re-check pending URLs.
        if ExternalDocumentRouter.shared.hasPending {
            DocumentSession.shared.beginDocumentOpenLaunch()
            NotificationCenter.default.post(name: .brainstormExternalDocumentsAvailable, object: nil)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // The dedicated welcome window is launched by SwiftUI. Map windows are
        // typed and opened explicitly only after the user chooses a map.
        false
    }
}

/// File menu: New, Open…, Open Recent, Save / Save As…, Export, Close.
private struct FileMenuCommands: Commands {
    @Bindable var recents: RecentDocuments

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Mind Map") {
                NotificationCenter.default.post(name: .brainstormNew, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Tab") {
                NotificationCenter.default.post(name: .brainstormNewTab, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Open…") {
                NotificationCenter.default.post(name: .brainstormOpen, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                if recents.items.isEmpty {
                    Button("No Recent Documents") {}
                        .disabled(true)
                } else {
                    ForEach(recents.items) { item in
                        Button(item.menuTitle) {
                            NotificationCenter.default.post(
                                name: .brainstormOpenRecent,
                                object: item.id
                            )
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        recents.clear()
                    }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                NotificationCenter.default.post(name: .brainstormSave, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As…") {
                NotificationCenter.default.post(name: .brainstormSaveAs, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Menu("Export") {
                Button("PNG Image…") {
                    NotificationCenter.default.post(name: .brainstormExportPNG, object: nil)
                }
                Button("PDF Document…") {
                    NotificationCenter.default.post(name: .brainstormExportPDF, object: nil)
                }
            }

            Button("Close") {
                NotificationCenter.default.post(name: .brainstormClose, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }
}
