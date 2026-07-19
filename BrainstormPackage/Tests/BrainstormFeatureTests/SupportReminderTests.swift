import Foundation
import Testing
@testable import BrainstormFeature

@Suite("Support reminder", .serialized)
@MainActor
struct SupportReminderTests {
    @Test func firstRunIsImmediatelyEligible() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = SupportReminderCoordinator(
            defaults: defaults,
            currentDate: { now },
            calendar: utcCalendar
        )

        #expect(coordinator.claimPresentation(for: UUID()))
    }

    @Test func dismissalRecursAtTheFourteenDayBoundaryAcrossRestart() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstDocumentID = UUID()
        let firstCoordinator = SupportReminderCoordinator(
            defaults: defaults,
            currentDate: { now },
            calendar: utcCalendar
        )

        #expect(firstCoordinator.claimPresentation(for: firstDocumentID))
        firstCoordinator.dismissPresentation(
            for: firstDocumentID,
            permanentlySuppress: false
        )

        now = utcCalendar.date(byAdding: .day, value: 13, to: now)!
        let beforeBoundary = SupportReminderCoordinator(
            defaults: defaults,
            currentDate: { now },
            calendar: utcCalendar
        )
        #expect(!beforeBoundary.claimPresentation(for: UUID()))

        now = utcCalendar.date(byAdding: .day, value: 1, to: now)!
        let atBoundary = SupportReminderCoordinator(
            defaults: defaults,
            currentDate: { now },
            calendar: utcCalendar
        )
        #expect(atBoundary.claimPresentation(for: UUID()))
    }

    @Test func permanentOptOutSurvivesRestart() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let documentID = UUID()
        let coordinator = SupportReminderCoordinator(
            defaults: defaults,
            currentDate: { now },
            calendar: utcCalendar
        )

        #expect(coordinator.claimPresentation(for: documentID))
        coordinator.dismissPresentation(
            for: documentID,
            permanentlySuppress: true
        )

        let relaunchedCoordinator = SupportReminderCoordinator(
            defaults: defaults,
            currentDate: { now.addingTimeInterval(60 * 60 * 24 * 365) },
            calendar: utcCalendar
        )
        #expect(!relaunchedCoordinator.claimPresentation(for: UUID()))
        #expect(relaunchedCoordinator.persistedSchedule.isPermanentlySuppressed)
    }

    @Test func openingLinksDoesNotDismissOrChangeTheSchedule() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let documentID = UUID()
        let coordinator = SupportReminderCoordinator(
            defaults: defaults,
            currentDate: { Date(timeIntervalSince1970: 1_800_000_000) },
            calendar: utcCalendar
        )
        var openedURLs: [URL] = []

        #expect(coordinator.claimPresentation(for: documentID))
        let scheduleBeforeOpening = coordinator.persistedSchedule
        for destination in SupportBrainstormDestination.allCases {
            coordinator.open(destination) { openedURLs.append($0) }
        }

        #expect(openedURLs == SupportBrainstormDestination.allCases.map(\.url))
        #expect(coordinator.presentingDocumentID == documentID)
        #expect(coordinator.persistedSchedule == scheduleBeforeOpening)
    }

    @Test func onlyOneDocumentCanClaimTheSheetAtATime() {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstDocumentID = UUID()
        let secondDocumentID = UUID()
        let coordinator = SupportReminderCoordinator(
            defaults: defaults,
            currentDate: { Date(timeIntervalSince1970: 1_800_000_000) },
            calendar: utcCalendar
        )

        #expect(coordinator.claimPresentation(for: firstDocumentID))
        #expect(!coordinator.claimPresentation(for: secondDocumentID))
        #expect(coordinator.presentingDocumentID == firstDocumentID)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "SupportReminderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
