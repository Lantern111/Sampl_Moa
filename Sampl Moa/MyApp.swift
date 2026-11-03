import SwiftUI

@main struct MyApp: App {
    @State private var store = LibraryStore()

    var body: some Scene {
        Window("Sampl Moa", id: "samples") {
            ContentView(store: store)
        }
        .defaultSize(width: 1400, height: 880)
        .commands {
            SidebarCommands()

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
            }
        }
    }
}
