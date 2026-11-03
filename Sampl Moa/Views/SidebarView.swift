import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var store: LibraryStore

    @State private var packQuery = ""

    private var filteredPacks: [SamplePack] {
        guard !packQuery.isEmpty else { return store.packs }
        return store.packs.filter { $0.name.localizedCaseInsensitiveContains(packQuery) }
    }

    /// `List` clears an optional selection when you click empty space, but one scope must always be active.
    private var scopeSelection: Binding<LibraryScope?> {
        Binding {
            store.scope
        } set: { newValue in
            if let newValue { store.scope = newValue }
        }
    }

    var body: some View {
        List(selection: scopeSelection) {
            Label("All Samples", systemImage: "waveform")
                .badge(store.tabSampleCount)
                .tag(LibraryScope.all)

            switch store.tab {
            case .splice:
                if !store.packs.isEmpty {
                    Section("Packs") {
                        ForEach(filteredPacks) { pack in
                            Label(pack.name, systemImage: "square.stack")
                                .lineLimit(1)
                                .badge(pack.sampleCount)
                                .tag(LibraryScope.pack(pack.name))
                        }
                    }
                }
            case .folders:
                if !store.folders.isEmpty {
                    Section("Folders") {
                        ForEach(store.folders) { folder in
                            Label(folder.name, systemImage: "folder")
                                .lineLimit(1)
                                .badge(folder.sampleCount)
                                .tag(LibraryScope.folder(folder.url))
                                .help(folder.url.path)
                                .contextMenu {
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                                    }
                                    Button("Remove from List") {
                                        store.removeFolder(folder.url)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            if store.tab == .splice, !store.packs.isEmpty {
                PackSearchField(text: $packQuery)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 360)
    }
}

/// The standard search field. SwiftUI's `searchable` only offers one per window, and the toolbar has it.
private struct PackSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Find a Pack")
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
