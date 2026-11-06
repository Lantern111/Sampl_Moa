import AVFoundation
import Accelerate
import AudioToolbox
import Foundation

/// How the mixer's outputs connect, the same whether they're going to the speakers or to a file:
///
///     sounds ───────────────────┐
///     a pad with plug-ins → its plug-ins ─┤
///     delay send → delay ───────┼─→ master → master EQ and volume → master plug-ins → out
///     reverb send → reverb ─────┘
nonisolated enum SamplerGraph {
    struct Built {
        /// Everything attached, for taking apart later.
        let nodes: [AVAudioNode]
        let masterEQ: AVAudioUnitEQ
        /// The last stop before the output, where the master meter listens.
        let last: AVAudioNode
    }

    static func build(
        in engine: AVAudioEngine,
        mixer: SamplerMixer,
        format: AVAudioFormat,
        master settings: SamplerMaster,
        plugins: [AVAudioUnit],
        slotPlugins: [Int: [AVAudioUnit]]
    ) -> Built {
        mixer.setIsolatedSlots(Set(slotPlugins.keys))
        let masterEQ = AVAudioUnitEQ(numberOfBands: 3)
        configure(masterEQ, for: settings)

        let master = AVAudioMixerNode()
        let delay = AVAudioUnitDelay()
        delay.delayTime = 0.375
        delay.feedback = 35
        delay.lowPassCutoff = 9000
        delay.wetDryMix = 100
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.plate)
        reverb.wetDryMix = 100

        // Only this first one does the mixing. A mixer asks its inputs in order, so this goes first and the others
        // read what it made.
        let sounds = source(format: format) { [mixer] frames, left, right in
            mixer.render(frames: frames, left: left, right: right)
        }
        let delaySend = source(format: format) { [mixer] frames, left, right in
            mixer.copy(.delay, frames: frames, left: left, right: right)
        }
        let reverbSend = source(format: format) { [mixer] frames, left, right in
            mixer.copy(.reverb, frames: frames, left: left, right: right)
        }

        var nodes: [AVAudioNode] = [master, masterEQ, delay, reverb, sounds, delaySend, reverbSend]
        nodes.append(contentsOf: plugins)
        nodes.forEach(engine.attach)

        engine.connect(sounds, to: master, format: format)
        engine.connect(delaySend, to: delay, format: format)
        engine.connect(delay, to: master, format: format)
        engine.connect(reverbSend, to: reverb, format: format)
        engine.connect(reverb, to: master, format: format)

        for (slot, units) in slotPlugins.sorted(by: { $0.key < $1.key }) {
            let slotSource = source(format: format) { [mixer] frames, left, right in
                mixer.copy(slot: slot, frames: frames, left: left, right: right)
            }
            nodes.append(slotSource)
            engine.attach(slotSource)

            var last: AVAudioNode = slotSource
            for unit in units {
                nodes.append(unit)
                engine.attach(unit)
                engine.connect(last, to: unit, format: format)
                last = unit
            }
            engine.connect(last, to: master, format: format)
        }

        engine.connect(master, to: masterEQ, format: format)
        var last: AVAudioNode = masterEQ
        for plugin in plugins {
            engine.connect(last, to: plugin, format: format)
            last = plugin
        }
        engine.connect(last, to: engine.mainMixerNode, format: format)
        return Built(nodes: nodes, masterEQ: masterEQ, last: last)
    }

    /// The master's volume is the EQ's overall gain, which goes up to +24 dB where a mixer's volume stops at 0.
    static func configure(_ eq: AVAudioUnitEQ, for settings: SamplerMaster) {
        let shapes: [(AVAudioUnitEQFilterType, Float, Double)] = [
            (.lowShelf, 150, settings.eqLow),
            (.parametric, 1000, settings.eqMid),
            (.highShelf, 6000, settings.eqHigh),
        ]
        for (band, shape) in zip(eq.bands, shapes) {
            band.filterType = shape.0
            band.frequency = shape.1
            band.bandwidth = 1.25
            band.gain = Float(shape.2)
            band.bypass = false
        }
        eq.globalGain = settings.gain > 0.0001 ? Float(20 * log10(Double(settings.gain))) : -96
    }

    private static func source(
        format: AVAudioFormat,
        render: @escaping @Sendable (Int, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void
    ) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frames, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_InvalidParameter }
            render(Int(frames), left, right)
            return noErr
        }
    }
}

/// Connects the mixer to the Mac's audio output.
///
/// Never touches the engine's input. Doing so would ask for the microphone, and it would drop AirPods into their
/// lower-quality call mode.
///
/// It leaves the output's block size to macOS. Asking for smaller blocks made it fight the preview player, which shares
/// the output, until the engine stopped for good.
nonisolated final class SamplerEngine: @unchecked Sendable {
    let mixer = SamplerMixer()

    /// Opening the Mac's audio output can take a long time, or longer. All of it happens here, off the main thread,
    /// so that the window keeps working however long the output takes to answer.
    private let queue = DispatchQueue(label: "Sampler Engine")
    private let engine = AVAudioEngine()
    private var connectedNodes: [AVAudioNode] = []
    private var plugins: [AVAudioUnit] = []
    private var slotPlugins: [Int: [AVAudioUnit]] = [:]
    private var isWanted = false
    private var isConnected = false
    private var master = SamplerMaster()
    private var masterEQ: AVAudioUnitEQ?
    private var meteredNode: AVAudioNode?
    private let masterPeak: UnsafeMutablePointer<Float> = {
        let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        peak.initialize(to: 0)
        return peak
    }()
    private var configurationObserver: NSObjectProtocol?
    private var isRecoveryScheduled = false

    /// The output's rate, or 0 until it's open.
    private(set) var outputRate = 0.0
    /// The most the output may ask for at once. The mixer can make up to 8192.
    private static let largestBlock: AUAudioFrameCount = 4096

    init() {
        // Plugging in headphones or choosing another output stops the engine, and the new output may run at another rate.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRecovery()
        }
    }

    /// Changes often come several at once, so they're answered together a moment later.
    private func scheduleRecovery() {
        queue.async {
            guard self.isWanted, !self.isRecoveryScheduled else { return }
            self.isRecoveryScheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.15) {
                self.isRecoveryScheduled = false
                if self.isWanted { self.recover() }
            }
        }
    }

    /// A change can arrive without any notice, and then nothing would start the engine again. So while the sampler is
    /// open, this looks once a second.
    private func keepWatching() {
        queue.asyncAfter(deadline: .now() + 1) {
            guard self.isWanted else { return }
            if !self.engine.isRunning, !self.isRecoveryScheduled { self.recover() }
            self.keepWatching()
        }
    }

    /// Other audio in the app, like the preview player, can change the output's settings, which stops the engine.
    /// If the output still runs at the same rate, starting again is enough. Rebuilding everything would cut off what's
    /// playing, and would make the output change again, round and round.
    private func recover() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if isConnected, rate == outputRate, rate > 0 {
            engine.prepare()
            if (try? engine.start()) != nil { return }
        }
        _ = reconnect()
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    func setMaster(_ master: SamplerMaster) {
        queue.async {
            self.master = master
            if let eq = self.masterEQ {
                SamplerGraph.configure(eq, for: master)
            }
        }
    }

    /// The loudest point leaving the sampler lately, plug-ins and all.
    var masterLevel: Float {
        masterPeak.pointee
    }

    /// Rebuilds the chain, which stops any sound for a moment.
    func setPlugins(_ plugins: [AVAudioUnit], slotPlugins: [Int: [AVAudioUnit]]) {
        let list = PluginList(everything: plugins, slots: slotPlugins)
        queue.async {
            self.plugins = list.everything
            self.slotPlugins = list.slots
            if self.isWanted { _ = self.reconnect() }
        }
    }

    /// `completion` says whether sound can now be heard. It runs on a background thread.
    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            let wasWanted = self.isWanted
            self.isWanted = true
            completion(self.reconnect())
            if !wasWanted { self.keepWatching() }
        }
    }

    func stop() {
        queue.async {
            self.isWanted = false
            self.engine.stop()
            self.mixer.resetWhileNotRendering()
            self.mixer.stopTransportWhileNotRendering()
        }
    }

    /// Only ever read on `queue`, once handed over.
    private struct PluginList: @unchecked Sendable {
        let everything: [AVAudioUnit]
        let slots: [Int: [AVAudioUnit]]
    }

    private func reconnect() -> Bool {
        engine.stop()
        mixer.resetWhileNotRendering()
        meteredNode?.removeTap(onBus: 0)
        meteredNode = nil
        connectedNodes.forEach(engine.detach)
        connectedNodes = []
        masterEQ = nil
        isConnected = false

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return false }
        outputRate = rate
        mixer.setOutputRate(rate)

        let built = SamplerGraph.build(in: engine, mixer: mixer, format: format, master: master, plugins: plugins, slotPlugins: slotPlugins)
        connectedNodes = built.nodes
        masterEQ = built.masterEQ

        // Listens without touching the sound. It runs well away from the real-time thread.
        let peak = masterPeak
        built.last.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            var loudest: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(buffer.frameLength))
                loudest = max(loudest, channelPeak)
            }
            peak.pointee = loudest
        }
        meteredNode = built.last

        if let unit = engine.outputNode.audioUnit {
            var largest = UInt32(Self.largestBlock)
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &largest, UInt32(MemoryLayout<UInt32>.size))
        }
        // The output can be asked for bigger blocks at any moment, for example when the preview player starts. Every
        // part has to be ready for the biggest, or it fails and goes silent.
        for node in connectedNodes + [engine.mainMixerNode] where !node.auAudioUnit.renderResourcesAllocated {
            node.auAudioUnit.maximumFramesToRender = Self.largestBlock
        }

        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        isConnected = (try? engine.start()) != nil
        return isConnected
    }
}
