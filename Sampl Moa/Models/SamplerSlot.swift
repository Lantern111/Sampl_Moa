import Foundation

/// What a sound does when its pad or key is let go.
nonisolated enum SamplerPlayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneShot, hold, loop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneShot: String(localized: "One Shot")
        case .hold: String(localized: "Hold")
        case .loop: String(localized: "Loop")
        }
    }
}

/// The eight controls every sound has, in the order of the knobs on a controller: two rows of four.
nonisolated enum SamplerKnob: Int, CaseIterable, Identifiable, Sendable {
    case volume, pitch, speed, filter, low, mid, high, pan

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .volume: String(localized: "Volume")
        case .pitch: String(localized: "Pitch")
        case .speed: String(localized: "Speed")
        case .filter: String(localized: "Filter")
        case .low: String(localized: "Low")
        case .mid: String(localized: "Mid")
        case .high: String(localized: "High")
        case .pan: String(localized: "Pan")
        }
    }

    /// Where the knob sits when nothing has been changed.
    var neutralValue: Double {
        switch self {
        case .volume: SamplerFaderScale.unityPosition
        case .pitch, .speed, .filter, .low, .mid, .high, .pan: 0.5
        }
    }

    /// Whether the master has this control too. It has a fader, EQ and a filter. Pitch, speed and pan only make
    /// sense for one sound.
    var appliesToMaster: Bool {
        switch self {
        case .volume, .filter, .low, .mid, .high: true
        case .pitch, .speed, .pan: false
        }
    }
}

/// One knob for a filter, the way a DJ mixer has it: turning left of the middle closes a low-pass filter, turning right
/// opens a high-pass one, and the middle leaves the sound alone. Each way runs from -1 to 1.
nonisolated enum SamplerFilterSweep {
    enum Shape: Equatable {
        case off
        case lowPass(Double)
        case highPass(Double)
    }

    /// A little of the ring that makes a filter sweep sound like one.
    static let resonance = 1.1

    static func shape(of amount: Double) -> Shape {
        if abs(amount) < 0.02 { return .off }
        if amount < 0 { return .lowPass(20000 * pow(80.0 / 20000, -amount)) }
        return .highPass(20 * pow(8000.0 / 20, amount))
    }

    static func reading(of amount: Double) -> String {
        func hertz(_ frequency: Double) -> String {
            frequency >= 1000 ? String(format: "%.1fk", frequency / 1000) : String(format: "%.0f", frequency)
        }
        switch shape(of: amount) {
        case .off: return String(localized: "filter.off", defaultValue: "Off", comment: "A filter knob in the middle, doing nothing.")
        case .lowPass(let frequency): return "LP " + hertz(frequency)
        case .highPass(let frequency): return "HP " + hertz(frequency)
        }
    }

    static func position(of amount: Double) -> Double { (amount + 1) / 2 }
    static func amount(at position: Double) -> Double { position * 2 - 1 }
}

/// Left and right of a sound, like a mixer's pan knob. On a stereo sound it turns down the other side.
nonisolated enum SamplerPan {
    static func reading(of pan: Float) -> String {
        let amount = Int((abs(pan) * 100).rounded())
        if amount == 0 { return "C" }
        return pan < 0 ? "L\(amount)" : "R\(amount)"
    }
}

/// Volume in decibels along a fader, the way a mixing desk works: most of the travel is the useful range near the
/// top, with 0 dB a little below it and room for 6 dB more.
nonisolated enum SamplerFaderScale {
    private static let lowest = -48.0
    private static let highest = 6.0

    static let unityPosition = -lowest / (highest - lowest)

    static func position(of gain: Float) -> Double {
        guard gain > 0.0001 else { return 0 }
        return min(max((20 * log10(Double(gain)) - lowest) / (highest - lowest), 0), 1)
    }

    static func gain(at rawPosition: Double) -> Float {
        // Hard to land on exactly by hand, and 0 dB means "as recorded".
        let position = abs(rawPosition - unityPosition) < 0.01 ? unityPosition : rawPosition
        guard position > 0.001 else { return 0 }
        return Float(pow(10, (position * (highest - lowest) + lowest) / 20))
    }

    static func reading(of gain: Float) -> String {
        guard gain > 0.0001 else { return "-∞" }
        return String(format: "%.1f", 20 * log10(Double(gain)))
    }
}

/// What everything passes through on its way out: like the Stereo Out channel in Logic Pro. Changing it leaves every
/// pad's own balance alone. Like Stereo Out, it has no sends, so it can't silence the pads' delay or reverb.
nonisolated struct SamplerMaster: Codable, Equatable, Sendable {
    private static let eqRange = 12.0

    var gain: Float = 1
    var eqLow = 0.0
    var eqMid = 0.0
    var eqHigh = 0.0
    /// A filter on everything, from -1 to 1: see `SamplerFilterSweep`.
    var filter = 0.0

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SamplerMaster()
        gain = try values.decodeIfPresent(Float.self, forKey: .gain) ?? defaults.gain
        eqLow = try values.decodeIfPresent(Double.self, forKey: .eqLow) ?? defaults.eqLow
        eqMid = try values.decodeIfPresent(Double.self, forKey: .eqMid) ?? defaults.eqMid
        eqHigh = try values.decodeIfPresent(Double.self, forKey: .eqHigh) ?? defaults.eqHigh
        filter = try values.decodeIfPresent(Double.self, forKey: .filter) ?? defaults.filter
    }

    /// Nil for a control the master doesn't have.
    func position(of knob: SamplerKnob) -> Double? {
        switch knob {
        case .volume: SamplerFaderScale.position(of: gain)
        case .low: (eqLow + Self.eqRange) / (Self.eqRange * 2)
        case .mid: (eqMid + Self.eqRange) / (Self.eqRange * 2)
        case .high: (eqHigh + Self.eqRange) / (Self.eqRange * 2)
        case .filter: SamplerFilterSweep.position(of: filter)
        case .pitch, .speed, .pan: nil
        }
    }

    mutating func set(_ knob: SamplerKnob, toPosition rawPosition: Double) {
        let isNearNeutral = knob.neutralValue == 0.5 && abs(rawPosition - 0.5) < 0.012
        let position = isNearNeutral ? 0.5 : min(max(rawPosition, 0), 1)
        switch knob {
        case .volume: gain = SamplerFaderScale.gain(at: position)
        case .low: eqLow = position * Self.eqRange * 2 - Self.eqRange
        case .mid: eqMid = position * Self.eqRange * 2 - Self.eqRange
        case .high: eqHigh = position * Self.eqRange * 2 - Self.eqRange
        case .filter: filter = SamplerFilterSweep.amount(at: position)
        case .pitch, .speed, .pan: break
        }
    }

    func reading(of knob: SamplerKnob) -> String {
        switch knob {
        case .volume: SamplerFaderScale.reading(of: gain)
        case .low: String(format: "%+.1f dB", eqLow)
        case .mid: String(format: "%+.1f dB", eqMid)
        case .high: String(format: "%+.1f dB", eqHigh)
        case .filter: SamplerFilterSweep.reading(of: filter)
        case .pitch, .speed, .pan: ""
        }
    }
}

/// One sound in the sampler: a file, the part of it to play, and how to play that part.
nonisolated struct SamplerSlot: Codable, Equatable, Sendable {
    /// Four banks of 16 pads, as on an MPC, then the sound the keyboard plays. A device's 16 pads play whichever bank
    /// is showing.
    static let padsPerBank = 16
    static let bankCount = 4
    static let padCount = padsPerBank * bankCount
    static let keyboardIndex = padCount
    static let count = padCount + 1

    static func bank(of pad: Int) -> Int {
        pad / padsPerBank
    }

    static func bankName(_ bank: Int) -> String {
        String(UnicodeScalar(UInt8(ascii: "A") + UInt8(bank)))
    }

    /// Like an MPC's: A1 to A16, then B1 and on.
    static func name(ofPad pad: Int) -> String {
        bankName(bank(of: pad)) + String(pad % padsPerBank + 1)
    }

    /// The pads of a bank, in order.
    static func pads(inBank bank: Int) -> Range<Int> {
        bank * padsPerBank..<(bank + 1) * padsPerBank
    }

    private static let eqRange = 12.0
    private static let tuneRange = 24

    var path: String?
    /// Where the sound starts and ends, as fractions of the whole file.
    var start = 0.0
    var end = 1.0
    /// Changes the length without changing the pitch.
    var speed = 1.0
    /// Changes the pitch and the length together, like speeding up a record.
    var tune = 0
    var volume: Float = 1
    var mode = SamplerPlayMode.oneShot
    /// Sounds in the same group cut each other off, the way a closed hi-hat silences an open one. 0 means no group.
    var cutGroup = 0
    /// The key that plays the file at its original pitch.
    var rootNote = SamplerNote.middleC
    /// How far the recording sits from that note, in hundredths of a semitone, so that the keyboard plays in tune.
    var fineTune = 0.0
    /// Boost or cut in decibels.
    var eqLow = 0.0
    var eqMid = 0.0
    var eqHigh = 0.0
    /// From -1 to 1: see `SamplerFilterSweep`.
    var filter: Float = 0
    /// From -1, all the way left, to 1, all the way right.
    var pan: Float = 0
    /// On the keyboard, gives every key the same length so that the notes of a chord stay together.
    var keepsLength = false
    /// The tempo the sound was recorded at, from Splice, its name, or typed in. Nil when it isn't known.
    var sourceBPM: Double?
    /// Whether its speed follows the sampler's tempo, so a loop stays in time when the tempo changes.
    var followsTempo = false

    var url: URL? {
        path.map { URL(fileURLWithPath: $0) }
    }

    var name: String {
        url?.deletingPathExtension().lastPathComponent ?? ""
    }

    init() {}

    /// Anything missing from an older save takes its default, so that an update never loses someone's kit.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SamplerSlot()
        path = try values.decodeIfPresent(String.self, forKey: .path)
        start = try values.decodeIfPresent(Double.self, forKey: .start) ?? defaults.start
        end = try values.decodeIfPresent(Double.self, forKey: .end) ?? defaults.end
        speed = try values.decodeIfPresent(Double.self, forKey: .speed) ?? defaults.speed
        tune = try values.decodeIfPresent(Int.self, forKey: .tune) ?? defaults.tune
        volume = try values.decodeIfPresent(Float.self, forKey: .volume) ?? defaults.volume
        mode = try values.decodeIfPresent(SamplerPlayMode.self, forKey: .mode) ?? defaults.mode
        cutGroup = try values.decodeIfPresent(Int.self, forKey: .cutGroup) ?? defaults.cutGroup
        rootNote = try values.decodeIfPresent(Int.self, forKey: .rootNote) ?? defaults.rootNote
        fineTune = try values.decodeIfPresent(Double.self, forKey: .fineTune) ?? defaults.fineTune
        eqLow = try values.decodeIfPresent(Double.self, forKey: .eqLow) ?? defaults.eqLow
        eqMid = try values.decodeIfPresent(Double.self, forKey: .eqMid) ?? defaults.eqMid
        eqHigh = try values.decodeIfPresent(Double.self, forKey: .eqHigh) ?? defaults.eqHigh
        filter = try values.decodeIfPresent(Float.self, forKey: .filter) ?? defaults.filter
        pan = try values.decodeIfPresent(Float.self, forKey: .pan) ?? defaults.pan
        keepsLength = try values.decodeIfPresent(Bool.self, forKey: .keepsLength) ?? defaults.keepsLength
        sourceBPM = try values.decodeIfPresent(Double.self, forKey: .sourceBPM)
        followsTempo = try values.decodeIfPresent(Bool.self, forKey: .followsTempo) ?? defaults.followsTempo
    }

    // MARK: - Knobs

    /// A knob's position from 0 to 1.
    func position(of knob: SamplerKnob) -> Double {
        switch knob {
        case .volume: SamplerFaderScale.position(of: volume)
        case .pitch: Double(tune + Self.tuneRange) / Double(Self.tuneRange * 2)
        case .speed: (log2(speed) + 1) / 2
        case .filter: SamplerFilterSweep.position(of: Double(filter))
        case .pan: Double(pan + 1) / 2
        case .low: (eqLow + Self.eqRange) / (Self.eqRange * 2)
        case .mid: (eqMid + Self.eqRange) / (Self.eqRange * 2)
        case .high: (eqHigh + Self.eqRange) / (Self.eqRange * 2)
        }
    }

    mutating func set(_ knob: SamplerKnob, toPosition rawPosition: Double) {
        // Hard to land on exactly by hand, and the middle of these knobs means "leave it alone".
        let isNearNeutral = knob.neutralValue == 0.5 && abs(rawPosition - 0.5) < 0.012
        let position = isNearNeutral ? 0.5 : min(max(rawPosition, 0), 1)

        switch knob {
        case .volume: volume = SamplerFaderScale.gain(at: position)
        case .pitch: tune = Int((position * Double(Self.tuneRange * 2)).rounded()) - Self.tuneRange
        case .speed: speed = pow(2, position * 2 - 1)
        case .filter: filter = Float(SamplerFilterSweep.amount(at: position))
        case .pan: pan = Float(position * 2 - 1)
        case .low: eqLow = position * Self.eqRange * 2 - Self.eqRange
        case .mid: eqMid = position * Self.eqRange * 2 - Self.eqRange
        case .high: eqHigh = position * Self.eqRange * 2 - Self.eqRange
        }
    }

    func reading(of knob: SamplerKnob) -> String {
        func decibels(_ value: Double) -> String { String(format: "%+.1f dB", value) }
        func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }

        switch knob {
        case .volume: return SamplerFaderScale.reading(of: volume)
        case .pitch: return tune > 0 ? "+\(tune)" : "\(tune)"
        case .speed: return percent(speed)
        case .filter: return SamplerFilterSweep.reading(of: Double(filter))
        case .pan: return SamplerPan.reading(of: pan)
        case .low: return decibels(eqLow)
        case .mid: return decibels(eqMid)
        case .high: return decibels(eqHigh)
        }
    }
}

/// Which key on a device plays a pad.
nonisolated struct SamplerPadBinding: Codable, Equatable, Sendable {
    var channel: Int
    var note: Int

    /// What most pad controllers send out of the box, the MPK mini included: channel 10, starting from note 36.
    static func standard(forPad pad: Int) -> SamplerPadBinding {
        SamplerPadBinding(channel: 9, note: 36 + pad)
    }
}

/// A plug-in in the effects chain, and everything needed to bring it back on the next launch.
nonisolated struct SamplerPluginEntry: Codable, Equatable, Sendable {
    var name: String
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32
    /// The pad or keyboard it belongs to, or nil if everything passes through it.
    var slot: Int?
    var isOn = true
    var state: Data?
}

/// What one device's pads and knobs send, remembered so that it's right the next time it's plugged in.
nonisolated struct SamplerDeviceProfile: Codable, Equatable, Sendable {
    var padBindings: [SamplerPadBinding]
    var knobControllers: [Int]
}

/// Everything the sampler remembers between launches.
nonisolated struct SamplerKit: Codable, Equatable, Sendable {
    /// What the MPK mini's knobs send out of the box.
    static let standardKnobControllers = SamplerKnob.allCases.map { 70 + $0.rawValue }

    var slots = Array(repeating: SamplerSlot(), count: SamplerSlot.count)
    /// What each of a device's 16 pads sends, the same whichever bank it's playing.
    var padBindings = (0..<SamplerSlot.padsPerBank).map(SamplerPadBinding.standard(forPad:))
    var knobControllers = standardKnobControllers
    var plugins: [SamplerPluginEntry] = []
    var deviceProfiles: [String: SamplerDeviceProfile] = [:]
    var pattern = SamplerPattern()
    var master = SamplerMaster()

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SamplerKit()
        slots = try values.decodeIfPresent([SamplerSlot].self, forKey: .slots) ?? defaults.slots
        padBindings = try values.decodeIfPresent([SamplerPadBinding].self, forKey: .padBindings) ?? defaults.padBindings
        knobControllers = try values.decodeIfPresent([Int].self, forKey: .knobControllers) ?? defaults.knobControllers
        plugins = try values.decodeIfPresent([SamplerPluginEntry].self, forKey: .plugins) ?? defaults.plugins
        deviceProfiles = try values.decodeIfPresent([String: SamplerDeviceProfile].self, forKey: .deviceProfiles) ?? defaults.deviceProfiles
        pattern = try values.decodeIfPresent(SamplerPattern.self, forKey: .pattern) ?? defaults.pattern
        master = try values.decodeIfPresent(SamplerMaster.self, forKey: .master) ?? defaults.master
        moveIntoBanks()
    }

    /// Kits from before there were banks have 16 pads and then the keyboard's sound. Those pads become bank A, and
    /// everything that pointed at the keyboard's sound, its plug-ins and the notes recorded on it, follows it to its
    /// new place.
    private mutating func moveIntoBanks() {
        let oldKeyboard = SamplerSlot.padsPerBank
        guard slots.count == oldKeyboard + 1 else { return }
        slots = Array(slots.prefix(oldKeyboard))
            + Array(repeating: SamplerSlot(), count: SamplerSlot.padCount - oldKeyboard)
            + [slots[oldKeyboard]]
        for index in plugins.indices where plugins[index].slot == oldKeyboard {
            plugins[index].slot = SamplerSlot.keyboardIndex
        }
        for index in pattern.notes.indices where pattern.notes[index].slot == oldKeyboard {
            pattern.notes[index].slot = SamplerSlot.keyboardIndex
        }
    }
}

nonisolated enum SamplerNote {
    /// Called C3 in Logic Pro and on the MPK mini.
    static let middleC = 60

    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func name(of note: Int) -> String {
        names[((note % 12) + 12) % 12] + String(note / 12 - 2)
    }
}
