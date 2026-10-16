import AppKit
import CalendarSyncCore
import Combine
import CryptoKit
import EventKit
import Foundation
import ServiceManagement

struct RulePreview {
    var rule: SyncRule
    var window: DateInterval
    var changes: [PlannedChange]
    var tested: [TestedEvent]
    var createdAt = Date()
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var rules: [SyncRule] = []
    @Published var selectedRuleID: UUID?
    @Published private(set) var calendars: [CalendarDescriptor] = []
    @Published private(set) var preview: RulePreview?
    @Published private(set) var runs: [RunRecord] = []
    @Published private(set) var hasAccess = false
    @Published private(set) var isBusy = false
    @Published private(set) var isDemo = false
    @Published private(set) var status = "Choose a rule to get started."
    @Published var errorMessage: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var pendingRecovery = false

    private let access = CalendarAccess()
    private var store: StateStore?
    private var state = SavedState()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isStarted = false

    var selectedRule: SyncRule? { rules.first { $0.id == selectedRuleID } }
    var automaticCount: Int { rules.filter(\.automatic).count }

    var ruleSummaries: [RuleSummary] {
        rules.map { rule in
            RuleSummary.make(
                rule: rule, calendars: calendars, mappings: isDemo ? [] : state.mappings,
                runs: runs, hasAccess: hasAccess, isDemo: isDemo, storageAvailable: store != nil,
                configurationApproved: state.approvedConfigurations[rule.id.uuidString] == configurationDigest(rule),
                pendingRecovery: pendingRecovery,
                previewChanges: preview?.rule == rule ? preview?.changes : nil
            )
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if ProcessInfo.processInfo.arguments.contains("--diagnose-sync") {
            runDiagnostics()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runAutomatic() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.runAutomatic() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refreshAccess() } })
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            enterDemo()
            return
        }
        loadLocalState()
        refreshAccess()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Task { await runAutomatic() }
    }

    /// Read only and deliberately omits calendar names, event contents, IDs and dates.
    /// This path runs before timers, normal state loading, or automatic syncing.
    private func runDiagnostics() {
        var lines = ["Calendar Sync read-only diagnostics", "Calendar access: \(access.authorizationGranted)"]
        do {
            let diagnosticStore = try StateStore(readOnly: true)
            let saved = try diagnosticStore.load()
            lines.append("Pending operations: \(try diagnosticStore.pendingCount())")
            if access.authorizationGranted {
                for (index, rule) in saved.rules.enumerated() {
                    let keys = try diagnosticStore.pendingSourceKeys(ruleID: rule.id)
                    guard !keys.isEmpty else { continue }
                    lines.append("Rule \(index + 1), preset \(rule.preset.rawValue)")
                    lines += try access.diagnosticReport(rule: rule, window: makeWindow(rule), pendingKeys: keys)
                }
            }
        } catch { lines.append("Diagnostic read failed: \(error.localizedDescription)") }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        NSApplication.shared.terminate(nil)
    }

    private func loadLocalState() {
        do {
            let store = try StateStore()
            state = try store.load()
            // Copy behavior can change between versions even when the rule's
            // editable fields are identical. Require a full preview before
            // that broader policy can run automatically.
            var pausedForReview = false
            for index in state.rules.indices where state.rules[index].automatic {
                let rule = state.rules[index]
                if state.approvedConfigurations[rule.id.uuidString] != configurationDigest(rule) {
                    state.rules[index].automatic = false
                    pausedForReview = true
                }
            }
            if pausedForReview { try store.save(state) }
            self.store = store
            pendingRecovery = try store.pendingCount() > 0
            rules = state.rules
            runs = state.runs
            selectedRuleID = rules.first?.id
            status = pendingRecovery ? "A previous run was interrupted. Review a fresh preview to recover safely."
                : pausedForReview ? "Copy settings changed. Review a full preview before turning automatic syncing back on."
                : "Ready when you are."
        } catch {
            store = nil
            errorMessage = error.localizedDescription
        }
    }

    func requestAccess() async {
        guard !isBusy, !isDemo else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            hasAccess = try await access.requestAccess()
            if hasAccess {
                calendars = access.calendars()
                status = "Calendars connected. Select a source and destination, then test your rule."
            } else {
                errorMessage = "Full Calendar access is needed to select calendars and update existing copies. You can allow it in System Settings → Privacy & Security → Calendars."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshAccess() {
        guard !isDemo else { return }
        hasAccess = access.authorizationGranted
        if hasAccess { calendars = access.calendars() }
        else { calendars = []; preview = nil }
    }

    func addRule(_ preset: RulePreset) {
        guard !isBusy else { return }
        var rule = SyncRule.makePreset(preset)
        if preset == .custom { rule.name = "New rule" }
        rules.append(rule)
        selectedRuleID = rule.id
        preview = nil
        persistRules()
    }

    func updateRule(_ rule: SyncRule) {
        guard !isBusy, let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var updated = rule
        if configurationDigest(rule) != state.approvedConfigurations[rule.id.uuidString] {
            updated.automatic = false
        }
        rules[index] = updated
        preview = nil
        persistRules()
    }

    func deleteRule(_ ruleID: UUID) {
        guard !isBusy else { return }
        rules.removeAll { $0.id == ruleID }
        // Keep mappings so deleting/recreating a rule never authorizes edits to its old copies.
        state.approvedConfigurations.removeValue(forKey: ruleID.uuidString)
        selectedRuleID = rules.first?.id
        preview = nil
        status = "Rule removed. Its existing calendar copies have been left in place."
        persistRules()
        if !isDemo, let store {
            do {
                // Deleting a rule explicitly abandons its pending operations;
                // its calendar objects remain untouched and its ID is retired.
                try store.acknowledgeRecoveredOperations(ruleID: ruleID, sourceKeys: store.pendingSourceKeys(ruleID: ruleID))
                pendingRecovery = try store.pendingCount() > 0
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func canEnableAutomatic(_ rule: SyncRule) -> Bool {
        !isDemo && store != nil && state.approvedConfigurations[rule.id.uuidString] == configurationDigest(rule)
    }

    func setAutomatic(_ enabled: Bool, ruleID: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }), !isBusy else { return }
        guard !enabled || canEnableAutomatic(rules[index]) else { return }
        rules[index].automatic = enabled
        persistRules()
    }

    func pauseAll() {
        guard !isBusy else { return }
        for index in rules.indices { rules[index].automatic = false }
        persistRules()
        status = "Automatic syncing paused. Existing copies are unchanged."
    }

    func makePreview() async {
        guard let rule = selectedRule, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let window = try makeWindow(rule)
            preview = try buildPreview(rule, window: window)
            status = "Preview ready. Your calendars have not been changed."
        } catch { preview = nil; errorMessage = error.localizedDescription }
    }

    func applyPreview(changeID: String? = nil) async {
        guard let old = preview, !isBusy else { return }
        guard !isDemo else { status = "This is a sample preview. Connect your calendars to sync real events."; return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let rule = rules.first(where: { $0.id == old.rule.id }), rule == old.rule else {
                throw AppError.message("The rule changed. Create a new preview before applying it.")
            }
            let fresh = try buildPreview(rule, window: old.window)
            let scope: ManualApplyScope
            do {
                scope = try ManualApplyScope.validate(previewed: old.changes, fresh: fresh.changes, changeID: changeID)
            } catch ManualApplyScope.ValidationError.stalePreview {
                preview = fresh
                status = "The calendars changed after this preview. Review the refreshed changes, then apply again."
                return
            }
            try apply(fresh, automatic: false, changes: scope.changes)
            if scope.approvesConfiguration {
                state.approvedConfigurations[rule.id.uuidString] = configurationDigest(rule)
            }
            try persist()
            try store?.acknowledgeRecoveredOperations(ruleID: rule.id, sourceKeys: scope.sourceKeysToAcknowledge)
            pendingRecovery = (try store?.pendingCount() ?? 0) > 0
            preview = try buildPreview(rule, window: old.window)
            if !scope.approvesConfiguration {
                status = "1 change synced. Review the refreshed preview for any remaining changes."
            }
        } catch {
            recordFailure(rule: old.rule, error: error)
        }
    }

    func runAutomatic() async {
        guard !isBusy, !isDemo, !pendingRecovery, store != nil else { return }
        refreshAccess()
        guard hasAccess else { return }
        let enabled = rules.filter { $0.automatic && canEnableAutomatic($0) }
        guard !enabled.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        for rule in enabled {
            do {
                let fresh = try buildPreview(rule, window: makeWindow(rule))
                try apply(fresh, automatic: true)
            } catch {
                recordFailure(rule: rule, error: error)
                if pendingRecovery { break }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isDemo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { status = "Enable Calendar Sync in System Settings → General → Login Items." }
        } catch { errorMessage = "Could not change login settings: \(error.localizedDescription)" }
    }

    func enterDemo() {
        guard !isBusy else { return }
        isDemo = true
        hasAccess = false
        calendars = [
            .init(id: "demo-work", title: "Calendar", sourceTitle: "Work account", writable: true),
            .init(id: "demo-travel", title: "Travel", sourceTitle: "iCloud", writable: true),
            .init(id: "demo-family", title: "Family", sourceTitle: "iCloud", writable: true)
        ]
        var flight = SyncRule.makePreset(.flights)
        flight.sourceCalendarID = "demo-work"; flight.destinationCalendarID = "demo-travel"
        var family = SyncRule.makePreset(.family)
        family.sourceCalendarID = "demo-family"; family.destinationCalendarID = "demo-work"
        rules = [flight, family]
        selectedRuleID = flight.id
        runs = []
        errorMessage = nil
        status = "Sample data. No real calendars are read or changed."
        Task { await makePreview() }
    }

    func exitDemo() {
        guard !isBusy else { return }
        isDemo = false
        preview = nil
        loadLocalState()
        refreshAccess()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func makeWindow(_ rule: SyncRule) throws -> DateInterval {
        guard (0...365).contains(rule.pastDays), (1...730).contains(rule.futureDays) else {
            throw AppError.message("Choose 0–365 days of history and 1–730 days ahead.")
        }
        let today = Calendar.current.startOfDay(for: Date())
        guard let start = Calendar.current.date(byAdding: .day, value: -rule.pastDays, to: today),
              let end = Calendar.current.date(byAdding: .day, value: rule.futureDays + 1, to: today) else {
            throw AppError.message("Could not calculate the date range.")
        }
        return DateInterval(start: start, end: end)
    }

    private func buildPreview(_ rule: SyncRule, window: DateInterval) throws -> RulePreview {
        let validation = RuleEngine.validationErrors(for: rule)
        guard validation.isEmpty else { throw AppError.message(validation.joined(separator: "\n")) }
        guard rule.sourceCalendarID != rule.destinationCalendarID,
              calendars.contains(where: { $0.id == rule.sourceCalendarID }),
              calendars.contains(where: { $0.id == rule.destinationCalendarID && $0.writable }) else {
            throw AppError.message("Select an available source and a different, writable destination calendar.")
        }
        let mappings = isDemo ? [] : state.mappings.filter { $0.ruleID == rule.id }
        var source: [EventSnapshot]
        var destination: [EventSnapshot]
        var unresolvedSourceKeys = Set<String>()
        if isDemo { source = demoEvents(calendarID: rule.sourceCalendarID); destination = [] }
        else {
            guard hasAccess else { throw AppError.message("Calendar permission is required. Connect your calendars first.") }
            source = try access.events(calendarID: rule.sourceCalendarID, window: window)
            destination = try access.events(calendarID: rule.destinationCalendarID, window: window)
            // Resolve tracked objects outside the window so a rescheduled event or
            // an edited destination is not mistaken for a deletion or a new copy.
            for mapping in mappings {
                if let event = access.event(id: mapping.sourceEventID), !source.contains(where: { $0.id == event.id }) { source.append(event) }
                if let event = access.trackedDestination(id: mapping.destinationEventID), !destination.contains(where: { $0.id == event.id }) { destination.append(event) }
            }
            for mapping in mappings where CalendarAccess.isRecurringReference(mapping.sourceEventID) {
                if !source.contains(where: { $0.sourceKey == mapping.sourceKey }) { unresolvedSourceKeys.insert(mapping.sourceKey) }
            }
        }
        if !isDemo { source = RuleEngine.excludeManagedCopies(source, mappings: state.mappings) }
        var changes = SyncPlanner.plan(rule: rule, sourceEvents: source, destinationEvents: destination, mappings: mappings, window: window, unresolvedSourceKeys: unresolvedSourceKeys)
        if !isDemo, let store {
            let unresolvedOperations = try store.pendingSourceKeys(ruleID: rule.id).subtracting(Set(changes.map(\.sourceKey)))
            for key in unresolvedOperations.sorted() {
                let mapping = mappings.first { $0.sourceKey == key }
                changes.append(PlannedChange(ruleID: rule.id, sourceKey: key, sourceEventID: mapping?.sourceEventID ?? "",
                    kind: .conflict, payload: mapping?.lastPayload,
                    reason: "An interrupted operation could not be verified in this range. Expand the coverage and test again. If the event cannot be recovered, removing this rule abandons the operation and leaves existing copies untouched.", requiresReview: true))
            }
        }
        let tested = source.filter { $0.start < window.end && $0.end > window.start }
            .sorted { $0.start < $1.start }.map { TestedEvent(event: $0, result: RuleEngine.evaluate(event: $0, rule: rule)) }
        return RulePreview(rule: rule, window: window, changes: changes, tested: tested)
    }

    private func apply(_ preview: RulePreview, automatic: Bool, changes: [PlannedChange]? = nil) throws {
        guard let store else { throw AppError.message("Local history is unavailable. Syncing is paused to prevent duplicates.") }
        guard !preview.changes.contains(where: { $0.kind == .conflict }) else {
            throw AppError.message("Resolve the conflicts in this preview before syncing this rule. No changes were applied.")
        }
        var written = 0
        let reviewCount = preview.changes.filter { $0.requiresReview && $0.kind == .remove }.count
        for change in changes ?? preview.changes {
            if automatic && change.requiresReview { continue }
            if change.kind == .unchanged {
                if let destinationID = change.destinationEventID, let payload = change.payload {
                    putMapping(SyncMapping(ruleID: preview.rule.id, sourceKey: change.sourceKey,
                        sourceEventID: change.sourceEventID, destinationEventID: destinationID,
                        sourceCalendarID: preview.rule.sourceCalendarID, destinationCalendarID: preview.rule.destinationCalendarID,
                        lastPayload: payload, sourceIdentityHint: access.event(id: change.sourceEventID)?.identityHint))
                }
                continue
            }
            guard change.kind == .create || change.kind == .update || change.kind == .remove else { continue }
            let operationID = try store.begin(change)
            if let mapping = try access.apply(change: change, rule: preview.rule, window: preview.window) {
                putMapping(mapping)
            } else if change.kind == .remove {
                state.mappings.removeAll { $0.ruleID == change.ruleID && $0.sourceKey == change.sourceKey }
            }
            // Persist after each operation; later failures must not lose successful writes.
            try persist()
            try store.finish(operationID)
            written += 1
        }
        let synced = "\(written) \(written == 1 ? "change" : "changes") synced."
        let message = automatic && reviewCount > 0
            ? "\(synced) \(reviewCount) removals need review."
            : synced
        state.runs.insert(RunRecord(ruleName: preview.rule.name, summary: message, succeeded: true, ruleID: preview.rule.id), at: 0)
        state.runs = Array(state.runs.prefix(100))
        try persist()
        status = message
    }

    private func putMapping(_ mapping: SyncMapping) {
        state.mappings.removeAll { $0.ruleID == mapping.ruleID && $0.sourceKey == mapping.sourceKey }
        state.mappings.append(mapping)
    }

    private func recordFailure(rule: SyncRule, error: Error) {
        errorMessage = error.localizedDescription
        status = "Sync needs attention. Successful changes were saved; use a fresh preview to continue."
        state.runs.insert(RunRecord(ruleName: rule.name, summary: error.localizedDescription, succeeded: false, ruleID: rule.id), at: 0)
        state.runs = Array(state.runs.prefix(100))
        let pendingCount = (try? store?.pendingCount()) ?? 1
        pendingRecovery = pendingCount > 0
        // Pause the failing rule instead of repeatedly reporting the same problem.
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index].automatic = false }
        state.rules = rules
        do { try persist() } catch { errorMessage = error.localizedDescription }
    }

    private func configurationDigest(_ rule: SyncRule) -> String {
        var copy = rule
        copy.automatic = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(copy) else { return "invalid" }
        // Version 2 includes notes for flights/custom rules. Old approvals
        // must not silently authorize copying this additional content.
        if copy.preset != .family {
            data.insert(contentsOf: Data("copy-policy-v2\n".utf8), at: 0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func persistRules() {
        guard !isDemo else { return }
        state.rules = rules
        do { try persist() } catch { errorMessage = error.localizedDescription }
    }

    private func persist() throws {
        guard !isDemo else { return }
        guard let store else { throw AppError.message("Cannot save settings. Restart after resolving the local storage error.") }
        try store.save(state)
        runs = state.runs
    }

    private func demoEvents(calendarID: String) -> [EventSnapshot] {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(2 * 86_400 + 10 * 3_600)
        if calendarID == "demo-family" {
            return [.init(id: "sample-family", sourceKey: "sample-family", calendarID: calendarID,
                          title: "School concert", start: start, end: start.addingTimeInterval(3_600),
                          timeZoneIdentifier: "Australia/Melbourne", location: "School hall", notes: "Sample family details")]
        }
        guard calendarID == "demo-work" else { return [] }
        return [
            .init(id: "sample-flight-1", sourceKey: "sample-flight-1", calendarID: calendarID,
                  title: "Flight for Alex Example from Melbourne, AU (MEL) to Sydney, AU (SYD), Qantas: QF420, Airline Confirmation Code: SAMPLE",
                  start: start, end: start.addingTimeInterval(5_400), timeZoneIdentifier: "Australia/Melbourne", location: "Melbourne Airport (MEL)",
                  notes: "Sample itinerary\nTerminal 1 · Check in before departure\nBooking reference: SAMPLE"),
            .init(id: "sample-flight-2", sourceKey: "sample-flight-2", calendarID: calendarID,
                  title: "Flight for Alex Example from Mumbai, IN (BOM) to Singapore, SG (SIN), Singapore Airlines: SQ423, Airline Confirmation Code: DEMO12",
                  start: start.addingTimeInterval(3 * 86_400), end: start.addingTimeInterval(3 * 86_400 + 19_800), timeZoneIdentifier: "Asia/Kolkata", location: "Mumbai Airport (BOM)"),
            .init(id: "sample-meeting", sourceKey: "sample-meeting", calendarID: calendarID,
                  title: "Weekly project check-in", start: start.addingTimeInterval(86_400), end: start.addingTimeInterval(86_400 + 1_800), timeZoneIdentifier: "Australia/Melbourne")
        ]
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}
