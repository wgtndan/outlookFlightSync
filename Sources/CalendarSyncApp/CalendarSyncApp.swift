import AppKit
import SwiftUI

@main
struct CalendarSyncApp: App {
    @NSApplicationDelegateAdaptor(CalendarSyncAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Calendar Sync", id: "main") {
            ContentView(model: model)
                .task {
                    model.start()
                    appDelegate.configure(model: model)
                }
        }
        .defaultSize(width: 1_100, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Calendar Sync") { showWindow() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }

        MenuBarExtra("Calendar Sync", systemImage: model.isBusy ? "arrow.triangle.2.circlepath" : "calendar.badge.clock") {
            Text(model.isDemo ? "Sample data" : "\(model.automaticCount) automatic rules")
            Button("Open Calendar Sync") { showWindow() }
            Button("Check automatic rules now") { Task { await model.runAutomatic() } }
                .disabled(model.isBusy || model.automaticCount == 0 || model.isDemo)
            Button("Pause all rules") { model.pauseAll() }
                .disabled(model.isBusy || model.automaticCount == 0)
            Divider()
            Button("Quit Calendar Sync") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class CalendarSyncAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var hasFinishedLaunching = false

    func configure(model: AppModel) {
        guard !ProcessInfo.processInfo.arguments.contains("--diagnose-sync") else { return }
        self.model = model
        if hasFinishedLaunching { model.restoreDockVisibility() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hasFinishedLaunching = true
        model?.restoreDockVisibility()
    }
}
