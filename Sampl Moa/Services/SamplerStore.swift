import AVFoundation
import AppKit
import Foundation
import Observation

/// What a pad shows. Kept apart from the rest of the sampler so that a hit only redraws the pad that was hit.
@Observable
final class SamplerPadState {
    enum Status {
        case empty, downloading, loading, ready, unavailable
    }

    fileprivate(set) var status = Status.empty
    /// True while a new version of a sound that can already be played is being prepared.
    fileprivate(set) var isWorking = false
    /// Goes up with every hit, for the pad to flash.
    fileprivate(set) var hits = 0
    /// The outline of the part that plays.
    fileprivate(set) var peaks: [Float] = []
    /// How far through that part the sound has got, from 0 to 1, or nil when it's silent.
    fileprivate(set) var progress: Double?
    /// How loud each side is right now, for its meters.
    fileprivate(set) var level = SamplerLevel.silent
    /// The loudest it has been since this sound was put on or the reading was reset, shown above its fader.
    fileprivate(set) var loudest: Float = 0
}

/// The sampler's sounds and settings, and everything that keeps them in step with the audio engine and MIDI devices.
@Observable
final class SamplerStore {
    enum ChopStyle: Hashable {
        case equalParts(Int)
        case atHits
    }

    /// Slices being marked out on the waveform, before they go on the pads.
    struct ChopSession: Equatable {
        let slot: Int
        var style = ChopStyle.atHits
        /// From 0 to 1. Higher finds quieter and more hits.
        var sensitivity = 0.5
        /// Where each slice starts, as fractions of the whole file.
        var markers: [Double] = []
    }

    /// Where an export's files went.
    struct ExportResult: Equatable {
        let files: [URL]
    }

    enum Learning: Equatable {
        case pad(Int)
        case knob(SamplerKnob)
    }

    /// A sound loaded and ready, and which of its frames to play.
    private struct Playable {
        let audio: SamplerAudio
        let startFrame: Int
        let endFrame: Int
    }

    private struct PeaksRequest: Hashable {
        let path: String
        let start: Double
        let end: Double
        let count: Int
    }

    /// How long the sampler stays quiet before its audio output rests. In front, the next hit should sound at once, so
    /// it waits a good while. Behind other apps nothing can play it, since devices are only heard in front, so it rests
    /// almost straight away.
    private static let quietBeforeRestingInFront: Duration = .seconds(45)
    private static let quietBeforeRestingBehind: Duration = .seconds(2)
    private static let isOpenKey = "samplerIsOpen"
    private static let playsFromComputerKeyboardKey = "samplerPlaysFromComputerKeyboard"
    private static let lowestComputerKeyboardOctave = -3
    private static let highestComputerKeyboardOctave = 3
    private static let hasSeenGuideKey = "hasSeenSamplerGuideWithPermissions"
    private static let onScreenVelocity = 110
    private static let shortestRegion: TimeInterval = 0.01
    /// Sounds at least this long stay in time across a chord, unless someone chooses otherwise.
    private static let shortestLengthToKeep: TimeInterval = 2
    private static let padPeakCount = 44
    private static let semitonesPreparedOnEachSide = 24
    /// How much memory the keys of one sound may take up. Any further keys simply change speed with their pitch.
    private static let memoryForKeyboardNotes = 400_000_000

    private(set) var slots = SamplerKit().slots
    let padStates = (0..<SamplerSlot.count).map { _ in SamplerPadState() }
    /// A pad, or `SamplerSlot.keyboardIndex`.
    var selectedSlot = 0
    private(set) var devices: [String] = []
    private(set) var learning: Learning?
    private(set) var canUndoChop = false
    /// True when the Mac's audio output has been slow to answer, or won't, so that silence has an explanation.
    private(set) var isWaitingForAudio = false
    private(set) var couldNotOpenAudio = false
    private(set) var isPreparingKeys = false
    var showsGuide = false
    private(set) var chopSession: ChopSession?
    /// A connected device whose pads and knobs haven't been taught yet.
    private(set) var unfamiliarDevice: String?
    private(set) var isExporting = false
    private(set) var exportResult: ExportResult?
    private(set) var exportFailed = false
    /// Goes up when a slot's part of its file is replaced rather than edited, so the waveform starts afresh.
    private(set) var editorGeneration = 0
    private var fileDurations = [TimeInterval?](repeating: nil, count: SamplerSlot.count)

    var isOpen = UserDefaults.standard.bool(forKey: isOpenKey) {
        didSet {
            guard isOpen != oldValue else { return }
            UserDefaults.standard.set(isOpen, forKey: Self.isOpenKey)
            applyIsOpen()
        }
    }

    /// Whether the Mac's own keyboard plays the pads and keys, for when there's no device to hand. Remembered, since
    /// someone without a device will want it every time.
    var playsFromComputerKeyboard = UserDefaults.standard.bool(forKey: playsFromComputerKeyboardKey) {
        didSet {
            guard playsFromComputerKeyboard != oldValue else { return }
            UserDefaults.standard.set(playsFromComputerKeyboard, forKey: Self.playsFromComputerKeyboardKey)
            if !playsFromComputerKeyboard { releaseComputerKeys() }
        }
    }
    /// How many octaves up or down from middle C the Mac's keyboard plays the keys.
    private(set) var computerKeyboardOctave = 0
    /// What each key held down on the Mac's keyboard started, so letting go stops that even if the octave has changed.
    @ObservationIgnored private var heldComputerKeys: [UInt16: (slot: Int, note: Int?)] = [:]

    /// What everything passes through on its way out.
    private(set) var master = SamplerMaster()
    /// Which strip a device's knobs turn: the selected sound's, or the master's.
    var knobsTurnMaster = false
    /// How loud each side of the master is right now, for its meters.
    private(set) var masterLevel = SamplerLevel.silent
    /// The loudest the master has been since its reading was reset.
    private(set) var masterLoudest: Float = 0

    @ObservationIgnored private var padBindings = SamplerKit().padBindings
    @ObservationIgnored private var knobControllers = SamplerKit.standardKnobControllers
    /// Waits until the sampler is first opened, so that nobody who doesn't use it pays for it at launch.
    @ObservationIgnored private lazy var engine = SamplerEngine()
    @ObservationIgnored private var audioWaitTask: Task<Void, Never>?
    @ObservationIgnored private var midi: MIDIInput?
    @ObservationIgnored private var hasLoadedKit = false
    @ObservationIgnored private var decoded: [URL: Task<SamplerAudio, Error>] = [:]
    @ObservationIgnored private var playables = [Playable?](repeating: nil, count: SamplerSlot.count)
    @ObservationIgnored private var loadedPaths = [String?](repeating: nil, count: SamplerSlot.count)
    @ObservationIgnored private var loadTasks = [Task<Void, Never>?](repeating: nil, count: SamplerSlot.count)
    @ObservationIgnored private var settleTasks = [Task<Void, Never>?](repeating: nil, count: SamplerSlot.count)
    /// Sounds that should have their pitch worked out once they've loaded.
    @ObservationIgnored private var slotsNeedingRoot: Set<Int> = []
    @ObservationIgnored private var keyboardNotes: [Int: SamplerAudio] = [:]
    @ObservationIgnored private var keyboardNotesTask: Task<Void, Never>?
    @ObservationIgnored private var slotsBeforeChop: [SamplerSlot]?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var playheadTask: Task<Void, Never>?
    @ObservationIgnored private var restTask: Task<Void, Never>?
    /// What the library knows about a file's tempo. Nil if the library doesn't have the file, and `.some(nil)` if it
    /// does but the sample has no tempo, like a one-shot.
    @ObservationIgnored var libraryTempo: (URL) -> Double?? = { _ in nil }
    @ObservationIgnored private var lastFollowedTempo: Double?
    @ObservationIgnored private var peaksCache: [PeaksRequest: [Float]] = [:]
    @ObservationIgnored private var knobRemainders = [Double](repeating: 0, count: SamplerKnob.allCases.count)
    @ObservationIgnored private var deviceProfiles: [String: SamplerDeviceProfile] = [:]
    @ObservationIgnored private var lastTriggerCounts = [Int](repeating: 0, count: SamplerSlot.count)
    @ObservationIgnored private var chopSearchTask: Task<Void, Never>?
    @ObservationIgnored private var lastLearnedController: Int?
    @ObservationIgnored private var activityObservers: [NSObjectProtocol] = []

    /// Plug-ins on a pad, or on everything.
    @ObservationIgnored private(set) lazy var effects: SamplerEffects = {
        let effects = SamplerEffects(engine: engine) { [weak self] in
            self?.saveSoon()
        }
        effects.tempo = { [weak self] in self?.sequencer.pattern.bpm ?? 120 }
        return effects
    }()

    @ObservationIgnored private(set) lazy var sequencer = SamplerSequencer(mixer: engine.mixer) { [weak self] in
        self?.saveSoon()
        self?.followTempoChange()
    }

    @ObservationIgnored private lazy var router = SamplerRouter(
        mixer: engine.mixer,
        onHit: { [weak self] slot in
            guard let self else { return }
            Self.onMain { self.soundStarted(in: slot) }
        },
        onKnob: { [weak self] knob, from, to in
            guard let self else { return }
            Self.onMain {
                // A hand on the device's knobs is about to play, so the output gets ready.
                self.wakeAudio()
                self.turnKnob(knob, from: from, to: to)
            }
        },
        onLearnPad: { [weak self] binding in
            guard let self else { return }
            Self.onMain { self.learnPad(binding) }
        },
        onLearnKnob: { [weak self] controller in
            guard let self else { return }
            Self.onMain { self.learnKnob(controller) }
        }
    )

    init() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            activityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyListening()
                    // Coming to the front wakes the output before anything is hit. Going behind lets it rest soon.
                    if NSApplication.shared.isActive { self.wakeAudio() } else { self.restWhenQuiet() }
                }
            })
        }
        // Left for later, because the app isn't running yet when this is first created.
        if isOpen {
            Task { self.applyIsOpen() }
        }
    }

    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }

    func slot(_ index: Int) -> SamplerSlot {
        slots[index]
    }

    private func applyIsOpen() {
        if isOpen {
            loadKitIfNeeded()
            startMIDIIfNeeded()
            startAudio()
            if !UserDefaults.standard.bool(forKey: Self.hasSeenGuideKey) { showsGuide = true }
        } else {
            finishLearning()
            cancelChop()
            audioWaitTask?.cancel()
            isWaitingForAudio = false
            restTask?.cancel()
            sequencer.stop()
            engine.stop()
        }
        applyListening()
    }

    // MARK: - Resting the audio output

    /// Makes sure the output is running, starting it again if it was resting. That takes about 40 ms, so anything
    /// that's about to play calls this as early as it can: coming to the front, the pointer reaching the sampler, a
    /// device's knob turning. A hit from a device arrives as it is, and is heard once the output is back.
    func wakeAudio() {
        guard isOpen else { return }
        engine.wake()
        restWhenQuiet()
    }

    /// Lets the output rest once the sampler has been quiet for a while, since a running output costs battery even
    /// in silence. Anything still ringing, like a reverb's tail on the master, gets to finish first.
    private func restWhenQuiet() {
        restTask?.cancel()
        guard isOpen else { return }
        let wait = NSApplication.shared.isActive ? Self.quietBeforeRestingInFront : Self.quietBeforeRestingBehind
        restTask = Task {
            try? await Task.sleep(for: wait)
            while !Task.isCancelled, isMakingSound {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            engine.sleep()
        }
    }

    private var isMakingSound: Bool {
        playheadTask != nil || sequencer.isPlaying || sequencer.isRecording || engine.masterLevel > 0.0001
    }

    func guideWasClosed() {
        showsGuide = false
        UserDefaults.standard.set(true, forKey: Self.hasSeenGuideKey)
    }

    private func startAudio() {
        couldNotOpenAudio = false
        engine.setMaster(master)

        // A short wait is normal, so the message only appears if this drags on.
        audioWaitTask?.cancel()
        audioWaitTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { isWaitingForAudio = true }
        }

        engine.start { [weak self] didOpen in
            guard let self else { return }
            Self.onMain {
                self.audioWaitTask?.cancel()
                self.isWaitingForAudio = false
                self.couldNotOpenAudio = !didOpen
                self.restWhenQuiet()
            }
        }
    }

    /// Other apps get the same MIDI messages, so the sampler only answers while it's in front. Otherwise playing a
    /// device in Logic Pro would also play everything here.
    private func applyListening() {
        guard midi != nil else { return }
        router.setEnabled(isOpen && NSApplication.shared.isActive)
    }

    private func startMIDIIfNeeded() {
        guard midi == nil else { return }
        router.setPadBindings(padBindings)
        router.setKnobControllers(knobControllers)

        let router = router
        midi = MIDIInput(
            onEvent: { router.handle($0) },
            onDevicesChanged: { [weak self] names in
                guard let self else { return }
                Self.onMain { self.devicesChanged(to: names) }
            }
        )
    }

    // MARK: - Choosing sounds

    /// Several samples fill consecutive pads. The keyboard only has room for one.
    func assign(_ urls: [URL], toSlot first: Int) {
        let targets: [Int] = first == SamplerSlot.keyboardIndex ? [first] : Array(first..<SamplerSlot.padCount)
        for (index, url) in zip(targets, urls) {
            var slot = SamplerSlot()
            slot.path = url.path
            slot.sourceBPM = tempo(of: url)
            if index == SamplerSlot.keyboardIndex {
                slot.mode = .hold
                slotsNeedingRoot.insert(index)
            }
            slots[index] = slot
            reload(index)
        }
        selectedSlot = first
        canUndoChop = false
        editorGeneration += 1
        forgetUnusedFiles()
        saveSoon()
    }

    func clear(_ index: Int) {
        slots[index] = SamplerSlot()
        reload(index)
        forgetUnusedFiles()
        saveSoon()
    }

    /// Keeps the part of the sound that's been chosen, and works out which note it is.
    func copyToKeyboard(_ index: Int) {
        var slot = slots[index]
        slot.cutGroup = 0
        slot.mode = slot.mode == .oneShot ? .hold : slot.mode
        slots[SamplerSlot.keyboardIndex] = slot
        slotsNeedingRoot.insert(SamplerSlot.keyboardIndex)
        reload(SamplerSlot.keyboardIndex)
        selectedSlot = SamplerSlot.keyboardIndex
        editorGeneration += 1
        saveSoon()
    }

    // MARK: - Editing the selected sound

    /// `isFinished` is false while a handle is being dragged.
    func setRegion(start: Double, end: Double, of index: Int, isFinished: Bool) {
        slots[index].start = start
        slots[index].end = end
        if slots[index].speed == 1 {
            refreshFramesOfUnstretchedSound(index)
        }
        if isFinished {
            if slots[index].speed != 1 || index == SamplerSlot.keyboardIndex {
                reload(index)
            } else {
                refreshPadPeaks(index)
            }
            saveSoon()
        }
    }

    // MARK: - Tempo

    /// From the library if it has the file, which knows Splice's tempos, and otherwise from the file's name.
    private func tempo(of url: URL) -> Double? {
        if let known = libraryTempo(url) { return known }
        return SampleTempo.bpm(inName: url.deletingPathExtension().lastPathComponent)
    }

    /// The library has looked through its folders. Sounds put on pads before it knew their tempos get them now. A
    /// tempo already there, found or typed in, stays.
    func libraryDidScan() {
        var changed = false
        for index in slots.indices where slots[index].sourceBPM == nil {
            guard let url = slots[index].url, let bpm = tempo(of: url) else { continue }
            slots[index].sourceBPM = bpm
            changed = true
        }
        if changed { saveSoon() }
    }

    /// Typed in, for a sound whose tempo wasn't known or was wrong. A loop that's twice as fast as it sounds can be
    /// given double its tempo to play in half time.
    func setSampleTempo(_ bpm: Double?, of index: Int) {
        let tempo = bpm.map { min(max($0, 30), 300) }
        guard slots[index].sourceBPM != tempo else { return }
        slots[index].sourceBPM = tempo
        if tempo == nil { slots[index].followsTempo = false }
        matchTempo(index)
        saveSoon()
    }

    /// Changes the sound's speed, not its pitch, so it plays at the sampler's tempo, and keeps doing so as the tempo
    /// changes.
    func setFollowsTempo(_ follows: Bool, of index: Int) {
        slots[index].followsTempo = follows && slots[index].sourceBPM != nil
        matchTempo(index)
        saveSoon()
    }

    private func matchTempo(_ index: Int) {
        guard slots[index].followsTempo, slots[index].path != nil, let source = slots[index].sourceBPM else { return }
        let speed = SampleTempo.speed(from: source, to: sequencer.pattern.bpm)
        guard abs(slots[index].speed - speed) > 0.0001 else { return }
        slots[index].speed = speed
        // Stretching takes a moment, so it waits for the tempo to stop changing. The last version plays meanwhile.
        settleSoon(index)
    }

    private func followTempoChange() {
        let tempo = sequencer.pattern.bpm
        guard tempo != lastFollowedTempo else { return }
        lastFollowedTempo = tempo
        for index in slots.indices where slots[index].followsTempo {
            matchTempo(index)
        }
    }

    /// Starts the loudest reading over, for a pad or the keyboard, or for the master when there's no slot.
    func resetLoudest(of slot: Int?) {
        if let slot { padStates[slot].loudest = 0 } else { masterLoudest = 0 }
    }

    func setMasterKnob(_ knob: SamplerKnob, toPosition position: Double) {
        let before = master
        master.set(knob, toPosition: position)
        guard master != before else { return }
        engine.setMaster(master)
        saveSoon()
    }

    func setKnob(_ knob: SamplerKnob, toPosition position: Double, of index: Int) {
        guard slots[index].path != nil else { return }
        let before = slots[index]
        // Turning Speed by hand takes over from following the tempo.
        if knob == .speed { slots[index].followsTempo = false }
        slots[index].set(knob, toPosition: position)
        guard slots[index] != before else { return }

        switch knob {
        case .speed:
            // Stretching takes a moment, so it waits for the knob to stop. The last version plays until it's ready.
            settleSoon(index)
        case .pitch where index == SamplerSlot.keyboardIndex && slots[index].keepsLength:
            sendToMixer(index)
            settleSoon(index)
        default:
            sendToMixer(index)
        }
        saveSoon()
    }

    /// A knob on a device sends a value from 0 to 127 and stops there, wherever the setting on screen happens to be.
    /// So a turn covers whatever's left of the setting in that direction, in proportion to what's left of the knob.
    /// A setting in the middle reaches its lowest as the device reaches 0, and its highest as it reaches 127. Nothing
    /// jumps when switching pads, and the two can't get stuck out of step.
    private func turnKnob(_ knob: SamplerKnob, from: Int, to: Int) {
        guard from != to else { return }
        let index = selectedSlot
        let turnsMaster = knobsTurnMaster && knob.appliesToMaster
        guard turnsMaster || slots[index].path != nil else { return }

        let start = turnsMaster ? (master.position(of: knob) ?? 0) : slots[index].position(of: knob)
        let current = start + knobRemainders[knob.rawValue]
        let wanted: Double
        if to > from {
            wanted = current + (1 - current) * Double(to - from) / Double(127 - from)
        } else {
            wanted = current - current * Double(from - to) / Double(from)
        }
        let position = min(max(wanted, 0), 1)
        if turnsMaster {
            setMasterKnob(knob, toPosition: position)
        } else {
            setKnob(knob, toPosition: position, of: index)
        }

        // A small turn may not be enough to change a setting that moves in steps, so it's remembered for the next.
        let leftOver = position - (turnsMaster ? (master.position(of: knob) ?? position) : slots[index].position(of: knob))
        knobRemainders[knob.rawValue] = abs(leftOver) < 0.05 ? leftOver : 0
    }

    private func settleSoon(_ index: Int) {
        settleTasks[index]?.cancel()
        settleTasks[index] = Task {
            try? await Task.sleep(for: .seconds(0.3))
            if !Task.isCancelled { reload(index) }
        }
    }

    func setMode(_ mode: SamplerPlayMode, of index: Int) {
        slots[index].mode = mode
        sendToMixer(index)
        saveSoon()
    }

    func setCutGroup(_ group: Int, of index: Int) {
        slots[index].cutGroup = group
        sendToMixer(index)
        saveSoon()
    }

    func setRootNote(_ note: Int, of index: Int) {
        slots[index].rootNote = note
        // Whatever was measured belonged to the note it was measured against.
        slots[index].fineTune = 0
        sendToMixer(index)
        if index == SamplerSlot.keyboardIndex { prepareKeyboardNotes() }
        saveSoon()
    }

    func setKeepsLength(_ keepsLength: Bool) {
        slots[SamplerSlot.keyboardIndex].keepsLength = keepsLength
        prepareKeyboardNotes()
        saveSoon()
    }

    /// The shortest a sound is allowed to be cut down to, as a fraction of its file.
    func shortestRegion(of index: Int) -> Double {
        guard let duration = fileDurations[index], duration > 0 else { return 0.001 }
        return min(0.5, Self.shortestRegion / duration)
    }

    /// Stops the recorder and silences every sound at once, for when something keeps ringing.
    func stopEverything() {
        sequencer.stop()
        engine.mixer.stopAll()
    }

    // MARK: - Chopping

    /// Marks out slices on the waveform, to be adjusted before they go on the pads.
    func beginChop(_ index: Int) {
        chopSession = ChopSession(slot: index)
        findChopMarkers()
    }

    func cancelChop() {
        chopSearchTask?.cancel()
        chopSession = nil
    }

    func setChopStyle(_ style: ChopStyle) {
        chopSession?.style = style
        findChopMarkers()
    }

    func setChopSensitivity(_ sensitivity: Double) {
        chopSession?.sensitivity = sensitivity
        findChopMarkers()
    }

    private func findChopMarkers() {
        guard let session = chopSession, let url = slots[session.slot].url else { return }
        chopSearchTask?.cancel()
        chopSearchTask = Task {
            guard let audio = try? await audio(for: url), !Task.isCancelled else { return }
            let source = slots[session.slot]
            let total = Double(audio.frameCount)
            let start = Int(source.start * total)
            let end = Int(source.end * total)

            let starts: [Int]
            switch session.style {
            case .equalParts(let count):
                starts = (0..<count).map { start + (end - start) * $0 / count }
            case .atHits:
                // From very picky at the bottom of the slider to very eager at the top.
                let threshold = Float(1.1 - session.sensitivity)
                let found = await Self.findHits(in: audio, from: start, to: end, threshold: threshold)
                // A sound with no clear hits, like a pad or a vocal, still gets cut somewhere useful.
                starts = found.count > 1 ? found : (0..<8).map { start + (end - start) * $0 / 8 }
            }
            guard !Task.isCancelled else { return }
            chopSession?.markers = starts.map { Double($0) / total }
        }
    }

    /// Returns which marker it became, to carry on dragging.
    func moveChopMarker(_ index: Int, to fraction: Double) -> Int {
        guard var session = chopSession, session.markers.indices.contains(index) else { return index }
        // The first marker is the start of the chosen part. It's moved with the handle, not here.
        guard index > 0 else { return index }
        let source = slots[session.slot]
        session.markers[index] = min(max(fraction, source.start + 0.0001), source.end - 0.0001)
        let moved = session.markers[index]
        session.markers.sort()
        chopSession = session
        return session.markers.firstIndex(of: moved) ?? index
    }

    func toggleChopMarker(at fraction: Double, within tolerance: Double) {
        guard var session = chopSession else { return }
        if let near = session.markers.indices.dropFirst().first(where: { abs(session.markers[$0] - fraction) < tolerance }) {
            session.markers.remove(at: near)
        } else if session.markers.count < SamplerSlot.padCount {
            session.markers.append(fraction)
            session.markers.sort()
        }
        chopSession = session
    }

    /// Plays the slice under a click, using a hidden slot so that no pad is disturbed.
    func auditionChopSlice(at fraction: Double) {
        guard let session = chopSession, let url = slots[session.slot].url else { return }
        let source = slots[session.slot]
        let starts = session.markers
        guard let index = starts.lastIndex(where: { $0 <= fraction }) else { return }
        let end = index + 1 < starts.count ? starts[index + 1] : source.end

        Task {
            guard let audio = try? await audio(for: url) else { return }
            let total = Double(audio.frameCount)
            engine.mixer.setSlot(SamplerMixer.auditionSlot, to: SamplerMixer.Slot(
                left: audio.left,
                right: audio.right,
                frameCount: audio.frameCount,
                startFrame: Int(starts[index] * total),
                endFrame: Int(end * total),
                sampleRate: audio.sampleRate,
                rootNote: SamplerNote.middleC,
                mode: .oneShot,
                cutGroup: 0
            ))
            wakeAudio()
            engine.mixer.noteOn(slot: SamplerMixer.auditionSlot, velocity: Self.onScreenVelocity)
        }
    }

    /// Puts one slice on each pad, starting from this pad if there's room for them all.
    func applyChop() {
        guard let session = chopSession, !session.markers.isEmpty else { return }
        let index = session.slot
        let source = slots[index]
        let starts = session.markers
        let isPad = index < SamplerSlot.padCount
        let first = isPad && index + starts.count <= SamplerSlot.padCount ? index : 0

        chopSession = nil
        slotsBeforeChop = slots
        canUndoChop = true

        for (offset, sliceStart) in starts.prefix(SamplerSlot.padCount).enumerated() where first + offset < SamplerSlot.padCount {
            var slice = source
            slice.start = sliceStart
            slice.end = offset + 1 < starts.count ? starts[offset + 1] : source.end
            // Slices of one recording usually sound wrong on top of each other, so each hit cuts off the last.
            slice.cutGroup = max(source.cutGroup, 1)
            slice.mode = source.mode == .loop ? .oneShot : source.mode
            slots[first + offset] = slice
            reload(first + offset)
        }
        selectedSlot = first
        editorGeneration += 1
        forgetUnusedFiles()
        saveSoon()
    }

    func undoChop() {
        guard let slotsBeforeChop else { return }
        let changed = slots.indices.filter { slots[$0] != slotsBeforeChop[$0] }
        slots = slotsBeforeChop
        changed.forEach(reload)
        self.slotsBeforeChop = nil
        canUndoChop = false
        editorGeneration += 1
        forgetUnusedFiles()
        saveSoon()
    }

    @concurrent nonisolated private static func findHits(in audio: SamplerAudio, from start: Int, to end: Int, threshold: Float) async -> [Int] {
        SampleAnalysis.hits(in: audio, from: start, to: end, limit: SamplerSlot.padCount, threshold: threshold)
    }

    // MARK: - Playing

    /// The keyboard's sound plays `note`, or its root note if there's none.
    func press(_ index: Int, note: Int? = nil) {
        selectedSlot = index
        if engine.mixer.noteOn(slot: index, velocity: Self.onScreenVelocity, note: self.note(note, for: index)) {
            soundStarted(in: index)
        }
    }

    func release(_ index: Int, note: Int? = nil) {
        engine.mixer.noteOff(slot: index, note: self.note(note, for: index))
    }

    private func note(_ note: Int?, for index: Int) -> Int? {
        index == SamplerSlot.keyboardIndex ? note ?? slots[index].rootNote : nil
    }

    // MARK: - Playing from the Mac's keyboard

    func computerKeyDown(_ key: UInt16, slot: Int, note: Int?) {
        if let held = heldComputerKeys[key] { release(held.slot, note: held.note) }
        heldComputerKeys[key] = (slot, note)
        press(slot, note: note)
    }

    /// Whether the key was playing something.
    func computerKeyUp(_ key: UInt16) -> Bool {
        guard let held = heldComputerKeys.removeValue(forKey: key) else { return false }
        release(held.slot, note: held.note)
        return true
    }

    /// For when the keys being held can no longer be heard letting go, such as when another app comes to the front.
    func releaseComputerKeys() {
        for held in heldComputerKeys.values { release(held.slot, note: held.note) }
        heldComputerKeys = [:]
    }

    func shiftComputerKeyboardOctave(by octaves: Int) {
        computerKeyboardOctave = min(
            max(computerKeyboardOctave + octaves, Self.lowestComputerKeyboardOctave),
            Self.highestComputerKeyboardOctave
        )
    }

    /// The note the Mac's keyboard plays for a key so many semitones above its C.
    func computerKeyboardNote(semitone: Int) -> Int {
        SamplerNote.middleC + 12 * computerKeyboardOctave + semitone
    }

    /// Whatever was just played opens in the editor, so what's on screen is always the sound being heard.
    private func soundStarted(in index: Int) {
        padStates[index].hits += 1
        if learning == nil { selectedSlot = index }
        startFollowingPlayheads()
    }

    /// Runs only while something is sounding or the recorder is going, so a quiet sampler costs nothing. Everything
    /// that starts a sound or the recorder comes through here, so this is also what wakes a resting output.
    func startFollowingPlayheads() {
        wakeAudio()
        guard playheadTask == nil else { return }
        playheadTask = Task {
            var quietTicks = 0
            while quietTicks < 8 {
                try? await Task.sleep(for: .seconds(1.0 / 30))
                sequencer.tick()

                var isAnythingPlaying = sequencer.isPlaying
                for index in 0..<SamplerSlot.count {
                    let head = engine.mixer.playhead(of: index)
                    let progress = head >= 0 ? head : nil
                    if padStates[index].progress != progress { padStates[index].progress = progress }
                    if progress != nil { isAnythingPlaying = true }

                    // Pads flash along with a recording too.
                    let triggers = engine.mixer.triggerCount(of: index)
                    if triggers != lastTriggerCounts[index] {
                        if sequencer.isPlaying { padStates[index].hits += 1 }
                        lastTriggerCounts[index] = triggers
                    }

                    // A pad with plug-ins is measured after them, so a reverb's or delay's tail shows too.
                    let dry = engine.mixer.takeLoudest(of: index)
                    let measured = engine.takeLoudestAfterPlugins(of: index) ?? dry
                    let shown = Self.meterReading(measured, after: padStates[index].level)
                    if shown != padStates[index].level { padStates[index].level = shown }
                    if measured.loudest > padStates[index].loudest { padStates[index].loudest = measured.loudest }
                    if measured.loudest > Self.stillHeard { isAnythingPlaying = true }
                }
                let measuredMaster = engine.takeMasterLoudest()
                let master = Self.meterReading(measuredMaster, after: masterLevel)
                if master != masterLevel { masterLevel = master }
                if measuredMaster.loudest > masterLoudest { masterLoudest = measuredMaster.loudest }
                // Tails ring on after the sounds that made them have stopped, and the meters follow them down.
                if measuredMaster.loudest > Self.stillHeard { isAnythingPlaying = true }
                quietTicks = isAnythingPlaying ? 0 : quietTicks + 1
            }
            for index in 0..<SamplerSlot.count where padStates[index].level != .silent { padStates[index].level = .silent }
            masterLevel = .silent
            playheadTask = nil
            restWhenQuiet()
        }
    }

    /// About -66 dB, below which a tail has as good as finished.
    private static let stillHeard: Float = 0.0005

    /// Meters rise at once and fall back gently, the way they do on a desk, each side on its own. A rise too small to
    /// see keeps the old reading, so the meter isn't redrawn for nothing.
    private static func meterReading(_ measured: SamplerLevel, after shown: SamplerLevel) -> SamplerLevel {
        func side(_ measured: Float, _ shown: Float) -> Float {
            let level = max(measured, shown * 0.8)
            let next = level < 0.001 ? 0 : level
            return next < shown || next - shown > 0.002 ? next : shown
        }
        return SamplerLevel(left: side(measured.left, shown.left), right: side(measured.right, shown.right))
    }

    // MARK: - Teaching the sampler a device's controls

    /// Each pad on the screen lights up in turn, and whatever the device sends next plays it from then on.
    func startLearningPads() {
        learning = .pad(0)
        selectedSlot = 0
        router.setLearning(.pads)
    }

    func startLearningKnobs() {
        guard let first = SamplerKnob.allCases.first else { return }
        learning = .knob(first)
        lastLearnedController = nil
        router.setLearning(.knobs)
    }

    func finishLearning() {
        guard learning != nil else { return }
        learning = nil
        router.setLearning(.nothing)
        rememberCurrentLayout()
    }

    func useStandardDeviceLayout() {
        padBindings = SamplerKit().padBindings
        knobControllers = SamplerKit.standardKnobControllers
        rememberCurrentLayout()
    }

    /// Each device keeps its own layout, which comes back whenever it's plugged in.
    private func rememberCurrentLayout() {
        router.setPadBindings(padBindings)
        router.setKnobControllers(knobControllers)
        if let device = devices.first {
            deviceProfiles[device] = SamplerDeviceProfile(padBindings: padBindings, knobControllers: knobControllers)
        }
        unfamiliarDevice = nil
        saveSoon()
    }

    func dismissUnfamiliarDevice() {
        useStandardDeviceLayout()
    }

    private func devicesChanged(to names: [String]) {
        devices = names

        if let known = names.first(where: { deviceProfiles[$0] != nil }), let profile = deviceProfiles[known] {
            padBindings = profile.padBindings
            knobControllers = profile.knobControllers
            unfamiliarDevice = nil
        } else {
            padBindings = SamplerKit().padBindings
            knobControllers = SamplerKit.standardKnobControllers
            // MPK minis send what the standard layout expects, so they can go straight to playing.
            unfamiliarDevice = names.first { !$0.localizedCaseInsensitiveContains("MPK") }
        }
        router.setPadBindings(padBindings)
        router.setKnobControllers(knobControllers)
    }

    private func learnPad(_ binding: SamplerPadBinding) {
        guard case .pad(let pad) = learning else { return }

        // A pad taught something another pad already plays swaps with it, so no pad ends up with nothing.
        if let other = padBindings.firstIndex(of: binding) {
            padBindings[other] = padBindings[pad]
        }
        padBindings[pad] = binding
        padStates[pad].hits += 1

        let next = pad + 1
        if next < SamplerSlot.padCount {
            learning = .pad(next)
            selectedSlot = next
        } else {
            finishLearning()
        }
    }

    /// One turn sends many messages, so a knob only counts once. The next one to be heard is the next knob.
    private func learnKnob(_ controller: Int) {
        guard case .knob(let knob) = learning, controller != lastLearnedController else { return }

        if let other = knobControllers.firstIndex(of: controller) {
            knobControllers[other] = knobControllers[knob.rawValue]
        }
        knobControllers[knob.rawValue] = controller
        lastLearnedController = controller

        if let next = SamplerKnob(rawValue: knob.rawValue + 1) {
            learning = .knob(next)
        } else {
            finishLearning()
        }
    }

    // MARK: - Loading

    /// Loads a slot's sound and stretches it if need be. Any load already under way for that slot is abandoned.
    private func reload(_ index: Int) {
        loadTasks[index]?.cancel()
        settleTasks[index]?.cancel()
        let slot = slots[index]

        guard let url = slot.url else {
            padStates[index].status = .empty
            padStates[index].isWorking = false
            padStates[index].peaks = []
            padStates[index].loudest = 0
            fileDurations[index] = nil
            loadedPaths[index] = nil
            install(nil, in: index)
            if index == SamplerSlot.keyboardIndex { prepareKeyboardNotes() }
            return
        }

        // Editing a sound that can already be played shouldn't take it away while the new version is prepared.
        let hasSameFile = playables[index] != nil && padStates[index].status == .ready && loadedPaths[index] == slot.path
        if hasSameFile {
            padStates[index].isWorking = true
        } else {
            padStates[index].status = .loading
            padStates[index].loudest = 0
        }

        loadTasks[index] = Task {
            do {
                guard await waitUntilOnThisMac(url, slot: index) else { return }
                // A pad that's been cleared or given another sound in the meantime must keep what it now shows.
                try Task.checkCancellation()
                if !hasSameFile { padStates[index].status = .loading }

                let audio = try await audio(for: url)
                try Task.checkCancellation()
                fileDurations[index] = audio.duration

                let startFrame = Int(slot.start * Double(audio.frameCount))
                let endFrame = Int(slot.end * Double(audio.frameCount))

                if slotsNeedingRoot.remove(index) != nil {
                    if let root = await Self.findRoot(of: audio, url: url, from: startFrame, to: endFrame) {
                        slots[index].rootNote = root.note
                        slots[index].fineTune = root.fineTune
                    }
                    slots[index].keepsLength = Double(endFrame - startFrame) / audio.sampleRate >= Self.shortestLengthToKeep
                    try Task.checkCancellation()
                    saveSoon()
                }

                if slot.speed == 1 {
                    install(Playable(audio: audio, startFrame: startFrame, endFrame: endFrame), in: index)
                } else {
                    let stretched = try await audio.stretchedInBackground(from: startFrame, to: endFrame, speed: slot.speed)
                    try Task.checkCancellation()
                    install(Playable(audio: stretched, startFrame: 0, endFrame: stretched.frameCount), in: index)
                }
                loadedPaths[index] = slot.path
                padStates[index].status = .ready
                padStates[index].isWorking = false
                refreshPadPeaks(index)
                if index == SamplerSlot.keyboardIndex { prepareKeyboardNotes() }
            } catch is CancellationError {
                // Something newer took over this slot.
            } catch {
                install(nil, in: index)
                padStates[index].status = .unavailable
                padStates[index].isWorking = false
            }
        }
    }

    @concurrent nonisolated private static func findRoot(of audio: SamplerAudio, url: URL, from start: Int, to end: Int) async -> (note: Int, fineTune: Double)? {
        SampleAnalysis.root(of: audio, named: url.deletingPathExtension().lastPathComponent, from: start, to: end)
    }

    /// Reading a file that's only in the cloud would block until it had downloaded, so this waits for it first.
    /// Returns false if the download failed or the wait was called off.
    private func waitUntilOnThisMac(_ url: URL, slot index: Int) async -> Bool {
        guard !CloudFiles.isOnThisMac(url) else { return true }

        padStates[index].status = .downloading
        CloudFiles.requestDownload(of: url)
        while !CloudFiles.isOnThisMac(url) {
            if CloudFiles.downloadFailed(url) {
                install(nil, in: index)
                padStates[index].status = .unavailable
                return false
            }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return false }
        }
        return true
    }

    /// Slices of one file all share the same memory, so a chopped song only takes up the room of one song.
    private func audio(for url: URL) async throws -> SamplerAudio {
        if let existing = decoded[url] {
            return try await existing.value
        }
        let task = Task { try await SamplerAudio.loadInBackground(url) }
        decoded[url] = task
        return try await task.value
    }

    private func forgetUnusedFiles() {
        let used = Set(slots.compactMap(\.url))
        for url in decoded.keys where !used.contains(url) {
            decoded[url] = nil
        }
    }

    private func install(_ playable: Playable?, in index: Int) {
        let previous = playables[index]
        playables[index] = playable
        sendToMixer(index)

        guard let previous, !playables.contains(where: { $0?.audio === previous.audio }) else { return }
        retire(previous.audio)
    }

    /// Anything still sounding gets a moment to fade before its memory goes away.
    private func retire(_ audio: SamplerAudio) {
        engine.mixer.stopVoices(using: audio.left)
        Task {
            try? await Task.sleep(for: .seconds(3))
            _ = audio
        }
    }

    private func refreshFramesOfUnstretchedSound(_ index: Int) {
        guard let audio = playables[index]?.audio else { return }
        let total = Double(audio.frameCount)
        playables[index] = Playable(audio: audio, startFrame: Int(slots[index].start * total), endFrame: Int(slots[index].end * total))
        sendToMixer(index)
    }

    private func sendToMixer(_ index: Int) {
        engine.mixer.setSlot(index, to: mixerSlot(index))
    }

    private func mixerSlot(_ index: Int) -> SamplerMixer.Slot? {
        guard let playable = playables[index] else { return nil }
        let slot = slots[index]
        return SamplerMixer.Slot(
            left: playable.audio.left,
            right: playable.audio.right,
            frameCount: playable.audio.frameCount,
            startFrame: playable.startFrame,
            endFrame: playable.endFrame,
            sampleRate: playable.audio.sampleRate,
            rootNote: slot.rootNote,
            mode: slot.mode,
            cutGroup: slot.cutGroup,
            live: SamplerMixer.Live(
                volume: slot.volume,
                semitones: Double(slot.tune) - slot.fineTune / 100,
                filter: slot.filter,
                pan: slot.pan,
                eqLow: slot.eqLow,
                eqMid: slot.eqMid,
                eqHigh: slot.eqHigh
            )
        )
    }

    // MARK: - Exporting

    /// Exports go in the Music folder, where other apps can read them without asking and people can find them later.
    private static func newExportFolder() throws -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space).timeSeparator(.omitted))
        let folder = FolderAccess.userHome
            .appending(path: "Music/Sampl Moa")
            .appending(path: stamp.replacing(":", with: ""))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The whole pattern as one audio file, including delay, reverb, and all plug-ins.
    func exportMix() {
        export { folder in
            let url = folder.appending(path: "Beat.wav")
            try await self.bounce(to: url, onlySlot: nil)
            return [url]
        }
    }

    /// One audio file per pad, the same length, so they line up when dropped on a DAW's tracks. Plug-ins on the pads
    /// are included. Those on everything aren't, since the DAW can do that part from here.
    func exportStems() {
        export { folder in
            var files: [URL] = []
            for slot in self.sequencer.slotsWithNotes {
                let name = slot == SamplerSlot.keyboardIndex ? "Keyboard" : String(format: "Pad %02d", slot + 1)
                let url = folder.appending(path: "\(name).wav")
                try await self.bounce(to: url, onlySlot: slot)
                files.append(url)
            }
            return files
        }
    }

    /// The notes alone, to play with any instrument in a DAW.
    func exportMIDI() {
        let data = SamplerMIDIFile.data(for: sequencer.pattern)
        export { folder in
            let url = folder.appending(path: "Beat.mid")
            try data.write(to: url)
            return [url]
        }
    }

    private func export(_ work: @escaping (URL) async throws -> [URL]) {
        guard !isExporting else { return }
        isExporting = true
        exportFailed = false
        exportResult = nil
        Task {
            defer { isExporting = false }
            do {
                let files = try await work(try Self.newExportFolder())
                exportResult = ExportResult(files: files)
            } catch {
                exportFailed = true
            }
        }
    }

    private func bounce(to url: URL, onlySlot: Int?) async throws {
        var mixerSlots: [Int: SamplerMixer.Slot] = [:]
        for index in 0..<SamplerSlot.count {
            if let slot = mixerSlot(index) { mixerSlots[index] = slot }
        }
        var noteSounds: [Int: SamplerMixer.NoteSound] = [:]
        for (note, audio) in keyboardNotes {
            noteSounds[note] = SamplerMixer.NoteSound(left: audio.left, right: audio.right, frameCount: audio.frameCount, sampleRate: audio.sampleRate)
        }

        var slotPlugins: [Int: [AVAudioUnit]] = [:]
        for slot in (onlySlot.map { [$0] } ?? sequencer.slotsWithNotes) {
            let copies = await effects.copies(for: slot)
            if !copies.isEmpty { slotPlugins[slot] = copies }
        }
        let everything = onlySlot == nil ? await effects.copies(for: nil) : []

        let rate = engine.outputRate > 0 ? engine.outputRate : 48_000
        let keepAlive: [AnyObject] = playables.compactMap { $0?.audio } + Array(keyboardNotes.values)
        try await SamplerBouncer.render(SamplerBouncer.Job(
            slots: mixerSlots,
            noteSounds: noteSounds,
            events: sequencer.events(slot: onlySlot),
            seconds: sequencer.pattern.seconds,
            secondsPerBeat: sequencer.pattern.secondsPerBeat,
            sampleRate: rate,
            master: onlySlot == nil ? master : SamplerMaster(),
            plugins: everything,
            slotPlugins: slotPlugins,
            url: url,
            keepAlive: keepAlive
        ))
    }

    /// DAWs on this Mac that can be sent an export directly.
    var installedDAWs: [(name: String, url: URL)] {
        let identifiers = [
            ("Logic Pro", "com.apple.logic10"),
            ("GarageBand", "com.apple.garageband10"),
            ("Ableton Live", "com.ableton.live"),
            ("FL Studio", "com.image-line.flstudio"),
            ("Bitwig Studio", "com.bitwig.BitwigStudio"),
            ("Cubase", "com.steinberg.cubase"),
            ("Studio One", "com.presonus.studioone"),
            ("REAPER", "com.cockos.reaper"),
        ]
        var found = identifiers.compactMap { name, identifier -> (String, URL)? in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).map { (name, $0) }
        }
        // Ableton's identifier changes with each edition, so it's also looked for by name.
        if !found.contains(where: { $0.0 == "Ableton Live" }),
           let live = try? FileManager.default.contentsOfDirectory(atPath: "/Applications").first(where: { $0.hasPrefix("Ableton Live") && $0.hasSuffix(".app") }) {
            found.append(("Ableton Live", URL(fileURLWithPath: "/Applications").appending(path: live)))
        }
        return found
    }

    func open(_ files: [URL], in app: URL) {
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func showInFinder(_ files: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    // MARK: - Permissions

    /// Plug-ins often read from these folders, and macOS asks about each the first time. Going through them now gets
    /// all the questions out of the way together, rather than in the middle of playing.
    func askForFolderAccess() {
        let home = FolderAccess.userHome
        Task.detached(priority: .userInitiated) {
            for folder in ["Documents", "Desktop", "Downloads", "Music"] {
                _ = try? FileManager.default.contentsOfDirectory(atPath: home.appending(path: folder).path)
            }
        }
    }

    // MARK: - Chords

    /// Changing a sound's pitch by changing its speed also changes its length, so the notes of a chord drift apart.
    /// This prepares a version for each key that's the same length as the others. Keys play the plain sound until
    /// their version is ready, closest to the root note first, so playing never has to wait.
    private func prepareKeyboardNotes() {
        keyboardNotesTask?.cancel()
        for (note, audio) in keyboardNotes {
            engine.mixer.setNoteSound(note, to: nil)
            retire(audio)
        }
        keyboardNotes = [:]

        let slot = slots[SamplerSlot.keyboardIndex]
        guard slot.keepsLength, let url = slot.url else {
            isPreparingKeys = false
            return
        }

        isPreparingKeys = true
        keyboardNotesTask = Task {
            guard let audio = try? await audio(for: url), !Task.isCancelled else { return }

            let startFrame = Int(slot.start * Double(audio.frameCount))
            let endFrame = Int(slot.end * Double(audio.frameCount))
            let bytesPerNote = max(1, Int(Double(endFrame - startFrame) / slot.speed)) * 2 * MemoryLayout<Float>.size
            let affordable = Self.memoryForKeyboardNotes / bytesPerNote

            let lowest = max(0, slot.rootNote - Self.semitonesPreparedOnEachSide)
            let highest = min(127, slot.rootNote + Self.semitonesPreparedOnEachSide)
            let notes = (lowest...highest).sorted { abs($0 - slot.rootNote) < abs($1 - slot.rootNote) }.prefix(affordable)

            for note in notes {
                let cents = Double(note - slot.rootNote + slot.tune) * 100 - slot.fineTune
                // The plain sound is already right for this key.
                if cents == 0 { continue }

                guard let rendered = try? await audio.stretchedInBackground(
                    from: startFrame,
                    to: endFrame,
                    speed: slot.speed,
                    pitchCents: cents
                ), !Task.isCancelled else { return }

                keyboardNotes[note] = rendered
                engine.mixer.setNoteSound(note, to: SamplerMixer.NoteSound(
                    left: rendered.left,
                    right: rendered.right,
                    frameCount: rendered.frameCount,
                    sampleRate: rendered.sampleRate
                ))
            }
            isPreparingKeys = false
        }
    }

    // MARK: - The waveform

    private func refreshPadPeaks(_ index: Int) {
        guard let playable = playables[index] else { return }
        let total = Double(playable.audio.frameCount)
        let start = Double(playable.startFrame) / total
        let end = Double(playable.endFrame) / total
        Task {
            let peaks = await playable.audio.peaksInBackground(from: start, to: end, count: Self.padPeakCount)
            if playables[index]?.audio === playable.audio { padStates[index].peaks = peaks }
        }
    }

    /// The outline of part of a slot's whole file, if it's already been worked out.
    func cachedPeaks(of index: Int, from start: Double, to end: Double, count: Int) -> [Float]? {
        guard let path = slots[index].path else { return nil }
        return peaksCache[PeaksRequest(path: path, start: start, end: end, count: count)]
    }

    /// The outline of part of a slot's whole file, whatever part of the file is being played.
    func peaks(of index: Int, from start: Double, to end: Double, count: Int) async -> [Float] {
        guard let path = slots[index].path, let url = slots[index].url else { return [] }

        let request = PeaksRequest(path: path, start: start, end: end, count: count)
        if let cached = peaksCache[request] { return cached }

        guard CloudFiles.isOnThisMac(url), let audio = try? await audio(for: url) else { return [] }
        let peaks = await audio.peaksInBackground(from: start, to: end, count: count)
        if peaksCache.count > 64 { peaksCache.removeAll() }
        peaksCache[request] = peaks
        return peaks
    }

    /// The length of the whole file, once it's loaded. Stretched sounds are a different length, so this asks the file.
    func fileDuration(of index: Int) -> TimeInterval? {
        fileDurations[index]
    }

    // MARK: - Remembering the kit

    nonisolated private static var kitFile: URL {
        URL.applicationSupportDirectory.appending(path: "Sampler Kit.json")
    }

    private func loadKitIfNeeded() {
        guard !hasLoadedKit else { return }
        hasLoadedKit = true

        guard let data = try? Data(contentsOf: Self.kitFile),
              let kit = try? JSONDecoder().decode(SamplerKit.self, from: data),
              kit.slots.count == SamplerSlot.count, kit.padBindings.count == SamplerSlot.padCount,
              kit.knobControllers.count == SamplerKnob.allCases.count
        else { return }

        slots = kit.slots
        padBindings = kit.padBindings
        knobControllers = kit.knobControllers
        deviceProfiles = kit.deviceProfiles
        master = kit.master
        engine.setMaster(master)
        sequencer.load(kit.pattern)
        slots.indices.forEach(reload)
        effects.restore(kit.plugins)
    }

    private func saveSoon() {
        saveTask?.cancel()
        var kit = SamplerKit()
        kit.slots = slots
        kit.padBindings = padBindings
        kit.knobControllers = knobControllers
        kit.plugins = effects.savedEntries
        kit.deviceProfiles = deviceProfiles
        kit.pattern = sequencer.pattern
        kit.master = master
        saveTask = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            await Self.save(kit)
        }
    }

    @concurrent nonisolated private static func save(_ kit: SamplerKit) async {
        guard let data = try? JSONEncoder().encode(kit) else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: kitFile, options: .atomic)
    }
}
