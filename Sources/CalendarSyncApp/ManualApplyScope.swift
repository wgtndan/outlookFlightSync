import CalendarSyncCore
import Foundation

/// Resolves a manual action against the complete, freshly rebuilt preview.
/// A single-event test must never broaden into a rule-wide write or approval.
struct ManualApplyScope {
    let changes: [PlannedChange]
    let approvesConfiguration: Bool
    var sourceKeysToAcknowledge: Set<String> { Set(changes.map(\.sourceKey)) }

    static func validate(previewed: [PlannedChange], fresh: [PlannedChange], changeID: String?) throws -> Self {
        guard fresh == previewed else { throw ValidationError.stalePreview }
        guard !fresh.contains(where: { $0.kind == .conflict }) else { throw ValidationError.conflicts }
        guard let changeID else { return Self(changes: fresh, approvesConfiguration: true) }
        let selected = fresh.filter { $0.id == changeID }
        guard selected.count == 1, let change = selected.first else { throw ValidationError.invalidSelection }
        guard change.kind == .create || change.kind == .update || change.kind == .remove else {
            throw ValidationError.notApplicable
        }
        return Self(changes: [change], approvesConfiguration: false)
    }

    enum ValidationError: LocalizedError, Equatable {
        case stalePreview, conflicts, invalidSelection, notApplicable

        var errorDescription: String? {
            switch self {
            case .stalePreview:
                "The calendars changed after this preview. Review the refreshed changes, then apply again."
            case .conflicts:
                "Resolve the conflicts in this preview before syncing this rule. No changes were applied."
            case .invalidSelection:
                "The selected change could not be identified uniquely. Create a new preview and try again."
            case .notApplicable:
                "This event has no change to apply. Choose a Create, Update, or Remove row."
            }
        }
    }
}
