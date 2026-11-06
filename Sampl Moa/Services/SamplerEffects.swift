import AVFoundation
import AppKit
import CoreAudioKit
import Observation

/// Audio Unit plug-ins, the same kind Logic Pro uses, on one pad or on everything the sampler plays.
///
/// They run in a separate process wherever they can. A plug-in that crashes then can't take the app down with it.
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

    private func load(_ plugin: Available) async -> AVAudioUnit? {
        if let unit = await load(plugin, options: .loadOutOfProcess) { return unit }
        return await load(plugin, options: [])
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
        for plugin in loaded {
            if let slot = plugin.slot { slotPlugins[slot, default: []].append(plugin.unit) }
        }
        engine.setPlugins(chain(for: nil).map(\.unit), slotPlugins: slotPlugins)
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

    func setOn(_ isOn: Bool, for plugin: Loaded) {
        plugin.isOn = isOn
        readSettings()
    }

    // MARK: - Plug-in windows

    func openEditor(of plugin: Loaded) {
        if let window = plugin.window {
            window.makeKeyAndOrderFront(nil)
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
    private func showWindow(for plugin: Loaded, with controller: NSViewController?) {
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
