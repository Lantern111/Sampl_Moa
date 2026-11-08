import Foundation

/// A sample's tempo, and the speed that puts it in time with another.
nonisolated enum SampleTempo {
    /// Tempos a loop could reasonably be at. Numbers outside this, like 808 or a year, aren't tempos.
    static let likelyRange = 50.0...220.0

    /// The tempo written in a file's name, as producers and sample makers do: `MNT_WC_80_Cello`, `drm128`, `90bpm`,
    /// `bpm_140`. A number on its own counts, as do digits at the end of a word. "bpm" next to a number wins over both.
    static func bpm(inName name: String) -> Double? {
        let lowered = name.lowercased()
        let words = lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init)

        // Marked as a tempo: "90bpm", "bpm90", or "bpm" just before or after the number.
        for (index, word) in words.enumerated() {
            if word.hasSuffix("bpm"), let value = tempo(String(word.dropLast(3))) { return value }
            if word.hasPrefix("bpm"), let value = tempo(String(word.dropFirst(3))) { return value }
            if word == "bpm" {
                if index > 0, let value = tempo(words[index - 1]) { return value }
                if index + 1 < words.count, let value = tempo(words[index + 1]) { return value }
            }
        }
        // A number on its own, like the 80 in "MNT_WC_80_Cello".
        for word in words where word.allSatisfy(\.isNumber) {
            if let value = tempo(word) { return value }
        }
        // Digits at the end of a word, like "drm128". Not "rhs5" or "vol2", which are too small to be tempos.
        for word in words where word.first?.isLetter == true {
            let digits = String(word.reversed().prefix { $0.isNumber }.reversed())
            if digits.count >= 2, digits.count < word.count, let value = tempo(digits) { return value }
        }
        return nil
    }

    private static func tempo(_ text: String) -> Double? {
        guard !text.isEmpty, text.count <= 3, text.allSatisfy(\.isNumber), let value = Double(text),
              likelyRange.contains(value)
        else { return nil }
        return value
    }

    /// The speed that plays a sound recorded at `source` BPM at `target` BPM. Past what the speed knob allows, half or
    /// double time is used instead, so a 60 BPM loop in a 170 BPM beat plays as if at 85.
    static func speed(from source: Double, to target: Double) -> Double {
        guard source > 0, target > 0 else { return 1 }
        var speed = target / source
        while speed > 2 { speed /= 2 }
        while speed < 0.5 { speed *= 2 }
        return speed
    }
}
