import AppKit
import CalendarSyncCore
import SwiftUI

private let accent = Color(red: 0.12, green: 0.43, blue: 0.40)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingDelete = false
    @State private var showingApply = false
    @State private var selectedChangeID: String?
    @State private var showExcluded = false
    @State private var selectedTab = 0
    @State private var showingSummary = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if model.rules.isEmpty { welcome }
                else if showingSummary {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if model.isDemo { demoBanner }
                            if !model.hasAccess && !model.isDemo { permissionCard }
                            if model.pendingRecovery && !model.isDemo { info("A previous sync was interrupted. Review and apply a fresh preview before automatic syncing resumes.", icon: "arrow.clockwise.circle") }
                            RuleSummaryView(summaries: model.ruleSummaries, isBusy: model.isBusy, reviewRule: openRule)
                            if !visibleRuns.isEmpty { historySection }
                        }.padding(28)
                    }
                }
                else if let rule = model.selectedRule {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if model.isDemo { demoBanner }
                            if !model.hasAccess && !model.isDemo { permissionCard }
                            if model.pendingRecovery && !model.isDemo { info("A previous sync was interrupted. Review and apply a fresh preview before automatic syncing resumes.", icon: "arrow.clockwise.circle") }
                            ruleEditor(rule)
                            if let preview = model.preview, preview.rule.id == rule.id { previewSection(preview) }
                            automationSection(rule)
                            if !visibleRuns.isEmpty { historySection }
                        }
                        .padding(28)
                    }
                } else {
                    ContentUnavailableView("Select a rule", systemImage: "slider.horizontal.3", description: Text("Choose a rule on the left, or create a new one."))
                }
                Divider()
                HStack(spacing: 8) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(accent) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if !model.isDemo { Text("On this Mac").font(.caption).foregroundStyle(.tertiary) }
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .frame(minWidth: 980, minHeight: 700)
        .tint(accent)
        .alert("Calendar Sync", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Remove this rule?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Remove rule", role: .destructive) {
                if let id = model.selectedRuleID { model.deleteRule(id); showingSummary = true }
            }
        } message: { Text("Automatic syncing will stop. Copies already in your calendars will remain.") }
        .confirmationDialog(selectedChangeID == nil ? "Apply all calendar changes?" : "Apply this calendar change?", isPresented: $showingApply, titleVisibility: .visible) {
            Button(selectedChangeID == nil ? "Apply all changes" : "Apply this change", role: confirmationChanges.contains(where: { $0.kind == .remove }) ? .destructive : nil) {
                let changeID = selectedChangeID
                Task { await model.applyPreview(changeID: changeID) }
            }
            .disabled(model.isBusy || model.isDemo || model.preview == nil || (selectedChangeID != nil && confirmationChanges.isEmpty))
        } message: {
            if let preview = model.preview {
                if selectedChangeID != nil, let change = confirmationChanges.first, let payload = change.payload {
                    Text("\(change.kind.rawValue.capitalized): \(payload.title)\n\(eventTime(payload))\nDestination: \(calendarLabel(preview.rule.destinationCalendarID))\nOnly this event will be applied. The other previewed changes will remain pending.")
                } else if selectedChangeID == nil {
                    Text("\(summary(preview.changes))\nDestination: \(calendarLabel(preview.rule.destinationCalendarID))\nOnly copies managed by this rule will be changed.")
                } else {
                    Text("This change is no longer in the preview. Cancel and test the rule again.")
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(accent)
                Text("Calendar Sync").font(.headline)
            }.padding(.top, 12)
            Button { showingSummary = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").frame(width: 20)
                    Text("Summary").fontWeight(.medium)
                    Spacer()
                    Text("\(model.rules.count)").font(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(showingSummary ? accent : Color.primary)
                .padding(12)
                .background(showingSummary ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).accessibilityLabel("Summary")
            Text("YOUR RULES").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(model.rules) { rule in
                        Button {
                            openRule(rule.id)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: rule.preset == .flights ? "airplane" : rule.preset == .family ? "house" : "line.3.horizontal.decrease.circle")
                                    .frame(width: 20).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.name.isEmpty ? "Untitled rule" : rule.name).fontWeight(.medium).lineLimit(2)
                                    Text(rule.automatic ? "Automatic · 5 min" : "Manual").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(!showingSummary && model.selectedRuleID == rule.id ? accent : Color.primary)
                            .padding(12)
                            .background(!showingSummary && model.selectedRuleID == rule.id ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Menu {
                Button("Flights") { addRule(.flights) }
                Button("Family commitments") { addRule(.family) }
                Button("Custom rule") { addRule(.custom) }
            } label: { Label("Add rule", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Runs locally", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary)
                Text("Your calendars.\nYour Mac. No sync server.").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .font(.caption).disabled(model.isDemo)
                Toggle("Show in Dock", isOn: Binding(get: { model.showInDock }, set: { model.setShowInDock($0) }))
                    .font(.caption).disabled(model.isDemo)
                    .help("Turn off to hide Calendar Sync from the Dock and Command-Tab. Its menu-bar icon stays available.")
                if !model.showInDock {
                    Text("Open this window from the Calendar Sync menu-bar icon.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !model.isDemo {
                    Button("Try sample data") { model.enterDemo(); showingSummary = true }.font(.caption).buttonStyle(.link).disabled(model.isBusy)
                }
            }
        }
        .padding(20)
        .frame(width: 210)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.rules.isEmpty ? "Make room for what matters" : showingSummary ? "Summary" : model.selectedRule?.name ?? "Your rules")
                    .font(.system(size: 24, weight: .semibold))
                Text(showingSummary && !model.rules.isEmpty ? "Your rules, calendar connections, and recent activity." : "Choose what crosses between your calendars.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if model.selectedRule != nil && !showingSummary {
                Button { showingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove rule; keep existing copies").disabled(model.isBusy)
            }
        }.padding(28)
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.isDemo { demoBanner }
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 48)).foregroundStyle(accent)
                    Text("A little less calendar juggling.").font(.system(size: 29, weight: .semibold))
                    Text("Copy your work flights to iCloud, or reserve time for family on your work calendar. Each rule has a source of truth, and you review the first sync.")
                        .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 15)
                permissionCard
                HStack(alignment: .top, spacing: 16) {
                    presetCard(.flights, icon: "airplane", description: "Keep travel plans on your personal calendar. Matches flight titles across airlines and routes.")
                    presetCard(.family, icon: "house", description: "Copy occupied time as “Family Commitment”. Original titles, locations and notes stay at the source.")
                }
                info("Both accounts must already be connected in Apple Calendar. This app requests full Calendar access to read sources and manage its destination copies.", icon: "info.circle")
            }.padding(32)
        }
    }

    private func presetCard(_ preset: RulePreset, icon: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(accent)
            Text(preset.title).font(.headline)
            Text(description).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Set up \(preset == .flights ? "flights" : "family time")") { addRule(preset) }
                .buttonStyle(.bordered)
        }.padding(20).frame(maxWidth: .infinity, minHeight: 195, alignment: .topLeading).background(cardBackground)
    }

    private var permissionCard: some View {
        HStack(spacing: 16) {
            Image(systemName: model.hasAccess ? "checkmark.shield" : "calendar.badge.plus").font(.title2).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.hasAccess ? "Calendars connected" : "Connect your calendars").font(.headline)
                Text(model.hasAccess ? "\(model.calendars.count) calendars available from this Mac." : "Use the accounts already set up in Apple Calendar.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasAccess {
                Button("Refresh") { model.refreshAccess() }
            } else {
                Button("Allow Calendar access") { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy || model.isDemo)
            }
        }.padding(20).background(cardBackground)
    }

    private var demoBanner: some View {
        HStack {
            Label("Sample data · your calendars are untouched", systemImage: "sparkles").font(.subheadline)
            Spacer()
            Button("Use my calendars") { model.exitDemo(); showingSummary = true }.buttonStyle(.bordered)
        }.padding(14).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private func ruleEditor(_ rule: SyncRule) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("01", "Calendars")
                    Text("The source is authoritative. Edits to managed copies may be overwritten.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                calendarPicker("From", rule: rule, keyPath: \.sourceCalendarID, writableOnly: false)
                Image(systemName: "arrow.right").foregroundStyle(accent).padding(.top, 18)
                calendarPicker("To", rule: rule, keyPath: \.destinationCalendarID, writableOnly: true)
            }
            HStack {
                Text("Rule name").font(.caption).foregroundStyle(.secondary)
                TextField("Rule name", text: binding(rule, \.name)).textFieldStyle(.roundedBorder)
            }
            Divider()
            HStack {
                sectionLabel("02", "Conditions")
                Spacer()
                if !rule.conditions.isEmpty {
                    Picker("Match", selection: binding(rule, \.matchMode)) {
                        Text("All conditions").tag(MatchMode.all)
                        Text("Any condition").tag(MatchMode.any)
                    }.labelsHidden().frame(width: 150)
                }
            }
            if rule.conditions.isEmpty {
                Text("Every original event in the selected source calendar is included.").font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 9) {
                ForEach(rule.conditions) { condition in
                    HStack(spacing: 10) {
                        Picker("Field", selection: conditionBinding(rule, condition, \.field)) {
                            Text("Title").tag(MatchField.title); Text("Location").tag(MatchField.location); Text("Notes").tag(MatchField.notes)
                        }.labelsHidden().frame(width: 100)
                        Picker("Comparison", selection: conditionBinding(rule, condition, \.operation)) {
                            ForEach(MatchOperator.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 145)
                        TextField("Text to match", text: conditionBinding(rule, condition, \.value)).textFieldStyle(.roundedBorder)
                        Button {
                            var changed = rule; changed.conditions.removeAll { $0.id == condition.id }; model.updateRule(changed)
                        } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Remove condition")
                    }
                }
                HStack {
                    Button { var changed = rule; changed.conditions.append(RuleCondition()); model.updateRule(changed) }
                    label: { Label("Add condition", systemImage: "plus") }.buttonStyle(.link)
                    Spacer()
                    Text("Text matching ignores case").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if rule.preset == .family {
                info("Copies are titled “Family Commitment”, marked Busy, and contain no source location or notes. macOS Calendar access cannot set Outlook’s Private flag; these are ordinary appointments with redacted details.", icon: "eye.slash")
            } else {
                Text("Copies include title, time, location and notes. Attendees and reminders are omitted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                sectionLabel("03", "Coverage")
                Spacer()
                Text("Past").font(.caption)
                TextField("7", value: binding(rule, \.pastDays), format: .number).textFieldStyle(.roundedBorder).frame(width: 46)
                Text("days · next").font(.caption)
                TextField("180", value: binding(rule, \.futureDays), format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
                Text("days").font(.caption)
            }
            Text("Recurring events are copied as individual occurrences. Historical copies are retained when they leave this range.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { Task { await model.makePreview() } } label: { Label("Test & preview", systemImage: "play.circle") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.isBusy || (!model.hasAccess && !model.isDemo))
                Text("No calendar changes until you apply.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(22).background(cardBackground).disabled(model.isBusy)
    }

    private func calendarPicker(_ title: String, rule: SyncRule, keyPath: WritableKeyPath<SyncRule, String>, writableOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Picker(title, selection: binding(rule, keyPath)) {
                Text("Choose calendar…").tag("")
                let value = rule[keyPath: keyPath]
                if !value.isEmpty && !model.calendars.contains(where: { $0.id == value }) { Text("Unavailable calendar — select again").tag(value) }
                ForEach(model.calendars.filter { !writableOnly || $0.writable }) { calendar in Text(calendar.label).tag(calendar.id) }
            }.labelsHidden().frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity)
    }

    private func previewSection(_ preview: RulePreview) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Preview").font(.title3.weight(.semibold))
                Spacer()
                Text(preview.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach([ChangeKind.create, .update, .remove, .unchanged], id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(preview.changes.filter { $0.kind == kind }.count)").font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text(kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Picker("Preview view", selection: $selectedTab) {
                Text("Proposed changes").tag(0)
                Text("Rule test (\(preview.tested.count))").tag(1)
            }.pickerStyle(.segmented)
            if selectedTab == 0 {
                if preview.changes.contains(where: { isWritableChange($0) }) {
                    Text("Apply one change to test a single event, or apply all changes below.").font(.caption).foregroundStyle(.secondary)
                }
                if preview.changes.isEmpty {
                    Text("No matching events or managed copies in this range.").foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(preview.changes) { change in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(change.kind)).foregroundStyle(color(change.kind)).frame(width: 18).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(change.payload?.title ?? "Needs review").font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            if let payload = change.payload { Text(eventTime(payload)).font(.caption).foregroundStyle(.secondary) }
                            if let location = change.payload?.location, !location.isEmpty {
                                Label(location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
                            }
                            if let notes = change.payload?.notes, !notes.isEmpty {
                                DisclosureGroup {
                                    ScrollView {
                                        Text(notes).font(.caption).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 160)
                                } label: {
                                    Label("Notes", systemImage: "note.text").font(.caption)
                                }
                            }
                            Text(change.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(change.kind.rawValue.capitalized).font(.caption.weight(.medium)).foregroundStyle(color(change.kind))
                            if isWritableChange(change) {
                                Button("Apply this change") {
                                    selectedChangeID = change.id
                                    showingApply = true
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                .fixedSize(horizontal: true, vertical: false)
                                .disabled(model.isDemo || model.isBusy || preview.changes.contains(where: { $0.kind == .conflict }))
                                .help("Apply only this event after confirmation")
                            }
                        }
                    }.padding(.vertical, 9)
                    Divider()
                }
            } else {
                Toggle("Show excluded events", isOn: $showExcluded).font(.caption)
                ForEach(preview.tested.filter { showExcluded || $0.result.matches }) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.result.matches ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(item.result.matches ? accent : .secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.event.title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            Text(item.result.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 7)
                }
            }
            if preview.changes.contains(where: { $0.kind == .remove }) {
                info("Removals always need your review. A missing source can also mean Apple Calendar has not finished syncing; confirm it is up to date before applying removals.", icon: "exclamationmark.circle")
            }
            if preview.changes.contains(where: { $0.kind == .conflict }) {
                info("There are conflicting or unidentifiable copies. This rule is paused until they are resolved.", icon: "exclamationmark.triangle")
            }
            HStack {
                Button(preview.changes.allSatisfy { $0.kind == .unchanged } ? "Confirm this preview" : "Apply all changes") {
                    selectedChangeID = nil
                    showingApply = true
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isDemo || model.isBusy || preview.changes.contains(where: { $0.kind == .conflict }))
                Text(model.isDemo ? "Sample previews cannot write to your calendars." : "Destination: \(calendarLabel(preview.rule.destinationCalendarID))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).background(cardBackground)
    }

    private func automationSection(_ rule: SyncRule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keep it in sync").font(.headline)
                    Text("Check every 5 minutes while this app runs, and after your Mac wakes.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Automatic", isOn: Binding(get: { rule.automatic }, set: { model.setAutomatic($0, ruleID: rule.id) }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(model.isBusy || (!rule.automatic && !model.canEnableAutomatic(rule)))
            }
            Text(model.canEnableAutomatic(rule) ? "Automatic runs create and update copies. Removals remain in the preview for your review." : "Apply or confirm a full preview first to enable automatic syncing. Applying one change does not enable it. Changing this rule pauses it until you review it again.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(cardBackground)
    }

    private var visibleRuns: [RunRecord] {
        showingSummary ? model.runs : model.runs.filter { $0.ruleID != nil && $0.ruleID == model.selectedRuleID }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(showingSummary ? "Recent activity" : "Recent activity for this rule").font(.headline)
            ForEach(visibleRuns.prefix(5)) { run in
                HStack(alignment: .top) {
                    Image(systemName: run.succeeded ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(run.succeeded ? accent : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(run.ruleName).font(.caption.weight(.medium))
                        Text(run.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(run.date, style: .relative).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }.padding(20).background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func openRule(_ id: UUID) {
        model.selectedRuleID = id
        selectedTab = 0
        showingSummary = false
    }

    private func addRule(_ preset: RulePreset) {
        model.addRule(preset)
        selectedTab = 0
        showingSummary = false
    }

    private func sectionLabel(_ number: String, _ title: String) -> some View {
        HStack(spacing: 9) {
            Text(number).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
            Text(title).font(.headline)
        }
    }

    private func info(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(accent).padding(.top, 1)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private func binding<T>(_ rule: SyncRule, _ keyPath: WritableKeyPath<SyncRule, T>) -> Binding<T> {
        Binding(get: { model.rules.first(where: { $0.id == rule.id })?[keyPath: keyPath] ?? rule[keyPath: keyPath] }, set: { value in
            guard var current = model.rules.first(where: { $0.id == rule.id }) else { return }
            current[keyPath: keyPath] = value; model.updateRule(current)
        })
    }

    private func conditionBinding<T>(_ rule: SyncRule, _ condition: RuleCondition, _ keyPath: WritableKeyPath<RuleCondition, T>) -> Binding<T> {
        Binding(get: {
            (model.rules.first(where: { $0.id == rule.id })?.conditions.first(where: { $0.id == condition.id }) ?? condition)[keyPath: keyPath]
        }, set: { value in
            guard var current = model.rules.first(where: { $0.id == rule.id }), let index = current.conditions.firstIndex(where: { $0.id == condition.id }) else { return }
            current.conditions[index][keyPath: keyPath] = value; model.updateRule(current)
        })
    }

    private func calendarLabel(_ id: String) -> String { model.calendars.first { $0.id == id }?.label ?? "Unavailable calendar" }
    private var confirmationChanges: [PlannedChange] {
        guard let preview = model.preview else { return [] }
        guard let selectedChangeID else { return preview.changes }
        return preview.changes.filter { $0.id == selectedChangeID }
    }
    private func isWritableChange(_ change: PlannedChange) -> Bool {
        change.kind == .create || change.kind == .update || change.kind == .remove
    }
    private func summary(_ changes: [PlannedChange]) -> String {
        "\(changes.filter { $0.kind == .create }.count) create, \(changes.filter { $0.kind == .update }.count) update, \(changes.filter { $0.kind == .remove }.count) remove."
    }
    private func eventTime(_ payload: CopyPayload) -> String {
        if payload.isAllDay { return "\(payload.start.formatted(date: .abbreviated, time: .omitted)) · All day" }
        let endDateStyle: Date.FormatStyle.DateStyle = Calendar.current.isDate(payload.start, inSameDayAs: payload.end) ? .omitted : .abbreviated
        return "\(payload.start.formatted(date: .abbreviated, time: .shortened)) – \(payload.end.formatted(date: endDateStyle, time: .shortened)) · \(TimeZone.current.abbreviation(for: payload.start) ?? TimeZone.current.identifier)"
    }
    private func icon(_ kind: ChangeKind) -> String {
        switch kind { case .create: "plus.circle"; case .update: "arrow.triangle.2.circlepath"; case .remove: "minus.circle"; case .unchanged: "checkmark.circle"; case .conflict: "exclamationmark.triangle" }
    }
    private func color(_ kind: ChangeKind) -> Color {
        switch kind { case .create: accent; case .update: .blue; case .remove: .orange; case .unchanged: .secondary; case .conflict: .red }
    }
}
