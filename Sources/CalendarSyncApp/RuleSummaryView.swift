import CalendarSyncCore
import SwiftUI

private let summaryAccent = Color(red: 0.12, green: 0.43, blue: 0.40)

struct RuleSummaryView: View {
    let summaries: [RuleSummary]
    let isBusy: Bool
    let reviewRule: (UUID) -> Void
    @State private var search = ""
    @State private var filter = SummaryFilter.all

    private enum SummaryFilter: String, CaseIterable {
        case all = "All rules"
        case attention = "Needs attention"
        case automatic = "Automatic"
        case manual = "Manual"
    }

    private var filteredRules: [RuleSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return summaries.filter { rule in
            let matchesFilter = switch filter {
            case .all: true
            case .attention: rule.status.needsAttention
            case .automatic: rule.automaticConfigured
            case .manual: !rule.automaticConfigured
            }
            let searchable = [rule.name, rule.presetTitle, rule.sourceLabel, rule.destinationLabel] + rule.conditions
            return matchesFilter && (query.isEmpty || searchable.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                metric("Rules", value: summaries.count, detail: "Calendar connections", icon: "slider.horizontal.3")
                metric("Automatic", value: summaries.filter(\.automaticConfigured).count, detail: "Enabled in settings", icon: "arrow.triangle.2.circlepath")
                metric("Needs attention", value: summaries.filter { $0.status.needsAttention }.count, detail: "Setup or review needed", icon: "exclamationmark.circle")
                metric("Tracked copies", value: summaries.reduce(0) { $0 + $1.trackedCopyCount }, detail: "Recorded by this app", icon: "doc.on.doc")
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Text("Your rules").font(.title3.weight(.semibold))
                    Spacer()
                    Picker("Filter rules", selection: $filter) {
                        ForEach(SummaryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 190)
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search rules or calendars", text: $search).textFieldStyle(.plain)
                            .accessibilityLabel("Search rules or calendars")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Clear search")
                        }
                    }
                    .padding(9).frame(maxWidth: 250)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Review a rule to test its current matches. Tracked copies include retained history; they are not a live count of matching events.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if filteredRules.isEmpty {
                ContentUnavailableView {
                    Label("No matching rules", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Try another search or show all rules.")
                } actions: {
                    Button("Show all rules") { search = ""; filter = .all }
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(filteredRules) { summary in ruleCard(summary) }
            }
        }
    }

    private func metric(_ title: String, value: Int, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(summaryAccent)
                Spacer(minLength: 0)
                Text("\(value)").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading).padding(16).background(cardBackground)
    }

    private func ruleCard(_ rule: RuleSummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: rule.preset == .flights ? "airplane" : rule.preset == .family ? "house" : "line.3.horizontal.decrease.circle")
                    .font(.title3).foregroundStyle(summaryAccent)
                    .frame(width: 40, height: 40)
                    .background(summaryAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("\(rule.presetTitle) · \(rule.automaticConfigured ? "Automatic enabled · 5 min" : "Manual syncing")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(rule.status.title).font(.caption.weight(.medium))
                    .foregroundStyle(rule.status.needsAttention ? Color.orange : summaryAccent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background((rule.status.needsAttention ? Color.orange : summaryAccent).opacity(0.08), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(alignment: .center, spacing: 16) {
                calendar("FROM", label: rule.sourceLabel, available: rule.sourceAvailable)
                Image(systemName: "arrow.right").foregroundStyle(summaryAccent)
                calendar("TO", label: rule.destinationLabel, available: rule.destinationAvailable)
            }
            .padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(rule.matchDescription).font(.caption.weight(.semibold))
                    ForEach(Array(rule.conditions.enumerated()), id: \.offset) { _, condition in
                        HStack(alignment: .top, spacing: 7) {
                            Text("•").foregroundStyle(summaryAccent)
                            Text(condition).fixedSize(horizontal: false, vertical: true)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("What gets copied").font(.caption.weight(.semibold))
                    Text(rule.copyDescription).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(rule.coverageDescription).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            Label(rule.statusDetail, systemImage: rule.status.needsAttention ? "info.circle" : "clock")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    if let run = rule.lastRun {
                        HStack(spacing: 5) {
                            Image(systemName: run.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(run.succeeded ? summaryAccent : .orange)
                            Text("Last result · \(run.date.formatted(date: .abbreviated, time: .shortened))")
                        }.font(.caption.weight(.medium))
                        Text(run.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No recent result for this rule").font(.caption).foregroundStyle(.secondary)
                        Text("Earlier activity, if any, appears below.").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text("\(rule.trackedCopyCount) tracked \(rule.trackedCopyCount == 1 ? "copy" : "copies")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { reviewRule(rule.id) } label: {
                    Label("Review rule", systemImage: "arrow.right")
                }.buttonStyle(.bordered).disabled(isBusy)
                    .accessibilityLabel("Review rule: \(rule.name)")
            }
        }.padding(22).background(cardBackground)
    }

    private func calendar(_ title: String, label: String, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(label).font(.subheadline).foregroundStyle(available ? Color.primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.07)))
    }
}
