import Foundation

/// How closely recorded notes are pulled to the beat.
nonisolated enum SamplerQuantize: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, eighth, sixteenth, thirtySecond

    var id: String { rawValue }

    /// The grid in beats, or nil to play back just as it was played.
    var grid: Double? {
        switch self {
        case .off: nil
        case .eighth: 0.5
        case .sixteenth: 0.25
        case .thirtySecond: 0.125
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .eighth: "1/8"
        case .sixteenth: "1/16"
        case .thirtySecond: "1/32"
        }
    }
}

/// One note in a recording. Kept as it was played, so the timing can be changed afterwards without losing anything.
nonisolated struct SamplerRecordedNote: Codable, Equatable, Sendable {
    var slot: Int
    /// A key on the keyboard, or nil for a pad.
    var note: Int?
    var velocity: Int
    /// Where it was played, in beats from the start of the pattern.
    var beat: Double
    var length: Double
    /// Which pass through the recorder it came from, so the last one can be taken back.
    var take: Int
}

/// A short loop of notes.
nonisolated struct SamplerPattern: Codable, Equatable, Sendable {
    /// A note played, with its timing worked out.
    struct TimedNote: Equatable {
        var slot: Int
        var note: Int?
        var velocity: Int
        var beat: Double
        var length: Double
    }

    var bpm = 90.0
    var bars = 2
    var quantize = SamplerQuantize.sixteenth
    /// How late the offbeats fall, from 50%, which is straight, up to 75%.
    var swing = 0.5
    var notes: [SamplerRecordedNote] = []

    var beats: Double { Double(bars * 4) }
    var secondsPerBeat: Double { 60 / bpm }
    var seconds: Double { beats * secondsPerBeat }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SamplerPattern()
        bpm = try values.decodeIfPresent(Double.self, forKey: .bpm) ?? defaults.bpm
        bars = try values.decodeIfPresent(Int.self, forKey: .bars) ?? defaults.bars
        quantize = try values.decodeIfPresent(SamplerQuantize.self, forKey: .quantize) ?? defaults.quantize
        swing = try values.decodeIfPresent(Double.self, forKey: .swing) ?? defaults.swing
        notes = try values.decodeIfPresent([SamplerRecordedNote].self, forKey: .notes) ?? defaults.notes
    }

    /// Where a note played at this beat lands, wrapping round if pulling it forward carries it past the end.
    func timedBeat(_ beat: Double) -> Double {
        var result = beat
        if let grid = quantize.grid {
            result = (beat / grid).rounded() * grid
        }
        // Swing moves every second sixteenth (or eighth, on an eighth-note grid) later within its pair.
        let pair = (quantize == .eighth) ? 1.0 : 0.5
        if swing > 0.5 {
            let inPair = result.truncatingRemainder(dividingBy: pair)
            if abs(inPair - pair / 2) < 0.001 {
                result += (swing - 0.5) * pair
            }
        }
        return result.truncatingRemainder(dividingBy: beats)
    }

    /// Every note with its timing worked out, in order.
    var timedNotes: [TimedNote] {
        // Notes past the end stay kept, in case the pattern is made longer again.
        notes
            .filter { $0.beat < beats }
            .map { TimedNote(slot: $0.slot, note: $0.note, velocity: $0.velocity, beat: timedBeat($0.beat), length: $0.length) }
            .sorted { $0.beat < $1.beat }
    }
}
