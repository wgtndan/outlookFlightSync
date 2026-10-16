# Architecture

Calendar Sync is a local macOS menu-bar application built with SwiftUI. Its current provider is EventKit, so calendar availability follows the accounts configured in macOS, rather than the accounts held privately by Outlook. The UI, matching engine, reconciliation and persistence all run locally. macOS is responsible for communicating with iCloud and Exchange.

## Components

- `CalendarSyncCore`: value models, condition matching, copy policies, ownership markers and change planning. This layer can be tested with synthetic events without opening a real calendar store.
- `CalendarSyncApp`: native UI, EventKit access, sync coordination, SQLite persistence, timer and optional login-item integration.
- `CSQLite`: module map for the SQLite library from the macOS SDK.
- `Resources`: bundle identity, calendar permission descriptions and calendar entitlement. The development bundle is not App Sandbox enabled.
- `scripts/build-app.sh`: packaging steps for debug/release builds on the current or selected architecture. `scripts/package-release.sh` creates and verifies Apple Silicon and Intel release archives with checksums. Builds are not claimed to be byte-for-byte reproducible across different Swift/macOS SDK versions.

## Rule and execution model

A rule selects exactly one source calendar and one destination calendar, a preset/copy policy, conditions, and a date window. Multiple rules are supported. A work-flights → iCloud rule and an iCloud-family → work rule remain independent source-authoritative copies; they are not bidirectional editing of the same event.

The app reads source occurrences and managed destination copies, evaluates conditions, and produces a preview of creates, updates, unchanged copies, removals and conflicts. The preview explains matches before any changes are applied. Reconciliation uses app-owned markers and stored mappings, never title/date coincidence alone. Copies include the marker in their URL field; changing that field can break ownership detection and should require review rather than adoption of an unrelated event.

Source events owned by this app are excluded from matching. Writes target the rule's destination calendar only. A family-copy policy removes descriptive content and marks busy time where supported, but **cannot set Exchange/Outlook Private sensitivity through the EventKit API used by this prototype**.

Flight and custom payloads include optional notes text. Missing notes in older saved payloads decode as nil; reconciliation proposes updates for existing copies whose notes differ. Family payloads always use nil notes. Approval digests include the expanded copy-policy version for flight/custom rules, so a prior approval to omit notes cannot silently enable copying them automatically.

A successful confirmation of the full preview establishes approval for the current rule configuration. A single-row apply revalidates the complete preview, writes only the selected create/update/removal, and acknowledges only that source's pending operations. It does not approve the whole rule for automatic syncing. Conflicts anywhere in the rule still block both full and single-row applies. Automatic creates and updates are opt-in and run approximately every five minutes while the app is running and the Mac can execute them. Changing the rule invalidates the approval. The default reconciliation window is seven days in the past and 180 days ahead. Recurring events are materialized as separate occurrences within that window.

Removals require an explicit manual preview and Apply confirmation showing the removal count and destination. Disappearance from a local cache never triggers automatic deletion. Before applying, the coordinator rebuilds the plan, and the EventKit adapter rechecks the source and destination ownership. Automatic sync does not remove events. Conflicting or uncertain ownership is surfaced for review.

## Summary and rule review

`RuleSummary` derives a read-only presentation from saved rules, mappings, approvals, run history, and the already-loaded calendar list. `RuleSummaryView` is the default landing view for configured rules and provides cards, search, and All rules/Needs attention/Automatic/Manual filters. Cards show account-aware calendar labels, conditions, copy policy, date window, status, tracked mappings, and the last result. Review rule opens the existing editor; it does not preview or apply a rule.

Status accounts for invalid configuration, permission, missing or read-only calendars, unavailable storage, interrupted operations, preview conflicts or removals, failed runs, and missing approval. Automatic counts and filters describe the stored setting, while the status explains any current pause. Tracked copies count local mappings, including retained history, and are not a fresh provider inventory.

New run records carry an optional stable rule ID. Per-rule results match that ID, so renaming a rule retains its history and two rules with the same name remain distinct. Older records without an ID continue to decode and appear in global Recent activity, but are not attributed by name. The Summary adds no calendar reads or writes of its own and does not change reconciliation or approval behavior.

## Persistence and permissions

SQLite stores rules, approval state and mappings in `~/Library/Application Support/CalendarSync/state.sqlite`. It is local state, not a calendar transport. Account credentials remain with macOS. This app has no hosted service, OAuth client registration, token vault or credential export from Outlook.

Calendar access is requested from an explicit UI action. The bundle includes both modern full-access and fallback calendar usage descriptions. The menu-bar process can remain open after the settings window closes; launch at login is a separate user choice. Building the bundle does not execute it or request permissions. `--demo` uses fictitious data without real EventKit access.

## Preview release boundaries

Validate live account synchronization, recurrence exceptions, time zones, revoked permissions and sleep/wake behavior with disposable calendars. EventKit can only see what macOS has successfully synchronized. The [current Apple Exchange sign-in guidance](https://support.apple.com/en-us/149092) is especially relevant during Exchange Online EWS retirement.

True Outlook Private sensitivity remains unsupported. The agreed first version uses the generic `Family Commitment` title with descriptive details removed. A future provider could implement the actual flag through an approved Microsoft API; it must not be represented as solved by content redaction. A future Outlook task pane would also need its own packaging/hosting arrangement and cannot inherit unrestricted access to Outlook's account store.

The project is published under the MIT license. Version 0.1.4 is a public preview with ad-hoc-signed Apple Silicon and Intel downloads; Developer ID signing and Apple notarization remain future work. CI tests the app and packages verified archives without accessing real calendars. Release publication is a separate maintainer action.

## Validation and next steps

Version 0.1.4 passes 91 automated tests using synthetic events and temporary databases. Coverage includes flight matching, family redaction, recurring occurrence identity, source-authoritative updates, ownership and loop prevention, interrupted operations, selective journal recovery, and rejecting corrupt saved state. Notes tests cover multiline text, additions, edits, removals, family redaction, and compatibility with older saved mappings. Single-change tests cover exact selection, stale previews, conflicts, pending-operation scope, and preserving the full-rule approval boundary. Native EventKit tests also reproduce the nonnil occurrence date on standalone appointments, which caused the original post-save verification failure, and verify copied notes without logging their contents. Summary tests cover status precedence, mapping counts, and stable rule history without attributing legacy name-only records. Native UI checks use sample data. These checks do not establish complete provider round-trip behavior.

The `--diagnose-sync` launch argument performs read-only checks of pending operations before timers or automatic syncing start, then exits. It reads SQLite with `SQLITE_OPEN_READONLY`, never requests Calendar access, and reports field comparisons without event titles, notes, calendar names, dates, or identifiers. An existing Calendar grant is required for provider checks. Ad-hoc rebuilds may invalidate that grant; a signed distribution identity is still required for a smoother update experience.

Before enabling a real rule:

1. Grant Calendar access in the app, select disposable source/destination calendars, and verify the account labels and write capability.
2. Create a fictional flight and a fictional family event; preview and apply each rule. Confirm the copies reach the provider and appear in Outlook, and that the ownership URL survives synchronization.
3. Change a source time, restart the app, and confirm exactly one copy updates. Check a recurring event, a moved occurrence, an all-day event, and a flight crossing time zones.
4. Remove or unmatch a source and confirm the proposed removal is shown for review, while automatic sync leaves the copy untouched.
5. Enable automatic syncing, then exercise sleep/wake, temporary network loss, and revoked Calendar access.

Broader live provider testing, Developer ID signing and notarization are the next distribution milestones. No hosted sync service is required for this roadmap.
