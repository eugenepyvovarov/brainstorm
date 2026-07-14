import Foundation

enum ExternalFileChangeAction: Equatable {
    case unchanged
    case reload
    case askBeforeReloading
}

enum ExternalFileChangePolicy {
    static func action(
        previousData: Data?,
        currentData: Data?,
        hasUnsavedChanges: Bool
    ) -> ExternalFileChangeAction {
        guard let previousData, let currentData, previousData != currentData else {
            return .unchanged
        }
        return hasUnsavedChanges ? .askBeforeReloading : .reload
    }
}
