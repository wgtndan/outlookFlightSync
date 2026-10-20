import Foundation

/// Produces a deterministic, side-effect-free reconciliation plan.
/// Callers must supply a complete source read before presenting removals.
public enum SyncPlanner {
    public static func plan(
        rule: SyncRule,
        sourceEvents: [EventSnapshot],
        destinationEvents: [EventSnapshot],
        mappings: [SyncMapping],
        window: DateInterval,
        unresolvedSourceKeys: Set<String> = []
    ) -> [PlannedChange] {
        let ruleMappings = mappings.filter { $0.ruleID == rule.id }
        var errors = RuleEngine.validationErrors(for: rule)
        if ruleMappings.contains(where: { $0.sourceCalendarID != rule.sourceCalendarID || $0.destinationCalendarID != rule.destinationCalendarID }) {
            errors.append("This rule has copies associated with different calendars. Review the existing copies before changing calendars.")
        }
        let selectedSources = sourceEvents.filter { $0.calendarID == rule.sourceCalendarID }
        let sourcesByID = Dictionary(grouping: selectedSources, by: \.id)
        let sourcesByHint = Dictionary(grouping: selectedSources.filter { !($0.identityHint?.isEmpty ?? true) }) { $0.identityHint! }
        if ruleMappings.contains(where: { mapping in
            // A provider can change a derived key and its identity hint when a
            // standalone event moves. Its exact saved event reference still
            // prevents treating that move as a new event plus a deletion.
            if sourcesByID[mapping.sourceEventID]?.contains(where: { $0.sourceKey != mapping.sourceKey }) == true {
                return true
            }
            guard let hint = mapping.sourceIdentityHint, !hint.isEmpty else { return false }
            return sourcesByHint[hint]?.contains(where: { $0.sourceKey != mapping.sourceKey }) == true
        }) {
            errors.append("A tracked source event now has a different source key. Review its identity before creating or removing copies.")
        }
        if !errors.isEmpty {
            return [PlannedChange(ruleID: rule.id, sourceKey: "configuration", sourceEventID: "",
                                  kind: .conflict, payload: nil, reason: errors.joined(separator: " "), requiresReview: true)]
        }

        // Arrays deliberately remain grouped: duplicate identifiers are conflicts, not crashes.
        let sources = Dictionary(grouping: selectedSources, by: \.sourceKey)
        let mappingGroups = Dictionary(grouping: ruleMappings, by: \.sourceKey)
        let destinationIDs = Dictionary(grouping: destinationEvents, by: \.id)
        let mappedDestinationIDs = Dictionary(grouping: ruleMappings, by: \.destinationEventID)
        let ownedCopies = Dictionary(grouping: destinationEvents.filter { $0.ownership?.ruleID == rule.id }) {
            $0.ownership!.sourceKey
        }
        let keys = Set(sources.keys).union(mappingGroups.keys).union(ownedCopies.keys).sorted()
        var changes: [PlannedChange] = []

        for key in keys {
            let sourceGroup = sources[key] ?? []
            let mappingGroup = mappingGroups[key] ?? []
            let ownedGroup = ownedCopies[key] ?? []
            let source = sourceGroup.first
            let mapping = mappingGroup.first
            let marker = OwnershipMarker(ruleID: rule.id, sourceKey: key)

            func conflict(_ reason: String, destination: EventSnapshot? = nil) -> PlannedChange {
                PlannedChange(ruleID: rule.id, sourceKey: key,
                              sourceEventID: source?.id ?? mapping?.sourceEventID ?? "",
                              destinationEventID: destination?.id ?? mapping?.destinationEventID,
                              kind: .conflict, payload: mapping?.lastPayload,
                              reason: reason, requiresReview: true)
            }

            if key.isEmpty || source?.id.isEmpty == true {
                changes.append(conflict("The source identity is missing; no changes can be made safely."))
                continue
            }
            if sourceGroup.count > 1 || mappingGroup.count > 1 || ownedGroup.count > 1 {
                changes.append(conflict("Multiple records share this source identity or ownership marker."))
                continue
            }
            if unresolvedSourceKeys.contains(key), mapping != nil || !ownedGroup.isEmpty {
                changes.append(conflict("The tracked recurring occurrence could not be resolved and may have moved. Confirm its identity before making changes.", destination: ownedGroup.first))
                continue
            }
            if let mapping, mapping.destinationEventID.isEmpty || (mappedDestinationIDs[mapping.destinationEventID]?.count ?? 0) > 1 {
                changes.append(conflict("The saved destination identity is missing or shared by multiple mappings."))
                continue
            }

            let mappedDestinations = mapping.flatMap { destinationIDs[$0.destinationEventID] } ?? []
            if mappedDestinations.count > 1 {
                changes.append(conflict("Multiple destination records share the saved destination identity."))
                continue
            }
            if let mappedDestination = mappedDestinations.first,
               mappedDestination.ownership != marker || mappedDestination.calendarID != rule.destinationCalendarID {
                changes.append(conflict("The saved destination event is no longer an owned copy in the selected calendar.", destination: mappedDestination))
                continue
            }
            let destination = ownedGroup.first ?? mappedDestinations.first
            if let destination,
               destination.id.isEmpty || destination.calendarID != rule.destinationCalendarID || (destinationIDs[destination.id]?.count ?? 0) > 1 {
                changes.append(conflict("The owned copy has an ambiguous identity or is in a different calendar.", destination: destination))
                continue
            }
            if let destination, !destination.canManageAsCopy {
                changes.append(conflict("The owned copy now has recurrence or attendees and cannot be managed safely. Review it before syncing.", destination: destination))
                continue
            }

            if let source {
                if source.end < source.start {
                    changes.append(conflict("The source event ends before it starts."))
                    continue
                }
                // Preserve out-of-window history even if its title, eligibility, or cancellation changes.
                guard overlaps(start: source.start, end: source.end, window: window) else { continue }
                let match = RuleEngine.evaluate(event: source, rule: rule)
                if !match.matches {
                    if let destination {
                        changes.append(removal(rule: rule, key: key, sourceID: source.id, destination: destination,
                                               lastPayload: mapping?.lastPayload, reason: match.reason))
                    }
                    continue
                }
                let payload = RuleEngine.payload(event: source, rule: rule)
                if let destination {
                    let unchanged = destinationPayload(destination) == payload && !destination.isCancelled
                    changes.append(PlannedChange(ruleID: rule.id, sourceKey: key, sourceEventID: source.id,
                                                 destinationEventID: destination.id,
                                                 kind: unchanged ? .unchanged : .update, payload: payload,
                                                 reason: unchanged ? "The owned copy is already up to date." : "Update the owned copy to match the source and privacy settings."))
                } else {
                    changes.append(PlannedChange(ruleID: rule.id, sourceKey: key, sourceEventID: source.id,
                                                 kind: .create, payload: payload,
                                                 reason: mapping == nil ? "Create a matching event copy." : "Recreate the missing owned copy."))
                }
            } else if let destination {
                let lastPayload = mapping?.lastPayload ?? destinationPayload(destination)
                // Absence outside this complete read window says nothing about deletion.
                guard overlaps(start: lastPayload.start, end: lastPayload.end, window: window) else { continue }
                changes.append(removal(rule: rule, key: key, sourceID: mapping?.sourceEventID ?? "",
                                       destination: destination, lastPayload: lastPayload,
                                       reason: "The source was absent from the completed read. Remove this owned copy."))
            }
        }
        return changes
    }

    private static func removal(rule: SyncRule, key: String, sourceID: String, destination: EventSnapshot,
                                lastPayload: CopyPayload?, reason: String) -> PlannedChange {
        PlannedChange(ruleID: rule.id, sourceKey: key, sourceEventID: sourceID, destinationEventID: destination.id,
                      kind: .remove, payload: lastPayload ?? destinationPayload(destination),
                      reason: reason, requiresReview: false)
    }

    private static func destinationPayload(_ event: EventSnapshot) -> CopyPayload {
        CopyPayload(title: event.title, start: event.start, end: event.end,
                    isAllDay: event.isAllDay, timeZoneIdentifier: event.timeZoneIdentifier,
                    location: event.location, busy: event.busy, notes: event.notes)
    }

    private static func overlaps(start: Date, end: Date, window: DateInterval) -> Bool {
        if start == end { return start >= window.start && start < window.end }
        return start < window.end && end > window.start
    }
}
