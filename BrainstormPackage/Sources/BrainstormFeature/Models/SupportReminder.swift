import Foundation
import Observation

public struct SupportReminderSchedule: Equatable, Sendable {
    public static let recurrenceDays = 14

    public var nextEligibleDate: Date?
    public var isPermanentlySuppressed: Bool

    public init(
        nextEligibleDate: Date? = nil,
        isPermanentlySuppressed: Bool = false
    ) {
        self.nextEligibleDate = nextEligibleDate
        self.isPermanentlySuppressed = isPermanentlySuppressed
    }

    public func isEligible(at date: Date) -> Bool {
        guard !isPermanentlySuppressed else { return false }
        guard let nextEligibleDate else { return true }
        return date >= nextEligibleDate
    }

    public mutating func postpone(
        from date: Date,
        calendar: Calendar = .current
    ) {
        guard !isPermanentlySuppressed else { return }
        nextEligibleDate = calendar.date(
            byAdding: .day,
            value: Self.recurrenceDays,
            to: date
        )
    }

    public mutating func suppressPermanently() {
        isPermanentlySuppressed = true
        nextEligibleDate = nil
    }
}

public enum SupportBrainstormDestination: CaseIterable, Sendable {
    case xProfile
    case githubSponsors
    case patreon
    case buyMeACoffee

    public var url: URL {
        switch self {
        case .xProfile:
            URL(string: "https://x.com/selfhosted_ai")!
        case .githubSponsors:
            URL(string: "https://github.com/sponsors/eugenepyvovarov")!
        case .patreon:
            URL(string: "https://patreon.com/selfhosted_ninja")!
        case .buyMeACoffee:
            URL(string: "https://buymeacoffee.com/selfhostedninja")!
        }
    }
}

@MainActor
final class SupportReminderPreferences {
    private static let nextEligibleDateKey =
        "Brainstorm.supportReminder.nextEligibleDate"
    private static let permanentSuppressionKey =
        "Brainstorm.supportReminder.permanentlySuppressed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SupportReminderSchedule {
        SupportReminderSchedule(
            nextEligibleDate: defaults.object(
                forKey: Self.nextEligibleDateKey
            ) as? Date,
            isPermanentlySuppressed: defaults.bool(
                forKey: Self.permanentSuppressionKey
            )
        )
    }

    func save(_ schedule: SupportReminderSchedule) {
        if let nextEligibleDate = schedule.nextEligibleDate {
            defaults.set(
                nextEligibleDate,
                forKey: Self.nextEligibleDateKey
            )
        } else {
            defaults.removeObject(forKey: Self.nextEligibleDateKey)
        }
        defaults.set(
            schedule.isPermanentlySuppressed,
            forKey: Self.permanentSuppressionKey
        )
    }
}

@Observable
@MainActor
public final class SupportReminderCoordinator {
    public static let shared = SupportReminderCoordinator()

    public private(set) var presentingDocumentID: UUID?

    private var schedule: SupportReminderSchedule
    private let preferences: SupportReminderPreferences
    private let currentDate: () -> Date
    private let calendar: Calendar

    public convenience init(
        defaults: UserDefaults = .standard,
        currentDate: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.init(
            preferences: SupportReminderPreferences(defaults: defaults),
            currentDate: currentDate,
            calendar: calendar
        )
    }

    init(
        preferences: SupportReminderPreferences,
        currentDate: @escaping () -> Date,
        calendar: Calendar
    ) {
        self.preferences = preferences
        self.currentDate = currentDate
        self.calendar = calendar
        self.schedule = preferences.load()
    }

    @discardableResult
    public func claimPresentation(for documentID: UUID) -> Bool {
        guard presentingDocumentID == nil else { return false }
        guard schedule.isEligible(at: currentDate()) else { return false }
        presentingDocumentID = documentID
        return true
    }

    public func dismissPresentation(
        for documentID: UUID,
        permanentlySuppress: Bool
    ) {
        guard presentingDocumentID == documentID else { return }
        if permanentlySuppress {
            schedule.suppressPermanently()
        } else {
            schedule.postpone(from: currentDate(), calendar: calendar)
        }
        preferences.save(schedule)
        presentingDocumentID = nil
    }

    public func open(
        _ destination: SupportBrainstormDestination,
        using opener: (URL) -> Void
    ) {
        opener(destination.url)
    }

    var persistedSchedule: SupportReminderSchedule {
        schedule
    }

    public var nextEligibilityDate: Date? {
        schedule.nextEligibleDate
    }

    public var isPermanentlySuppressed: Bool {
        schedule.isPermanentlySuppressed
    }
}
