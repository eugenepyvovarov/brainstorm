import Foundation
import Observation

/// Workspace chrome preferences independent of `.bs` document bytes.
///
/// - App-wide: focus mode, style sidebar visibility, and which inspector blocks
///   are expanded. These survive launches and apply to every window.
/// - Per map: whether task checkboxes are shown. Task *done* flags still live
///   in the `.bs` file; this only remembers chrome visibility per path / untitled id.
@Observable
@MainActor
public final class BrainstormUIPreferences {
    public static let shared = BrainstormUIPreferences()

    private let defaults: UserDefaults
    private static let showInspectorKey = "Brainstorm.ui.showInspector"
    private static let focusModeKey = "Brainstorm.ui.focusMode"
    private static let colorsExpandedKey = "Brainstorm.ui.inspector.colorsExpanded"
    private static let typeExpandedKey = "Brainstorm.ui.inspector.typeExpanded"
    private static let mediaExpandedKey = "Brainstorm.ui.inspector.mediaExpanded"
    private static let resetExpandedKey = "Brainstorm.ui.inspector.resetExpanded"
    private static let taskCompletenessByDocumentKey =
        "Brainstorm.ui.taskCompletenessByDocument"
    /// Legacy single app-wide tasks flag (migrated into per-document map on load).
    private static let legacyShowTaskCompletenessKey =
        "Brainstorm.ui.showTaskCompleteness"

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

    public var colorsExpanded: Bool {
        didSet {
            guard oldValue != colorsExpanded else { return }
            defaults.set(colorsExpanded, forKey: Self.colorsExpandedKey)
        }
    }

    public var typeExpanded: Bool {
        didSet {
            guard oldValue != typeExpanded else { return }
            defaults.set(typeExpanded, forKey: Self.typeExpandedKey)
        }
    }

    public var mediaExpanded: Bool {
        didSet {
            guard oldValue != mediaExpanded else { return }
            defaults.set(mediaExpanded, forKey: Self.mediaExpandedKey)
        }
    }

    public var resetExpanded: Bool {
        didSet {
            guard oldValue != resetExpanded else { return }
            defaults.set(resetExpanded, forKey: Self.resetExpandedKey)
        }
    }

    /// Per-document task-chrome visibility (`file:<path>` or `doc:<uuid>`).
    private var taskCompletenessByDocument: [String: Bool] {
        didSet {
            persistTaskCompletenessMap()
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showInspector = defaults.object(forKey: Self.showInspectorKey) as? Bool ?? true
        self.isFocusMode = defaults.object(forKey: Self.focusModeKey) as? Bool ?? false
        self.colorsExpanded =
            defaults.object(forKey: Self.colorsExpandedKey) as? Bool ?? true
        self.typeExpanded =
            defaults.object(forKey: Self.typeExpandedKey) as? Bool ?? true
        self.mediaExpanded =
            defaults.object(forKey: Self.mediaExpandedKey) as? Bool ?? true
        self.resetExpanded =
            defaults.object(forKey: Self.resetExpandedKey) as? Bool ?? true
        self.taskCompletenessByDocument = Self.loadTaskCompletenessMap(from: defaults)
    }

    /// Convenience for isolated tests (in-memory suite).
    public convenience init(suiteName: String) {
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)
        self.init(defaults: suite)
    }

    // MARK: - Per-document task chrome

    /// Stable key for a map window’s task-chrome preference.
    public static func documentChromeKey(fileURL: URL?, documentID: UUID) -> String {
        if let path = fileURL?.standardizedFileURL.path, !path.isEmpty {
            return "file:\(path)"
        }
        return "doc:\(documentID.uuidString.lowercased())"
    }

    /// Whether task checkboxes are visible for this map (default off).
    public func showTaskCompleteness(fileURL: URL?, documentID: UUID) -> Bool {
        let key = Self.documentChromeKey(fileURL: fileURL, documentID: documentID)
        return taskCompletenessByDocument[key] ?? false
    }

    public func setShowTaskCompleteness(
        _ value: Bool,
        fileURL: URL?,
        documentID: UUID
    ) {
        let key = Self.documentChromeKey(fileURL: fileURL, documentID: documentID)
        if taskCompletenessByDocument[key] == value { return }
        taskCompletenessByDocument[key] = value
    }

    public func toggleShowTaskCompleteness(fileURL: URL?, documentID: UUID) {
        setShowTaskCompleteness(
            !showTaskCompleteness(fileURL: fileURL, documentID: documentID),
            fileURL: fileURL,
            documentID: documentID
        )
    }

    /// After Save As / first save, keep the same tasks-chrome choice under the new path.
    public func rekeyTaskCompleteness(
        from previousFileURL: URL?,
        documentID: UUID,
        to newFileURL: URL
    ) {
        let oldKey = Self.documentChromeKey(
            fileURL: previousFileURL,
            documentID: documentID
        )
        let newKey = Self.documentChromeKey(
            fileURL: newFileURL,
            documentID: documentID
        )
        guard oldKey != newKey else { return }
        if let value = taskCompletenessByDocument[oldKey] {
            taskCompletenessByDocument[newKey] = value
            if oldKey.hasPrefix("doc:") {
                taskCompletenessByDocument.removeValue(forKey: oldKey)
            }
        }
    }

    private func persistTaskCompletenessMap() {
        defaults.set(taskCompletenessByDocument, forKey: Self.taskCompletenessByDocumentKey)
    }

    private static func loadTaskCompletenessMap(
        from defaults: UserDefaults
    ) -> [String: Bool] {
        if let stored = defaults.dictionary(
            forKey: taskCompletenessByDocumentKey
        ) as? [String: Bool] {
            return stored
        }
        // Migrate the old app-wide toggle into a default used for every new key.
        if let legacy = defaults.object(forKey: legacyShowTaskCompletenessKey) as? Bool,
           legacy
        {
            defaults.removeObject(forKey: legacyShowTaskCompletenessKey)
            // No entries yet; new documents still default to false unless set.
            // Keep true only as a soft default via empty map + caller choice —
            // prefer off for new maps; users re-enable per file.
        } else {
            defaults.removeObject(forKey: legacyShowTaskCompletenessKey)
        }
        return [:]
    }
}
