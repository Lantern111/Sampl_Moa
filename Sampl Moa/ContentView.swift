import AppKit
import Sparkle
import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    let updater: SPUUpdater

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var keyMonitor: Any?
    @State private var window: NSWindow?

    private var samplerIsOpen: Binding<Bool> {
        Binding(get: { store.sampler.isOpen }, set: { store.sampler.isOpen = $0 })
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            // With the sampler open, the inspector runs the full height beside the list and the sampler, as in Logic Pro.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    LibraryView(store: store)
                    if store.sampler.isOpen {
                        Divider()
                        SamplerPanel(sampler: store.sampler, selectedSamples: store.selection)
                    }
                }
                if store.sampler.isOpen {
                    Divider()
                    SamplerInspector(sampler: store.sampler)
                }
            }
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
                    ToolbarItem(placement: .primaryAction) {
                        Toggle(isOn: samplerIsOpen) {
                            Label("Sampler", systemImage: "square.grid.4x3.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Show or hide the sampler")
                    }
                }
                .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search names, packs, genres")
                .onSubmit(of: .search, store.requestListFocus)
        }
        .frame(minWidth: store.sampler.isOpen ? 1300 : 1000, minHeight: store.sampler.isOpen ? 780 : 620)
        .background(WindowReader(window: $window))
        .sheet(isPresented: Binding(get: { !hasSeenWelcome }, set: { hasSeenWelcome = !$0 })) {
            WelcomeView(updater: updater)
        }
        .onAppear(perform: startListeningForPlaybackKeys)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfIdle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // Keys let go of in another app are never heard here.
            store.sampler.releaseComputerKeys()
        }
    }

    /// The sampler's keys come first, while it's open: those that play it from the Mac's keyboard, then its shortcuts.
    /// Then Space, Left and Right should work wherever the focus is,
    /// except while typing in a search field. An empty field doesn't count, since there's nothing to edit there yet and
    /// a field can hold focus right after launch. Settings and the welcome sheet are left alone, because these keys
    /// operate their own controls.
    private func startListeningForPlaybackKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // Letting go of a key that's playing is heard from any window, so a note can't be left ringing.
            if event.type == .keyUp {
                return SamplerComputerKeyboard.handle(event, in: store.sampler) ? nil : event
            }
            guard event.window === window else { return event }
            if SamplerComputerKeyboard.handle(event, in: store.sampler) || SamplerShortcut.handle(event, in: store.sampler) {
                return nil
            }

            let spaceKey: UInt16 = 49, leftArrow: UInt16 = 123, rightArrow: UInt16 = 124
            guard [spaceKey, leftArrow, rightArrow].contains(event.keyCode),
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
