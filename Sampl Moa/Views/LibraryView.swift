import SwiftUI

struct LibraryView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            detail
                .navigationTitle("Sampl Moa")
                .navigationSubtitle(String(localized: "\(store.visibleSamples.count) samples"))
                .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search samples and packs")
                .toolbar {
                    ToolbarItem {
                        Button("Rescan", systemImage: "arrow.clockwise", action: store.rescan)
                            .disabled(store.isScanning)
                    }
                }
        }
    }

    private var sidebar: some View {
        List(selection: scopeSelection) {
            Label("All Samples", systemImage: "square.stack.3d.up")
                .badge(store.totalSampleCount)
                .tag(LibraryScope.all)

            Section("Accounts") {
                ForEach(store.accounts) { account in
                    Label(account.name, systemImage: "person.crop.circle")
                        .badge(store.sampleCount(in: account))
                        .tag(LibraryScope.account(account.id))
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !store.visibleSamples.isEmpty {
            SampleTable(samples: store.visibleSamples, sort: $store.sort)
        } else if store.isScanning {
            ProgressView("Looking for samples…")
        } else if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else if store.accounts.isEmpty {
            ContentUnavailableView(
                "No Splice Folders Found",
                systemImage: "folder.badge.questionmark",
                description: Text("Splice creates its folder in your user folder after you sign in. Rescan once it’s there.")
            )
        } else {
            ContentUnavailableView(
                "No Samples Yet",
                systemImage: "waveform",
                description: Text("Samples you download from Splice will appear here.")
            )
        }
    }

    /// `List` clears an optional selection when you click empty space, but one scope must always be active.
    private var scopeSelection: Binding<LibraryScope?> {
        Binding {
            store.scope
        } set: { newValue in
            if let newValue { store.scope = newValue }
        }
    }
}
