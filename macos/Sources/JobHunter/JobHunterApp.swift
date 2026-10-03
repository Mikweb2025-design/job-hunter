import AppKit
import JobHunterCore
import SwiftUI

@main
struct JobHunterApp: App {
    @State private var model: AppModel

    init() {
        // Also behave like a normal app when launched as a bare binary (`swift run`).
        NSApplication.shared.setActivationPolicy(.regular)
        _model = State(initialValue: AppModel(settings: AppSettings()))
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
