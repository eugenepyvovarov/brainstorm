import Foundation
import XCTest

final class BrainstormUITests: XCTestCase {
    private var app: XCUIApplication!
    private var testSessionID: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        testSessionID = UUID().uuidString
        app = XCUIApplication()
        app.launchEnvironment["BRAINSTORM_UI_TEST_SESSION_ID"] = testSessionID
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-Brainstorm.ui.showInspector", "YES",
            "-Brainstorm.ui.focusMode", "NO",
            "-Brainstorm.ui.showNotesLayer", "YES",
        ]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func testRapidNewTabsTabBarPlusAndNewWindow() throws {
        launchApp()
        XCTAssertEqual(app.windows.count, 1)

        // Exercise the race that used to share one global "next window" slot.
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)

        let tabBar = app.tabGroups.firstMatch
        XCTAssertTrue(waitUntil { tabBar.exists && tabBar.tabs.count == 3 })

        // AppKit only exposes this button when newWindowForTab: is visible in
        // the responder chain. Clicking it verifies the native + path end-to-end.
        let newTabButton = tabBar.buttons["new tab"]
        XCTAssertTrue(newTabButton.waitForExistence(timeout: 2))
        newTabButton.click()
        XCTAssertTrue(
            waitUntil { tabBar.tabs.count == 4 },
            "After tab-bar +: tabs=\(tabBar.tabs.count), windows=\(app.windows.count)\n\(app.debugDescription)"
        )

        // ⌘N must remain a separate top-level window, independent of the
        // user's system preference for automatic window tabs.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitUntil { self.app.windows.count == 2 })
        XCTAssertEqual(tabBar.tabs.count, 4)
    }

    @MainActor
    func testNewTabTargetsOnlyTheKeyWindowWhenTwoMapGroupsAreOpen() throws {
        launchApp()
        XCTAssertEqual(app.windows.count, 1)

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitUntil {
            self.app.tabGroups.firstMatch.exists
                && self.app.tabGroups.firstMatch.tabs.count == 2
        })

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitUntil { self.app.windows.count == 2 })

        app.typeKey("t", modifierFlags: .command)

        XCTAssertTrue(
            waitUntil {
                guard self.app.windows.count == 2, self.app.tabGroups.count == 2 else {
                    return false
                }
                let tabCounts = (0 ..< self.app.tabGroups.count)
                    .map { self.app.tabGroups.element(boundBy: $0).tabs.count }
                    .sorted()
                return tabCounts == [2, 2]
            },
            "One ⌘T should add one tab only to the key map window.\n\(app.debugDescription)"
        )
        XCTAssertEqual(app.windows.count, 2)
    }

    @MainActor
    func testNewTabFromThemeManagerTargetsOnlyTheLastActiveMap() throws {
        launchApp()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitUntil { self.app.windows.count == 2 })

        let themeMenu = app.toolbars.menuButtons.element(boundBy: 0)
        XCTAssertTrue(themeMenu.waitForExistence(timeout: 2), app.debugDescription)
        themeMenu.click()
        let manageThemes = app.menuItems["Manage Themes…"]
        XCTAssertTrue(manageThemes.waitForExistence(timeout: 2), app.debugDescription)
        manageThemes.click()

        XCTAssertTrue(app.windows["Theme Manager"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.windows.count, 3)

        app.typeKey("t", modifierFlags: .command)

        XCTAssertTrue(
            waitUntil {
                guard self.app.windows.count == 3, self.app.tabGroups.count == 1 else {
                    return false
                }
                return self.app.tabGroups.firstMatch.tabs.count == 2
            },
            "⌘T from Theme Manager should add one tab to the last active map only.\n\(app.debugDescription)"
        )
    }

    @MainActor
    func testFreshLaunchShowsWelcomeScreen() throws {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["welcomeNewMap"].exists)
        XCTAssertTrue(app.buttons["welcomeOpenMap"].exists)
        XCTAssertTrue(app.staticTexts["welcomeRecentMaps"].exists)
    }

    @MainActor
    func testWelcomeOpensDormantRecentSessionDocumentWithoutBlankPlaceholder() throws {
        let mapTitle = "Dormant Recent Fixture"
        let childTitle = "Recovered child fixture"
        app.launchEnvironment["BRAINSTORM_UI_TEST_DORMANT_RECENT_TITLE"] = mapTitle
        app.launchEnvironment["BRAINSTORM_UI_TEST_DORMANT_RECENT_CHILD"] = childTitle

        app.launch()
        XCTAssertTrue(app.buttons["welcomeNewMap"].waitForExistence(timeout: 5))

        let recentButton = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", mapTitle))
            .firstMatch
        XCTAssertTrue(
            recentButton.waitForExistence(timeout: 3),
            "Seeded recent map should appear on Welcome.\n\(app.debugDescription)"
        )
        recentButton.click()

        XCTAssertTrue(
            waitUntil { !self.app.buttons["welcomeNewMap"].exists },
            "Opening a recent map should dismiss Welcome.\n\(app.debugDescription)"
        )

        let mapWindow = app.windows[mapTitle]
        XCTAssertTrue(
            mapWindow.waitForExistence(timeout: 5),
            "The dormant session document should reopen with its saved title.\n\(app.debugDescription)"
        )

        let fixtureChild = mapWindow.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label == %@ OR value == %@",
                childTitle,
                childTitle
            ))
            .firstMatch
        XCTAssertTrue(
            fixtureChild.waitForExistence(timeout: 3),
            "The reopened window should render the seeded map, not a blank document.\n\(app.debugDescription)"
        )

        XCTAssertTrue(
            waitUntil {
                guard self.app.windows.count == 1 else { return false }
                let tabGroup = self.app.tabGroups.firstMatch
                return !tabGroup.exists || tabGroup.tabs.count == 1
            },
            "Opening one recent map must not leave an Untitled window or duplicate tab.\n\(app.debugDescription)"
        )
        XCTAssertFalse(app.windows["Untitled"].exists)
    }

    @MainActor
    func testClosedTabDoesNotReturnAfterRelaunch() throws {
        launchApp()
        app.typeKey("t", modifierFlags: .command)

        let tabBar = app.tabGroups.firstMatch
        XCTAssertTrue(waitUntil { tabBar.exists && tabBar.tabs.count == 2 })

        let selectedTab = tabBar.tabs.element(boundBy: 1)
        let closeButton = selectedTab.buttons.matching(identifier: "_closeButton").firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
        closeButton.click()
        // A newly created map is intentionally dirty. Confirm the standard
        // close-without-saving path before checking session cleanup.
        let dontSaveButton = app.dialogs.buttons["Don’t Save"]
        if dontSaveButton.waitForExistence(timeout: 2) {
            dontSaveButton.click()
        }
        XCTAssertTrue(
            waitUntil { !tabBar.exists || tabBar.tabs.count == 1 },
            "After tab close: tabs=\(tabBar.tabs.count), windows=\(app.windows.count), sheets=\(app.sheets.count)\n\(app.debugDescription)"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        // Session restoration is delayed briefly to allow Finder-open routing.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(app.tabGroups.firstMatch.exists && app.tabGroups.firstMatch.tabs.count > 1)
    }

    @MainActor
    func testCommandWClosesOnlyTheSelectedTab() throws {
        launchApp()
        app.typeKey("t", modifierFlags: .command)

        let tabBar = app.tabGroups.firstMatch
        XCTAssertTrue(waitUntil { tabBar.exists && tabBar.tabs.count == 2 })

        app.typeKey("w", modifierFlags: .command)
        let dontSaveButton = app.dialogs.buttons["Don’t Save"]
        if dontSaveButton.waitForExistence(timeout: 2) {
            dontSaveButton.click()
        }

        XCTAssertTrue(
            waitUntil { !tabBar.exists || tabBar.tabs.count == 1 },
            "⌘W should close one selected tab, not the entire tab group.\n\(app.debugDescription)"
        )
        XCTAssertEqual(app.windows.count, 1)
    }

    @MainActor
    func testCommandQReviewsUnsavedChangesBeforeTerminating() throws {
        let mapTitle = "Quit Review Fixture"
        let savedChildTitle = "Last saved child"
        let editedChildTitle = "Unsaved replacement"
        app.launchEnvironment[
            "BRAINSTORM_UI_TEST_DORMANT_RECENT_TITLE"
        ] = mapTitle
        app.launchEnvironment[
            "BRAINSTORM_UI_TEST_DORMANT_RECENT_CHILD"
        ] = savedChildTitle

        app.launch()
        XCTAssertTrue(app.buttons["welcomeNewMap"].waitForExistence(timeout: 5))
        let recentButton = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", mapTitle))
            .firstMatch
        XCTAssertTrue(recentButton.waitForExistence(timeout: 3))
        recentButton.click()

        let mapWindow = app.windows[mapTitle]
        XCTAssertTrue(mapWindow.waitForExistence(timeout: 5), app.debugDescription)
        let savedChild = mapWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", savedChildTitle))
            .firstMatch
        XCTAssertTrue(waitForHittable(savedChild), app.debugDescription)
        savedChild.doubleClick()

        let titleEditor = mapWindow.textViews
            .matching(NSPredicate(format: "value == %@", savedChildTitle))
            .firstMatch
        XCTAssertTrue(waitForHittable(titleEditor), app.debugDescription)
        titleEditor.click()
        titleEditor.typeKey("a", modifierFlags: .command)
        titleEditor.typeText(editedChildTitle)

        let editedEditor = mapWindow.textViews
            .matching(NSPredicate(format: "value == %@", editedChildTitle))
            .firstMatch
        XCTAssertTrue(editedEditor.waitForExistence(timeout: 3), app.debugDescription)
        app.typeKey(.return, modifierFlags: .command)

        let editedChild = mapWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", editedChildTitle))
            .firstMatch
        XCTAssertTrue(
            waitUntil {
                editedChild.exists && !editedEditor.exists
            },
            "The committed unsaved title must be visible before testing Quit."
        )

        app.typeKey("q", modifierFlags: .command)
        let saveButton = app.dialogs.buttons["Save"]
        let dontSaveButton = app.dialogs.buttons["Don’t Save"]
        let cancelButton = app.dialogs.buttons["Cancel"]
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 5)
                && dontSaveButton.exists
                && cancelButton.exists,
            "Cmd-Q must show the native Save / Don’t Save / Cancel review.\n\(app.debugDescription)"
        )

        cancelButton.click()
        app.activate()
        XCTAssertTrue(
            waitUntil {
                self.app.state == .runningForeground
                    && !self.app.dialogs.buttons["Cancel"].exists
            },
            "Cancel must keep Brainstorm and its dirty document open."
        )
        XCTAssertTrue(
            editedChild.waitForExistence(timeout: 3),
            "Cancel must preserve the unsaved edit."
        )

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(dontSaveButton.waitForExistence(timeout: 5))
        dontSaveButton.click()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 8),
            "Don’t Save should approve application termination."
        )

        // Relaunch without reseeding: the original file/session must remain,
        // while the explicitly discarded recovery bytes must not reappear.
        app.launchEnvironment.removeValue(
            forKey: "BRAINSTORM_UI_TEST_DORMANT_RECENT_TITLE"
        )
        app.launchEnvironment.removeValue(
            forKey: "BRAINSTORM_UI_TEST_DORMANT_RECENT_CHILD"
        )
        app.launch()

        let restoredWindow = app.windows[mapTitle]
        if !restoredWindow.waitForExistence(timeout: 5) {
            XCTAssertTrue(
                app.buttons["welcomeNewMap"].waitForExistence(timeout: 3)
            )
            let restoredRecentButton = app.buttons
                .matching(
                    NSPredicate(
                        format: "label BEGINSWITH %@",
                        mapTitle
                    )
                )
                .firstMatch
            XCTAssertTrue(restoredRecentButton.waitForExistence(timeout: 3))
            restoredRecentButton.click()
        }

        let restoredSavedChild = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label == %@ OR value == %@",
                    savedChildTitle,
                    savedChildTitle
                )
            )
            .firstMatch
        XCTAssertTrue(
            restoredSavedChild.waitForExistence(timeout: 5),
            "Don’t Save must restore the last saved document content."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "label == %@ OR value == %@",
                        editedChildTitle,
                        editedChildTitle
                    )
                )
                .firstMatch
                .exists,
            "Discarded recovery content must not reappear after relaunch."
        )
    }

    @MainActor
    func testRelaunchReturnsToWelcomeScreenInsteadOfRestoringTabs() throws {
        launchApp()
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)

        let tabBar = app.tabGroups.firstMatch
        XCTAssertTrue(waitUntil { tabBar.exists && tabBar.tabs.count == 3 })
        let firstTab = tabBar.tabs.element(boundBy: 0)
        firstTab.click()
        XCTAssertTrue(waitUntil { self.isSelected(firstTab) })

        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["welcomeNewMap"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabGroups.firstMatch.exists)
    }

    @MainActor
    func testShiftClickSelectsMultipleNodesForBatchStyling() throws {
        launchApp()

        app.typeText("Root")
        app.typeKey(.tab, modifierFlags: [])
        app.typeText("First")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Second")
        app.typeKey(.return, modifierFlags: .command)

        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "First"))
            .firstMatch
        let second = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "Second"))
            .firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(second.waitForExistence(timeout: 3), app.debugDescription)

        first.click()
        XCTAssertTrue(
            waitUntil { first.isSelected },
            "The first click must settle before extending the selection.\n\(app.debugDescription)"
        )
        XCUIElement.perform(withKeyModifiers: .shift) {
            second.click()
        }

        let summary = app.staticTexts["styleSelectionSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertEqual(summary.value as? String, "Style · 2 nodes")
    }

    @MainActor
    func testShiftReturnInsertsManualLineBreakWithoutAddingNode() throws {
        launchApp()

        app.typeText("Line one")
        app.typeKey(.return, modifierFlags: .shift)
        app.typeText("Line two")
        app.typeKey(.return, modifierFlags: .command)

        let multilineNode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "Line one\nLine two"))
            .firstMatch
        XCTAssertTrue(multilineNode.waitForExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    func testPresentationStartsFromSelectedNodeAndKeepsEarlierSteps() throws {
        launchApp()

        app.typeText("Root")
        app.typeKey(.tab, modifierFlags: [])
        app.typeText("First")
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Second")
        app.typeKey(.return, modifierFlags: .command)

        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "First"))
            .firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3), app.debugDescription)
        first.click()
        XCTAssertTrue(
            waitUntil { first.isSelected },
            "The selected branch must settle before presentation starts.\n\(app.debugDescription)"
        )

        let present = app.buttons["startPresentation"]
        XCTAssertTrue(present.waitForExistence(timeout: 3), app.debugDescription)
        present.click()

        // The outer presentation accessibility container deliberately groups
        // its descendants, so use the stable spoken labels exposed to VoiceOver
        // instead of relying on descendant identifiers that SwiftUI coalesces.
        let current = app.groups
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Step "))
            .firstMatch
        let progress = app.staticTexts
            .matching(NSPredicate(format: "value == %@", "2 of 3"))
            .firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                current.exists && current.label.contains("First")
            },
            "Presentation should open on the selected node title.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            progress.waitForExistence(timeout: 3),
            "The selected node should keep its original position in the full sequence."
        )

        let previous = app.buttons["Previous"]
        XCTAssertTrue(waitUntil(timeout: 8) { previous.isEnabled && previous.isHittable })
        previous.click()
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                current.exists && current.label.contains("Root")
            },
            "Previous should still reach nodes before the selected starting point."
        )

        let next = app.buttons["Next"]
        XCTAssertTrue(waitUntil(timeout: 8) { next.isEnabled && next.isHittable })
        next.click()
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                current.exists && current.label.contains("First")
            }
        )
        XCTAssertTrue(waitUntil(timeout: 8) { next.isEnabled && next.isHittable })
        next.click()
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                current.exists && current.label.contains("Second")
            },
            "Forward navigation should continue after the selected starting point."
        )
    }

    @MainActor
    func testNodeNotePillOpensCenteredEditorAndEscapeReturnsToNormalCreation() throws {
        launchApp()

        let mapWindow = app.windows.firstMatch
        XCTAssertTrue(
            waitUntil {
                self.app.windows.count == 1
                    && !self.app.buttons["welcomeNewMap"].exists
                    && mapWindow.exists
            },
            app.debugDescription
        )

        // A fresh map's "Main Idea" is a drawn placeholder; the native title
        // editor itself is empty and already active. Type into that existing
        // editor directly so no modifier-key event can overlap the final
        // character and accidentally invoke an application menu command.
        let titleEditor = mapWindow.textViews.firstMatch
        XCTAssertTrue(waitForHittable(titleEditor), app.debugDescription)
        titleEditor.click()
        titleEditor.typeText("Root with note")
        let editedTitle = mapWindow.textViews
            .matching(NSPredicate(format: "value == %@", "Root with note"))
            .firstMatch
        XCTAssertTrue(
            editedTitle.waitForExistence(timeout: 3),
            "Typing should update the live node title before notes open.\n\(app.debugDescription)"
        )

        let notesLayerToggle = app.buttons["notesLayerToggle"]
        XCTAssertTrue(notesLayerToggle.waitForExistence(timeout: 3))
        if (notesLayerToggle.value as? String) != "On" {
            notesLayerToggle.click()
        }

        let notePill = mapWindow.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "nodeNotePill-"))
            .firstMatch
        XCTAssertTrue(
            notePill.waitForExistence(timeout: 3),
            "The selected node should reveal its transient + Note action.\n\(app.debugDescription)"
        )
        // Opening the note commits any active title edit, matching the real
        // workflow and avoiding a synthetic global Command-key event.
        notePill.click()

        let focusSurface = app.descendants(matching: .any)["nodeNoteFocusSurface"]
        XCTAssertTrue(
            focusSurface.waitForExistence(timeout: 3),
            "The node should lift into a centered note workspace.\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.descendants(matching: .any)["focusedNoteNodeTitle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["finishNodeNote"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["nodeNoteTextEditor"].exists)

        app.typeText("A focused note")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil { !focusSurface.exists },
            "Escape should commit and close the foreground note editor.\n\(app.debugDescription)"
        )

        let noteIndicator = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "nodeNoteIndicator-"))
            .firstMatch
        XCTAssertTrue(
            noteIndicator.waitForExistence(timeout: 3),
            "Notes-on should show a compact presence marker for the saved note."
        )
        XCTAssertFalse(
            app.staticTexts["A focused note"].exists,
            "The map must not render the note body as an inline preview."
        )

        notesLayerToggle.click()
        XCTAssertTrue(
            waitUntil { !noteIndicator.exists },
            "Turning note indicators off should leave the map text-only."
        )
        notesLayerToggle.click()
        XCTAssertTrue(noteIndicator.waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.buttons
                .matching(
                    NSPredicate(
                        format: "identifier BEGINSWITH %@",
                        "nodeNoteIndicator-"
                    )
                )
                .firstMatch
                .exists,
            "The in-node marker is a passive notification, not an editor button."
        )
        XCTAssertTrue(notePill.waitForExistence(timeout: 3))
        notePill.click()
        XCTAssertTrue(
            focusSurface.waitForExistence(timeout: 3),
            "The selected node’s transient Note pill should reopen the editor."
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !focusSurface.exists })

        // Closing note mode restores the existing canvas workflow: Tab creates
        // a child and begins its title edit instead of being captured by notes.
        app.typeKey(.tab, modifierFlags: [])
        app.typeText("Child after note")
        let childEditor = mapWindow.textViews
            .matching(NSPredicate(format: "value == %@", "Child after note"))
            .firstMatch
        XCTAssertTrue(
            childEditor.waitForExistence(timeout: 3),
            "Tab should create a child and return keyboard focus to title editing.\n\(app.debugDescription)"
        )
    }

    @MainActor
    private func launchApp() {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.activate()
        let newMap = app.buttons["welcomeNewMap"]
        XCTAssertTrue(newMap.waitForExistence(timeout: 5), app.debugDescription)
        newMap.click()
        XCTAssertTrue(waitUntil { self.app.buttons["welcomeNewMap"].exists == false })
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.05,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return condition()
    }

    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        waitUntil(timeout: timeout) {
            element.exists && element.isHittable
        }
    }

    private func isSelected(_ element: XCUIElement) -> Bool {
        element.isSelected
            || (element.value as? NSNumber)?.boolValue == true
    }
}
