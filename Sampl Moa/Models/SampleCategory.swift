import Foundation

/// A rough kind of sound, guessed from the words in a sample's file name and folders.
nonisolated enum SampleCategory: String, CaseIterable, Identifiable, Sendable {
    case kick, snare, clap, hiHat, cymbal, percussion, drumLoop, bass, vocal, melodic, fx, other

    var id: String { rawValue }

    /// Sorting by type asks for these thousands of times, so each is looked up once.
    private static let titles = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.localizedTitle) })

    var title: String { Self.titles[self] ?? "" }

    private var localizedTitle: String {
        switch self {
        case .kick: String(localized: "Kick")
        case .snare: String(localized: "Snare")
        case .clap: String(localized: "Clap")
        case .hiHat: String(localized: "Hi-hat")
        case .cymbal: String(localized: "Cymbal")
        case .percussion: String(localized: "Percussion")
        case .drumLoop: String(localized: "Drum Loop")
        case .bass: String(localized: "808 & Bass")
        case .vocal: String(localized: "Vocal")
        case .melodic: String(localized: "Melodic")
        case .fx: String(localized: "FX")
        case .other: String(localized: "Other")
        }
    }

    /// What people might type to find this kind of sound, in either language.
    var searchTerms: String {
        switch self {
        case .kick: "kick 킥"
        case .snare: "snare 스네어"
        case .clap: "clap 클랩"
        case .hiHat: "hi-hat hihat hat 하이햇"
        case .cymbal: "cymbal 심벌 심벌즈"
        case .percussion: "percussion perc 퍼커션"
        case .drumLoop: "drum loop 드럼 루프"
        case .bass: "808 bass 베이스"
        case .vocal: "vocal 보컬"
        case .melodic: "melodic melody 멜로디"
        case .fx: "fx sfx 효과음"
        case .other: ""
        }
    }

    /// The file name decides first because it's the most specific. Folders, closest first, then Splice's tags and
    /// the pack name only fill in for names like `KMRBI_RHS5_bolt` that don't say what they are.
    static func classify(
        fileName: String,
        folders: [String],
        tags: [String] = [],
        isLoop: Bool = false,
        pack: String
    ) -> SampleCategory {
        if let category = match(words(in: fileName)) { return category }
        for folder in folders.reversed() {
            if let category = match(words(in: folder)) { return category }
        }

        // Splice tags nearly every drum sound `drums`, so that tag alone only means something on a loop.
        let usefulTags = tags.filter { $0 != "drums" }
        if let category = match(Set(usefulTags.flatMap { words(in: $0) })) { return category }
        if isLoop, tags.contains("drums") { return .drumLoop }

        return match(words(in: pack)) ?? .other
    }

    private static func match(_ words: Set<String>) -> SampleCategory? {
        // These come first so `Crash_Reverse_FX` isn't a cymbal and `Drum_Loop_No_Kick` isn't a kick.
        if !words.isDisjoint(with: ["fx", "sfx", "sfxb", "foley"]) { return .fx }
        let hasDrumPhrase = words.contains("drum") && !words.isDisjoint(with: ["loop", "loops", "fill", "fills"])
        if hasDrumPhrase || !words.isDisjoint(with: ["drumloop", "drumloops", "drums", "breakbeat", "드럼", "드럼루프"]) {
            return .drumLoop
        }
        if words.contains("bass") && words.contains("drum") { return .kick }

        return wordGroups.first { !words.isDisjoint(with: $0.1) }?.0
    }

    /// Checked for every sample in a scan, so these are built once.
    private static let wordGroups: [(SampleCategory, Set<String>)] = [
        (.bass, ["808", "808s", "bass", "basses", "bassline", "sub", "subs", "reese", "베이스", "서브"]),
        (.kick, ["kick", "kicks", "kik", "bd", "킥"]),
        (.snare, ["snare", "snares", "snr", "snrs", "스네어"]),
        (.clap, ["clap", "claps", "clp", "snap", "snaps", "클랩", "스냅"]),
        (.hiHat, ["hihat", "hihats", "hat", "hats", "hh", "openhat", "closedhat", "하이햇", "햇"]),
        (.cymbal, ["cymbal", "cymbals", "crash", "crashes", "ride", "rides", "심벌", "심벌즈", "크래시", "라이드"]),
        (.percussion, [
            "perc", "percs", "percussion", "percloop", "rim", "rims", "rimshot", "tom", "toms", "shaker", "shakers",
            "conga", "congas", "bongo", "bongos", "tamb", "tambourine", "cowbell", "woodblock", "triangle", "clave",
            "퍼커션", "탐", "쉐이커", "림",
        ]),
        (.vocal, [
            "vocal", "vocals", "vox", "adlib", "adlibs", "acapella", "chant", "chants", "choir", "shout", "shouts",
            "rap", "spoken", "phrase", "phrases", "보컬", "목소리", "랩",
        ]),
        (.melodic, [
            "melody", "melodies", "melodic", "chord", "chords", "keys", "piano", "rhodes", "organ", "synth", "synths",
            "pad", "pads", "pluck", "plucks", "lead", "leads", "arp", "arps", "bell", "bells", "guitar", "guitars",
            "strings", "flute", "brass", "horn", "horns", "sax", "violin", "harp", "songstarter", "songstarters",
            "stack", "stacks", "marimba", "kalimba", "멜로디", "코드", "피아노", "기타", "신스", "건반",
        ]),
        (.fx, [
            "riser", "risers", "impact", "impacts", "sweep", "sweeps", "downlift", "uplift", "whoosh", "whooshes",
            "transition", "transitions", "noise", "ambience", "ambiences", "ambient", "atmosphere", "atmospheres",
            "effects", "drop", "drops", "texture", "textures", "cartoon", "alarm", "alarms", "siren", "sirens",
            "gun", "guns", "gunshot", "shotguns", "rifles", "door", "doors", "footsteps", "birds", "zap", "knock",
            "knocks", "효과음", "사운드이펙트", "노이즈",
        ]),
    ]

    /// Splits `PJ_DH_92_Drum-Loop`, `ClosedHat03` and `PercLoop` into lowercase words.
    private static func words(in text: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        var previous: Character?

        for character in text {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.insert(current) }
                current = ""
                previous = nil
                continue
            }
            let startsCamelCaseWord = character.isUppercase && previous?.isLowercase == true
            let endsWordWithNumber = character.isNumber && previous?.isLetter == true
            if startsCamelCaseWord || endsWordWithNumber {
                words.insert(current)
                current = ""
            }
            current.append(contentsOf: character.lowercased())
            previous = character
        }
        if !current.isEmpty { words.insert(current) }
        // `ClosedHat` should match both as `closed` + `hat` and as written.
        words.insert(text.lowercased().filter { $0.isLetter || $0.isNumber })
        return words
    }
}
