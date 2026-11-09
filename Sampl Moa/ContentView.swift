import AppKit
import Sparkle
import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    let updater: SPUUpdater

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var keyMonitor: Any?
    @State private var window: NSWindow?
    /// The sampler and its inspector lie over the list and slide in and out over it, so there's always the list
    /// underneath, never a gap. Opening, they're built out of sight, slide in, and only then does the list make room
    /// beside them. Closing, the list takes the room back first, hidden underneath, and then they slide away. The
    /// heavy work, building them or laying the list out again, never lands in the middle of a slide.
    @State private var samplerIsBuilt: Bool
    @State private var samplerIsShown: Bool
    @State private var listMakesRoom: Bool
    @State private var samplerMotion: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let samplerSize = CGSize(width: 1300, height: 780)
    private static let librarySize = CGSize(width: 1000, height: 620)

    init(store: LibraryStore, updater: SPUUpdater) {
        self.store = store
        self.updater = updater
        _samplerIsBuilt = State(initialValue: store.sampler.isOpen)
        _samplerIsShown = State(initialValue: store.sampler.isOpen)
        _listMakesRoom = State(initialValue: store.sampler.isOpen)
    }

    private var samplerIsOpen: Binding<Bool> {
        Binding(get: { store.sampler.isOpen }, set: { store.sampler.isOpen = $0 })
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
        } detail: {
            // With the sampler open, the inspector runs the full height beside the list and the sampler, as in Logic Pro.
            LibraryView(store: store)
                .padding(.trailing, listMakesRoom ? Self.inspectorRoom : 0)
                .padding(.bottom, listMakesRoom ? Self.panelRoom : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Moving these changes nothing else's size, so a slide only has to redraw them.
                .overlay(alignment: .bottomLeading) {
                    if samplerIsBuilt {
                        VStack(spacing: 0) {
                            Divider()
                            SamplerPanel(sampler: store.sampler, selectedSamples: store.selection)
                        }
                        .padding(.trailing, Self.inspectorRoom)
                        .offset(y: samplerIsShown || reduceMotion ? 0 : Self.panelRoom)
                        .opacity(samplerIsShown || !reduceMotion ? 1 : 0)
                        .allowsHitTesting(samplerIsShown)
                    }
                }
                .overlay(alignment: .trailing) {
                    if samplerIsBuilt {
                        HStack(spacing: 0) {
                            Divider()
                            SamplerInspector(sampler: store.sampler)
                        }
                        .frame(maxHeight: .infinity)
                        .offset(x: samplerIsShown || reduceMotion ? 0 : Self.inspectorRoom)
                        .opacity(samplerIsShown || !reduceMotion ? 1 : 0)
                        .allowsHitTesting(samplerIsShown)
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
        .frame(
            minWidth: samplerIsBuilt ? Self.samplerSize.width : Self.librarySize.width,
            minHeight: samplerIsBuilt ? Self.samplerSize.height : Self.librarySize.height
        )
        // However it's opened: the toolbar, the menu, or its shortcut.
        .onChange(of: store.sampler.isOpen) { _, isOpen in
            if isOpen { showSampler() } else { hideSampler() }
        }
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

    private static let slideDuration = 0.34
    private static let growDuration = 0.28
    /// What the sampler and its inspector cover, dividers included.
    private static let panelRoom = SamplerPanel.height + 1
    private static let inspectorRoom = SamplerInspector.width + 1

    private func showSampler() {
        samplerMotion?.cancel()
        samplerMotion = Task {
            if !samplerIsBuilt {
                await growWindowForSampler()
                guard !Task.isCancelled else { return }
                samplerIsBuilt = true
                // The first frames with the sampler in them take a moment to build. Waiting for them to reach the
                // screen means the slide starts from its beginning rather than partway through.
                await waitForScreenToSettle()
                guard !Task.isCancelled else { return }
            }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: Self.slideDuration)) {
                samplerIsShown = true
            }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.15 : Self.slideDuration))
            guard !Task.isCancelled else { return }
            // Out of sight, under the sampler.
            listMakesRoom = true
        }
    }

    private func hideSampler() {
        samplerMotion?.cancel()
        samplerMotion = Task {
            if listMakesRoom {
                // Out of sight, under the sampler, so there's a whole list there as it slides away.
                listMakesRoom = false
                await waitForScreenToSettle()
                guard !Task.isCancelled else { return }
            }
            let duration = reduceMotion ? 0.15 : Self.slideDuration * 0.85
            withAnimation(reduceMotion ? .easeIn(duration: duration) : .smooth(duration: duration)) {
                samplerIsShown = false
            }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            samplerIsBuilt = false
        }
    }

    /// Waits until a frame's worth of waiting takes about a frame, which means nothing heavy is holding up the screen,
    /// or until it's been long enough.
    private func waitForScreenToSettle() async {
        for _ in 0..<6 {
            let start = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(16))
            if ContinuousClock.now - start < .milliseconds(40) { return }
        }
    }

    /// Grows a window that's too small for the sampler before the sampler goes in, while there's only the list to lay
    /// out. The top left corner stays put, as when a window is resized by hand, unless that would take it off the
    /// screen.
    private func growWindowForSampler() async {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let room = window.contentLayoutRect.size
        let extra = CGSize(
            width: max(0, Self.samplerSize.width - room.width),
            height: max(0, Self.samplerSize.height - room.height)
        )
        guard extra.width > 0 || extra.height > 0 else { return }
        var frame = window.frame
        frame.size.width += extra.width
        frame.size.height += extra.height
        frame.origin.y -= extra.height
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width))
            frame.origin.y = min(max(frame.minY, screen.minY), max(screen.minY, screen.maxY - frame.height))
        }
        guard !reduceMotion else {
            window.setFrame(frame, display: true)
            return
        }
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.growDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            } completionHandler: {
                continuation.resume()
            }
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
