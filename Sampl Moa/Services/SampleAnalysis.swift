import Accelerate
import Foundation

/// Works out things about a sound that the sampler needs and nobody wants to set by hand.
nonisolated enum SampleAnalysis {
    /// Finds the note a sound should be treated as, so the keyboard plays it in tune. The file name comes first,
    /// because a melodic loop's key is what matters and no single pitch can be measured from it.
    static func root(of audio: SamplerAudio, named name: String, from start: Int, to end: Int) -> (note: Int, fineTune: Double)? {
        if let pitchClass = keyInName(name) {
            return (SamplerNote.middleC + pitchClass, 0)
        }
        guard let pitch = measurePitch(of: audio, from: start, to: end) else {
            return noteAtEndOfName(name).map { (SamplerNote.middleC + $0, 0) }
        }

        let nearest = pitch.rounded()
        // Only the note matters, not its octave. A deep 808 should still sit in the middle of a 25-key keyboard.
        let pitchClass = ((Int(nearest) % 12) + 12) % 12
        return (SamplerNote.middleC + pitchClass, (pitch - nearest) * 100)
    }

    // MARK: - Names

    /// Finds names like `Bass_C#min_140`, `Pad Am`, `lead_fmaj` and `Lead_F_major`, returning 0 for C through 11 for B.
    /// A lone letter doesn't count unless the name says it's a key, because `Kick_A` is more likely the first of a set.
    static func keyInName(_ name: String) -> Int? {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "#♯♭")).inverted
        let words = name.components(separatedBy: separators).filter { !$0.isEmpty }

        for (index, word) in words.enumerated().reversed() {
            guard let (pitchClass, isCertain) = key(from: word) else { continue }
            if isCertain { return pitchClass }

            let next = index + 1 < words.count ? words[index + 1].lowercased() : ""
            let previous = index > 0 ? words[index - 1].lowercased() : ""
            if ["maj", "major", "min", "minor"].contains(next) || previous == "key" {
                return pitchClass
            }
        }
        return nil
    }

    /// Bass one-shots are often named like `Bass_Bronze_E`. That's only good enough to use once measuring has found no
    /// pitch, since it could also be the last of a set.
    private static func noteAtEndOfName(_ name: String) -> Int? {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "#♯♭")).inverted
        return name.components(separatedBy: separators).last(where: { !$0.isEmpty }).flatMap { key(from: $0)?.pitchClass }
    }

    private static func key(from word: String) -> (pitchClass: Int, isCertain: Bool)? {
        var rest = Substring(word)
        guard let letter = rest.popFirst(),
              let natural = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][letter.uppercased()]
        else { return nil }

        var pitchClass = natural
        var isCertain = false
        if let accidental = rest.first {
            if accidental == "#" || accidental == "♯" {
                pitchClass += 1
                isCertain = true
                rest.removeFirst()
            } else if accidental == "b" || accidental == "♭" {
                pitchClass -= 1
                isCertain = true
                rest.removeFirst()
            }
        }

        switch rest.lowercased() {
        case "maj", "min", "major", "minor":
            isCertain = true
        case "m" where letter.isUppercase:
            isCertain = true
        case "" where letter.isUppercase:
            break
        default:
            return nil
        }
        return ((pitchClass + 12) % 12, isCertain)
    }

    // MARK: - Pitch

    /// The pitch as a MIDI note number with a fractional part, or nil if the sound doesn't hold one clear pitch.
    /// Listens in several places along the sound, using the YIN method, and only believes an answer they agree on.
    static func measurePitch(of audio: SamplerAudio, from start: Int, to end: Int) -> Double? {
        let rate = audio.sampleRate
        let longestLag = Int(rate / 30)
        let shortestLag = Int(rate / 2000)
        let window = longestLag * 2
        // The first moments of a note are mostly noise from the attack.
        let firstFrame = start + Int(rate * 0.04)
        let available = min(end, start + Int(rate * 1.5)) - firstFrame - window - longestLag - 2
        guard available > 0 else { return nil }

        let attempts = 7
        var pitches: [Double] = []
        for attempt in 0..<attempts {
            let windowStart = firstFrame + available * attempt / max(1, attempts - 1)
            if let pitch = pitchInWindow(
                of: audio.left + windowStart,
                length: window,
                lags: shortestLag...longestLag,
                sampleRate: rate
            ) {
                pitches.append(pitch)
            }
        }
        guard pitches.count * 2 > attempts else { return nil }

        pitches.sort()
        let middle = pitches[pitches.count / 2]
        let agreeing = pitches.filter { abs($0 - middle) < 0.5 }
        guard agreeing.count * 2 > attempts else { return nil }
        return agreeing.reduce(0, +) / Double(agreeing.count)
    }

    private static func pitchInWindow(
        of samples: UnsafePointer<Float>,
        length: Int,
        lags: ClosedRange<Int>,
        sampleRate: Double
    ) -> Double? {
        var power: Float = 0
        vDSP_rmsqv(samples, 1, &power, vDSP_Length(length))
        guard power > 0.005 else { return nil }

        var differences = [Float](repeating: 0, count: lags.upperBound + 2)
        var scratch = [Float](repeating: 0, count: length)
        for lag in 1...(lags.upperBound + 1) {
            vDSP_vsub(samples + lag, 1, samples, 1, &scratch, 1, vDSP_Length(length))
            vDSP_svesq(scratch, 1, &differences[lag], vDSP_Length(length))
        }

        // How close each lag comes to repeating, compared with the lags before it. Near 0 means a near-perfect repeat.
        var total: Float = 0
        var normalized = [Float](repeating: 1, count: differences.count)
        for lag in 1..<differences.count {
            total += differences[lag]
            normalized[lag] = total > 0 ? differences[lag] * Float(lag) / total : 1
        }

        let threshold: Float = 0.12
        var lag = lags.lowerBound
        while lag <= lags.upperBound {
            if normalized[lag] < threshold {
                while lag < lags.upperBound, normalized[lag + 1] < normalized[lag] { lag += 1 }
                let before = normalized[lag - 1]
                let here = normalized[lag]
                let after = normalized[lag + 1]
                let curve = before - 2 * here + after
                let exact = Double(lag) + (curve != 0 ? Double((before - after) / (2 * curve)) : 0)
                return 69 + 12 * log2(sampleRate / exact / 440)
            }
            lag += 1
        }
        return nil
    }

    // MARK: - Chopping

    /// Finds where the hits are in a part of a sound. Returns up to `limit` positions, the first always being `start`.
    /// `threshold` is how sudden a jump has to be to count. Lower finds more.
    static func hits(in audio: SamplerAudio, from start: Int, to end: Int, limit: Int, threshold: Float = 0.35) -> [Int] {
        let hop = max(64, Int(audio.sampleRate / 200))
        let count = (end - start) / hop
        guard count > 8, limit > 1 else { return [start] }

        var levels = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let frame = start + index * hop
            var left: Float = 0
            var right: Float = 0
            vDSP_rmsqv(audio.left + frame, 1, &left, vDSP_Length(hop))
            vDSP_rmsqv(audio.right + frame, 1, &right, vDSP_Length(hop))
            levels[index] = max(left, right)
        }

        let loudest = levels.max() ?? 0
        guard loudest > 0 else { return [start] }

        // How far each moment jumps above the moments just before it. A drum hit is a big, sudden jump.
        let floor = loudest * 0.02
        var strengths = [Float](repeating: 0, count: count)
        for index in 4..<count where levels[index] > floor {
            let before = max(levels[(index - 4)..<index].reduce(0, +) / 4, floor)
            strengths[index] = log2(levels[index] / before) * (levels[index] / loudest).squareRoot()
        }

        let closestHits = max(4, Int(0.06 * audio.sampleRate) / hop)
        var candidates: [Int] = []
        for index in 1..<(count - 1) where strengths[index] > threshold {
            let neighbourhood = max(0, index - 3)...min(count - 1, index + 3)
            if strengths[neighbourhood].max() == strengths[index] { candidates.append(index) }
        }
        candidates.sort { strengths[$0] > strengths[$1] }

        var chosen: [Int] = []
        for candidate in candidates where chosen.count < limit - 1 {
            // The start of the part is always kept, so anything right next to it is the same hit.
            guard candidate >= closestHits, chosen.allSatisfy({ abs($0 - candidate) >= closestHits }) else { continue }
            chosen.append(candidate)
        }

        // A little ahead of the hit, so that the rounded-off start of a slice doesn't soften the attack.
        let lead = hop
        return [start] + chosen.sorted().map { max(start, start + $0 * hop - lead) }
    }
}
