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
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
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
    func testSelectedTabIsNotStolenByBackgroundAutosave() throws {
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

        let restoredTabBar = app.tabGroups.firstMatch
        XCTAssertTrue(waitUntil { restoredTabBar.exists && restoredTabBar.tabs.count == 3 })
        XCTAssertTrue(isSelected(restoredTabBar.tabs.element(boundBy: 0)))
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
    private func launchApp() {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
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

    private func isSelected(_ tab: XCUIElement) -> Bool {
        (tab.value as? NSNumber)?.boolValue == true
    }
}
