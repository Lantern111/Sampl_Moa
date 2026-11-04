import AppKit
import Sparkle
import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    let updater: SPUUpdater

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var keyMonitor: Any?
    @State private var window: NSWindow?

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            LibraryView(store: store)
                .navigationTitle(store.title)
                .navigationSubtitle(String(localized: "\(store.visibleSamples.count) samples"))
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Library", selection: $store.tab) {
                            Text("Samples").tag(LibraryTab.splice)
                            Text("My Folders").tag(LibraryTab.folders)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await store.addFolders() }
                        } label: {
                            Label("Add Samples", systemImage: "plus")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Add a folder of samples")
                    }
                }
                .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search names, packs, genres")
                .onSubmit(of: .search, store.requestListFocus)
        }
        .frame(minWidth: 1000, minHeight: 620)
        .background(WindowReader(window: $window))
        .sheet(isPresented: Binding(get: { !hasSeenWelcome }, set: { hasSeenWelcome = !$0 })) {
            WelcomeView(updater: updater)
        }
        .onAppear(perform: startListeningForPlaybackKeys)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfIdle()
        }
    }

    /// Space, Left and Right should work wherever the focus is, except while typing in a search field. An empty field
    /// doesn't count, since there's nothing to edit there yet and a field can hold focus right after launch. Settings
    /// and the welcome sheet are left alone, because these keys operate their own controls.
    private func startListeningForPlaybackKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let spaceKey: UInt16 = 49, leftArrow: UInt16 = 123, rightArrow: UInt16 = 124
            guard event.window === window,
                  [spaceKey, leftArrow, rightArrow].contains(event.keyCode),
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
            else { return event }
            if let editor = event.window?.firstResponder as? NSTextView, !editor.string.isEmpty { return event }

            switch event.keyCode {
            case spaceKey:
                store.togglePlaybackOfSelection()
            case leftArrow:
                // Holding the key shouldn't stutter the start of the sample over and over.
                if !event.isARepeat { store.replaySelection() }
            default:
                store.selectNextSample()
            }
            return nil
        }
    }
}

/// Reports which window a view is in.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onMove = { newWindow in
            DispatchQueue.main.async { window = newWindow }
        }
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {}

    final class ReportingView: NSView {
        var onMove: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            onMove?(window)
        }
    }
}

#Preview {
    ContentView(
        store: LibraryStore(),
        updater: SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater
    )
}
