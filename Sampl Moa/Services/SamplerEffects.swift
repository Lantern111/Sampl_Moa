import AVFoundation
import AppKit
import CoreAudioKit
import Observation
import SwiftUI

/// Audio Unit plug-ins, the same kind Logic Pro uses, on one pad or on everything the sampler plays.
///
/// Other companies' plug-ins run in a separate process wherever they can, so one that crashes can't take the app down
/// with it. Apple's own run inside the app, which saves handing every block of sound to another process and back.
/// A plug-in that's switched off is taken out of the sound altogether, rather than being passed sound to ignore.
@Observable
final class SamplerEffects {
    struct Available: Identifiable, Hashable {
        let name: String
        let manufacturer: String
        let type: UInt32
        let subType: UInt32
        let manufacturerCode: UInt32

        var id: String { "\(type).\(subType).\(manufacturerCode)" }

        var description: AudioComponentDescription {
            AudioComponentDescription(
                componentType: type,
                componentSubType: subType,
                componentManufacturer: manufacturerCode,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        }
    }

    @Observable
    final class Loaded: Identifiable {
        let id = UUID()
        let name: String
        let source: Available
        let unit: AVAudioUnit
        /// The pad or keyboard it belongs to, or nil if everything passes through it.
        let slot: Int?
        var isOn = true {
            didSet { unit.auAudioUnit.shouldBypassEffect = !isOn }
        }
        @ObservationIgnored fileprivate var window: NSWindow?
        @ObservationIgnored fileprivate var closeObserver: NSObjectProtocol?

        init(source: Available, unit: AVAudioUnit, slot: Int?) {
            self.name = SamplerBuiltInEffect.matching(
                type: source.type,
                subType: source.subType,
                manufacturer: source.manufacturerCode
            )?.title ?? source.name
            self.source = source
            self.unit = unit
            self.slot = slot
        }
    }

    private static let longestWaitForPlugin: TimeInterval = 20

    private(set) var available: [Available] = []
    private(set) var loaded: [Loaded] = []
    private(set) var isAdding = false
    /// The name of a plug-in that wouldn't load here, to say so instead of quietly doing nothing.
    private(set) var pluginThatFailed: String?

    /// What gets written to disk. A plug-in's settings are read when its window closes, not on every save, since
    /// asking a plug-in in another process for them takes a moment.
    @ObservationIgnored private(set) var savedEntries: [SamplerPluginEntry] = []

    @ObservationIgnored private let engine: SamplerEngine
    @ObservationIgnored private let onChange: () -> Void
    /// The recorder's tempo, for setting a delay in time with it.
    @ObservationIgnored var tempo: () -> Double = { 120 }

    init(engine: SamplerEngine, onChange: @escaping () -> Void) {
        self.engine = engine
        self.onChange = onChange
    }

    /// The plug-ins on a pad, or those on everything if `slot` is nil.
    func chain(for slot: Int?) -> [Loaded] {
        loaded.filter { $0.slot == slot }
    }

    var manufacturers: [String] {
        var seen: Set<String> = []
        return available.map(\.manufacturer).filter { seen.insert($0).inserted }
    }

    func findAvailablePlugins() {
        guard available.isEmpty else { return }
        Task { available = await Self.installedPlugins() }
    }

    @concurrent nonisolated private static func installedPlugins() async -> [Available] {
        let kinds: [OSType] = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        let components = kinds.flatMap { kind in
            AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription(
                componentType: kind,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            ))
        }
        return components
            .map { component in
                let description = component.audioComponentDescription
                return Available(
                    name: component.name,
                    manufacturer: component.manufacturerName,
                    type: description.componentType,
                    subType: description.componentSubType,
                    manufacturerCode: description.componentManufacturer
                )
            }
            .sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
    }

    func add(_ effect: SamplerBuiltInEffect, to slot: Int?) {
        add(Available(
            name: effect.title,
            manufacturer: "Apple",
            type: effect.description.componentType,
            subType: effect.subType,
            manufacturerCode: effect.description.componentManufacturer
        ), to: slot)
    }

    func dismissFailure() {
        pluginThatFailed = nil
    }

    func add(_ plugin: Available, to slot: Int?) {
        isAdding = true
        pluginThatFailed = nil
        Task {
            defer { isAdding = false }
            guard let unit = await load(plugin) else {
                pluginThatFailed = plugin.name
                return
            }
            SamplerBuiltInEffect.matching(type: plugin.type, subType: plugin.subType, manufacturer: plugin.manufacturerCode)?
                .applyStartingSettings(to: unit)
            let new = Loaded(source: plugin, unit: unit, slot: slot)
            loaded.append(new)
            chainChanged()
            openEditor(of: new)
        }
    }

    func remove(_ plugin: Loaded) {
        plugin.window?.close()
        loaded.removeAll { $0.id == plugin.id }
        chainChanged()
    }

    func restore(_ entries: [SamplerPluginEntry]) {
        guard !entries.isEmpty else { return }
        savedEntries = entries
        Task {
            for entry in entries {
                let source = Available(
                    name: entry.name,
                    manufacturer: "",
                    type: entry.type,
                    subType: entry.subType,
                    manufacturerCode: entry.manufacturer
                )
                guard let unit = await load(source) else {
                    pluginThatFailed = entry.name
                    continue
                }
                let new = Loaded(source: source, unit: unit, slot: entry.slot)
                Self.apply(entry.state, to: unit)
                new.isOn = entry.isOn
                loaded.append(new)
            }
            sendChainsToEngine()
        }
    }

    /// New copies of a chain with the same settings, for rendering to a file. A plug-in can only be in one place.
    func copies(for slot: Int?) async -> [AVAudioUnit] {
        var units: [AVAudioUnit] = []
        for plugin in chain(for: slot) where plugin.isOn {
            guard let unit = await load(plugin.source) else {
                pluginThatFailed = plugin.name
                continue
            }
            unit.auAudioUnit.fullState = plugin.unit.auAudioUnit.fullState
            units.append(unit)
        }
        return units
    }

    private static func apply(_ state: Data?, to unit: AVAudioUnit) {
        guard let state,
              let settings = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any]
        else { return }
        unit.auAudioUnit.fullState = settings
    }

    /// Apple's own run inside the app, which costs less. Everyone else's run only in a process of their own, so one
    /// that misbehaves can't take the app down with it. Copy-protected plug-ins, like Universal Audio's, would: they
    /// rewrite their own code as they start, which macOS doesn't let this app run, and it's closed on the spot.
    private func load(_ plugin: Available) async -> AVAudioUnit? {
        if plugin.manufacturerCode == kAudioUnitManufacturer_Apple {
            if let unit = await load(plugin, options: []) { return unit }
            return await load(plugin, options: .loadOutOfProcess)
        }
        let start = ContinuousClock.now
        if let unit = await load(plugin, options: .loadOutOfProcess) { return unit }
        // Turned down quickly, as can happen while the plug-in service is still starting just after launch, it gets
        // one more try. One that took its time already had its chance.
        guard ContinuousClock.now - start < .seconds(5) else { return nil }
        try? await Task.sleep(for: .seconds(1))
        return await load(plugin, options: .loadOutOfProcess)
    }

    /// A plug-in can sit waiting for a licence check or anything else, so it only gets so long to answer.
    private func load(_ plugin: Available, options: AudioComponentInstantiationOptions) async -> AVAudioUnit? {
        await withCheckedContinuation { continuation in
            let answer = SingleAnswer(continuation)
            AVAudioUnit.instantiate(with: plugin.description, options: options) { unit, _ in
                answer.give(unit)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.longestWaitForPlugin) {
                answer.give(nil)
            }
        }
    }

    /// Whichever comes first, the plug-in or the time limit, is the answer.
    private final class SingleAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AVAudioUnit?, Never>?

        init(_ continuation: CheckedContinuation<AVAudioUnit?, Never>) {
            self.continuation = continuation
        }

        func give(_ unit: AVAudioUnit?) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: unit)
        }
    }

    private func chainChanged() {
        sendChainsToEngine()
        readSettings()
    }

    private func sendChainsToEngine() {
        var slotPlugins: [Int: [AVAudioUnit]] = [:]
        for plugin in loaded where plugin.isOn {
            if let slot = plugin.slot { slotPlugins[slot, default: []].append(plugin.unit) }
        }
        engine.setPlugins(chain(for: nil).filter(\.isOn).map(\.unit), slotPlugins: slotPlugins)
    }

    private func readSettings() {
        savedEntries = loaded.map { plugin in
            SamplerPluginEntry(
                name: plugin.name,
                type: plugin.source.type,
                subType: plugin.source.subType,
                manufacturer: plugin.source.manufacturerCode,
                slot: plugin.slot,
                isOn: plugin.isOn,
                state: plugin.unit.auAudioUnit.fullState.flatMap {
                    try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
                }
            )
        }
        onChange()
    }

    /// Switching a plug-in off or on rebuilds the chain, which stops any sound for a moment, the same as adding one.
    func setOn(_ isOn: Bool, for plugin: Loaded) {
        plugin.isOn = isOn
        chainChanged()
    }

    // MARK: - Plug-in windows

    func openEditor(of plugin: Loaded) {
        if let window = plugin.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // The built-in effects have windows of this app's own, since Apple's are hard to make sense of.
        if let effect = SamplerBuiltInEffect.matching(type: plugin.source.type, subType: plugin.source.subType, manufacturer: plugin.source.manufacturerCode) {
            let editor = NSHostingController(rootView: SamplerEffectEditor(
                effect: effect,
                plugin: plugin,
                onTurnOn: { [weak self, weak plugin] isOn in
                    guard let self, let plugin else { return }
                    self.setOn(isOn, for: plugin)
                },
                tempo: { [weak self] in self?.tempo() ?? 120 }
            ))
            editor.sizingOptions = .preferredContentSize
            showWindow(for: plugin, with: editor, isDark: true)
            return
        }
        plugin.unit.auAudioUnit.requestViewController { [weak self, weak plugin] controller in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let plugin else { return }
                    self.showWindow(for: plugin, with: controller)
                }
            }
        }
    }

    /// A plug-in with no window of its own still gets plain controls for its settings.
    private func showWindow(for plugin: Loaded, with controller: NSViewController?, isDark: Bool = false) {
        let content: NSViewController
        if let controller {
            content = controller
        } else {
            let generic = AUGenericViewController()
            generic.auAudioUnit = plugin.unit.auAudioUnit
            content = generic
        }

        let window = NSWindow(contentViewController: content)
        window.title = plugin.name
        window.isReleasedWhenClosed = false
        if isDark {
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(white: 0.12, alpha: 1)
            window.styleMask.remove(.resizable)
        }
        if content.preferredContentSize != .zero {
            window.setContentSize(content.preferredContentSize)
        }
        plugin.window = window
        plugin.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak plugin] _ in
            MainActor.assumeIsolated {
                plugin?.window = nil
                self?.readSettings()
            }
        }
        window.makeKeyAndOrderFront(nil)
    }
}
