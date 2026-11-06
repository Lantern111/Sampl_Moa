import Sparkle
import SwiftUI

@main struct MyApp: App {
    @State private var store = LibraryStore()
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        Window("Sampl Moa", id: "samples") {
            ContentView(store: store, updater: updaterController.updater)
        }
        .defaultSize(width: 1400, height: 880)
        .commands {
            SidebarCommands()

            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }

            CommandGroup(after: .newItem) {
                Button("Add Samples…") {
                    Task { await store.addFolders() }
                }
                .keyboardShortcut("o")

                Button("Rescan Library", action: store.rescan)
                    .keyboardShortcut("r")
                    .disabled(store.isScanning)
            }

            CommandMenu("Playback") {
                Button("Play or Pause", action: store.togglePlaybackOfSelection)

                Toggle("Sampler", isOn: Binding(
                    get: { store.sampler.isOpen },
                    set: { store.sampler.isOpen = $0 }
                ))
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .help) {
                Button("Getting Started with Sampl Moa") {
                    hasSeenWelcome = false
                }

                Button("How to Use the Sampler") {
                    store.sampler.isOpen = true
                    store.sampler.showsGuide = true
                }

                Button("Report a Bug…") {
                    BugReport.open()
                }
            }
        }

        Settings {
            SettingsView(updater: updaterController.updater)
        }
    }
}
