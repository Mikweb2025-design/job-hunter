import AppKit
import JobHunterCore
import SwiftUI

@main
struct JobHunterApp: App {
    @State private var model: AppModel

    init() {
        // Also behave like a normal app when launched as a bare binary (`swift run`).
        NSApplication.shared.setActivationPolicy(.regular)
        // Test instance (JOBHUNTER_DATA_DIR set): own preferences, so it never writes into the real
        // app's settings (seen jobs, send ledger …). Launch arguments still override as usual.
        let defaults = ProcessInfo.processInfo.environment["JOBHUNTER_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 } != nil
            ? (UserDefaults(suiteName: "de.daniele.JobHunter.testinstance") ?? .standard) : .standard
        _model = State(initialValue: AppModel(settings: AppSettings(defaults: defaults)))
    }

    var body: some Scene {
        Window("JobHunter", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
                .task { model.start() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Aktualisieren") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Jetzt suchen") { model.triggerRun() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isRunActive)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.settings)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            let n = model.highScoreNew.count
            Label(n > 0 ? "\(n)" : "JobHunter", systemImage: n > 0 ? "briefcase.fill" : "briefcase")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}
