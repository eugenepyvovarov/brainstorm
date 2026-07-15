import Foundation
import Observation

/// App-wide workspace preferences that are independent of a map's contents.
///
/// These values are shared by every open document and survive app launches.
/// They intentionally live outside `BrainstormFile` so changing the editor
/// chrome never modifies or dirties a `.bs` document.
@Observable
@MainActor
public final class BrainstormUIPreferences {
    public static let shared = BrainstormUIPreferences()

    private let defaults: UserDefaults
    private static let showInspectorKey = "Brainstorm.ui.showInspector"
    private static let focusModeKey = "Brainstorm.ui.focusMode"

    /// Whether the style inspector is shown beside the canvas.
    public var showInspector: Bool {
        didSet {
            guard oldValue != showInspector else { return }
            defaults.set(showInspector, forKey: Self.showInspectorKey)
        }
    }

    /// Whether focus mode dims nodes outside the selected branch.
    public var isFocusMode: Bool {
        didSet {
            guard oldValue != isFocusMode else { return }
            defaults.set(isFocusMode, forKey: Self.focusModeKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showInspector = defaults.object(forKey: Self.showInspectorKey) as? Bool ?? true
        self.isFocusMode = defaults.object(forKey: Self.focusModeKey) as? Bool ?? false
    }

    /// Convenience for isolated tests (in-memory suite).
    public convenience init(suiteName: String) {
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)
        self.init(defaults: suite)
    }
}
