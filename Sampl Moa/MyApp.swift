import SwiftUI

@main struct MyApp: App {
    @State private var store = LibraryStore()

    var body: some Scene {
        Window("Sampl Moa", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Library", action: store.rescan)
                    .keyboardShortcut("r")
                    .disabled(!store.hasAccess || store.isScanning)

                Button("Choose Library Folder…") {
                    Task { await store.chooseFolder() }
                }
            }
        }
    }
}
