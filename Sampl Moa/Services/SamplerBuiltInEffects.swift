import AVFoundation

/// Effects that come with every Mac, offered before any other plug-ins and under plain names. Each starts with
/// settings that can be heard straight away: left alone, Apple's distortion is a delay, a bit crusher and an overdrive
/// at once, and its filters barely do anything. Each has its own window with only the controls that matter, in the
/// manner of Logic Pro's plug-ins.
nonisolated struct SamplerBuiltInEffect: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case reverb, delay, lowPass, highPass, bandPass, distortion, compressor, limiter
        /// The reverb this app offered at first. Kits saved then still have it.
        case roomReverb
    }

    /// A knob on the effect's window: one of the Audio Unit's settings, over the range that's useful.
    struct Control: Identifiable, Sendable {
        enum Unit: Sendable {
            case percent, milliseconds, hertz, decibels, octaves
            /// Shown as a share of the range, for settings with no unit a person would know.
            case amount
        }

        let parameter: AudioUnitParameterID
        let title: String
        let range: ClosedRange<AUValue>
        let unit: Unit
        var isLogarithmic = false

        var id: AudioUnitParameterID { parameter }

        func position(of value: AUValue) -> Double {
            let value = min(max(value, range.lowerBound), range.upperBound)
            if isLogarithmic {
                return log(Double(value / range.lowerBound)) / log(Double(range.upperBound / range.lowerBound))
            }
            return Double((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        }

        func value(at position: Double) -> AUValue {
            let position = min(max(position, 0), 1)
            if isLogarithmic {
                return range.lowerBound * pow(range.upperBound / range.lowerBound, AUValue(position))
            }
            return range.lowerBound + AUValue(position) * (range.upperBound - range.lowerBound)
        }

        func reading(of value: AUValue) -> String {
            switch unit {
            case .percent:
                String(format: "%.0f%%", value)
            case .amount:
                String(format: "%.0f%%", position(of: value) * 100)
            case .milliseconds:
                value >= 1 ? String(format: "%.2f s", value)
                    : value >= 0.01 ? String(format: "%.0f ms", value * 1000)
                    : String(format: "%.1f ms", value * 1000)
            case .hertz:
                value >= 1000 ? String(format: "%.1f kHz", value / 1000) : String(format: "%.0f Hz", value)
            case .decibels:
                String(format: "%+.1f dB", value)
            case .octaves:
                String(format: "%.1f oct", value / 1200)
            }
        }
    }

    let kind: Kind
    let subType: OSType
    /// Where it starts, and where Reset puts it back.
    let startingSettings: [(AudioUnitParameterID, AudioUnitParameterValue)]
    /// Parts of the Audio Unit its window doesn't show, kept out of the way so the window matches what's heard.
    var hiddenSettings: [(AudioUnitParameterID, AudioUnitParameterValue)] = []
    let controls: [Control]

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .reverb, .roomReverb: String(localized: "Reverb")
        case .delay: String(localized: "Delay")
        case .lowPass: String(localized: "Low-Pass Filter")
        case .highPass: String(localized: "High-Pass Filter")
        case .bandPass: String(localized: "Band-Pass Filter")
        case .distortion: String(localized: "Distortion")
        case .compressor: String(localized: "Compressor")
        case .limiter: String(localized: "Limiter")
        }
    }

    var description: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    func startingValue(of parameter: AudioUnitParameterID) -> AUValue? {
        startingSettings.first { $0.0 == parameter }?.1
    }

    /// The effects offered to choose from.
    static let all: [SamplerBuiltInEffect] = [
        SamplerBuiltInEffect(
            kind: .reverb,
            subType: kAudioUnitSubType_Reverb2,
            startingSettings: [
                (kReverb2Param_DryWetMix, 30), (kReverb2Param_Gain, 0),
                (kReverb2Param_DecayTimeAt0Hz, 2), (kReverb2Param_DecayTimeAtNyquist, 1),
                (kReverb2Param_MaxDelayTime, 0.06), (kReverb2Param_MinDelayTime, 0.008),
            ],
            controls: [
                Control(parameter: kReverb2Param_DecayTimeAt0Hz, title: String(localized: "Decay"), range: 0.1...10, unit: .milliseconds, isLogarithmic: true),
                Control(parameter: kReverb2Param_DecayTimeAtNyquist, title: String(localized: "High Decay"), range: 0.1...10, unit: .milliseconds, isLogarithmic: true),
                Control(parameter: kReverb2Param_MaxDelayTime, title: String(localized: "Size"), range: 0.01...0.5, unit: .milliseconds, isLogarithmic: true),
                Control(parameter: kReverb2Param_MinDelayTime, title: String(localized: "Pre-delay"), range: 0.001...0.05, unit: .milliseconds, isLogarithmic: true),
                Control(parameter: kReverb2Param_DryWetMix, title: String(localized: "Mix"), range: 0...100, unit: .percent),
            ]
        ),
        SamplerBuiltInEffect(
            kind: .delay,
            subType: kAudioUnitSubType_Delay,
            startingSettings: [
                (kDelayParam_WetDryMix, 30), (kDelayParam_DelayTime, 0.375),
                (kDelayParam_Feedback, 35), (kDelayParam_LopassCutoff, 9000),
            ],
            controls: [
                Control(parameter: kDelayParam_DelayTime, title: String(localized: "Time"), range: 0.01...2, unit: .milliseconds, isLogarithmic: true),
                Control(parameter: kDelayParam_Feedback, title: String(localized: "Feedback"), range: 0...95, unit: .percent),
                Control(parameter: kDelayParam_LopassCutoff, title: String(localized: "Tone"), range: 200...20000, unit: .hertz, isLogarithmic: true),
                Control(parameter: kDelayParam_WetDryMix, title: String(localized: "Mix"), range: 0...100, unit: .percent),
            ]
        ),
        SamplerBuiltInEffect(
            kind: .lowPass,
            subType: kAudioUnitSubType_LowPassFilter,
            startingSettings: [(kLowPassParam_CutoffFrequency, 1200), (kLowPassParam_Resonance, 6)],
            controls: [
                Control(parameter: kLowPassParam_CutoffFrequency, title: String(localized: "Cutoff"), range: 20...20000, unit: .hertz, isLogarithmic: true),
                Control(parameter: kLowPassParam_Resonance, title: String(localized: "Resonance"), range: -12...24, unit: .decibels),
            ]
        ),
        SamplerBuiltInEffect(
            kind: .highPass,
            subType: kAudioUnitSubType_HighPassFilter,
            startingSettings: [(kHipassParam_CutoffFrequency, 400), (kHipassParam_Resonance, 3)],
            controls: [
                Control(parameter: kHipassParam_CutoffFrequency, title: String(localized: "Cutoff"), range: 20...20000, unit: .hertz, isLogarithmic: true),
                Control(parameter: kHipassParam_Resonance, title: String(localized: "Resonance"), range: -12...24, unit: .decibels),
            ]
        ),
        SamplerBuiltInEffect(
            kind: .bandPass,
            subType: kAudioUnitSubType_BandPassFilter,
            startingSettings: [(kBandpassParam_CenterFrequency, 1000), (kBandpassParam_Bandwidth, 1200)],
            controls: [
                Control(parameter: kBandpassParam_CenterFrequency, title: String(localized: "Frequency"), range: 20...20000, unit: .hertz, isLogarithmic: true),
                Control(parameter: kBandpassParam_Bandwidth, title: String(localized: "Width"), range: 100...12000, unit: .octaves, isLogarithmic: true),
            ]
        ),
        SamplerBuiltInEffect(
            kind: .distortion,
            subType: kAudioUnitSubType_Distortion,
            startingSettings: [
                (kDistortionParam_CubicTerm, 6), (kDistortionParam_SquaredTerm, 2),
                (kDistortionParam_Decimation, 40), (kDistortionParam_Rounding, 30), (kDistortionParam_DecimationMix, 0),
                (kDistortionParam_SoftClipGain, -6), (kDistortionParam_FinalMix, 60),
            ],
            hiddenSettings: [
                (kDistortionParam_DelayMix, 0), (kDistortionParam_RingModMix, 0),
                (kDistortionParam_PolynomialMix, 100), (kDistortionParam_LinearTerm, 1),
            ],
            controls: [
                Control(parameter: kDistortionParam_CubicTerm, title: String(localized: "Drive"), range: 0...20, unit: .amount),
                Control(parameter: kDistortionParam_SquaredTerm, title: String(localized: "Warmth"), range: 0...20, unit: .amount),
                Control(parameter: kDistortionParam_DecimationMix, title: String(localized: "Crush"), range: 0...100, unit: .percent),
                Control(parameter: kDistortionParam_SoftClipGain, title: String(localized: "Output"), range: -24...12, unit: .decibels),
                Control(parameter: kDistortionParam_FinalMix, title: String(localized: "Mix"), range: 0...100, unit: .percent),
            ]
        ),
        SamplerBuiltInEffect(
            kind: .compressor,
            subType: kAudioUnitSubType_DynamicsProcessor,
            startingSettings: [
                (kDynamicsProcessorParam_Threshold, -20), (kDynamicsProcessorParam_HeadRoom, 5),
                (kDynamicsProcessorParam_ExpansionRatio, 1), (kDynamicsProcessorParam_ExpansionThreshold, -100),
                (kDynamicsProcessorParam_AttackTime, 0.005), (kDynamicsProcessorParam_ReleaseTime, 0.15),
                (kDynamicsProcessorParam_OverallGain, 0),
            ],
            controls: [
                Control(parameter: kDynamicsProcessorParam_Threshold, title: String(localized: "Threshold"), range: -40...0, unit: .decibels),
                Control(parameter: kDynamicsProcessorParam_HeadRoom, title: String(localized: "Headroom"), range: 0.5...30, unit: .decibels, isLogarithmic: true),
                Control(parameter: kDynamicsProcessorParam_AttackTime, title: String(localized: "Attack"), range: 0.001...0.3, unit: .milliseconds, isLogarithmic: true),
                Control(parameter: kDynamicsProcessorParam_ReleaseTime, title: String(localized: "Release"), range: 0.01...3, unit: .milliseconds, isLogarithmic: true),
                Control(parameter: kDynamicsProcessorParam_OverallGain, title: String(localized: "Gain"), range: -20...20, unit: .decibels),
            ]
        ),
        SamplerBuiltInEffect(
            kind: .limiter,
            subType: kAudioUnitSubType_PeakLimiter,
            startingSettings: [(kLimiterParam_AttackTime, 0.002), (kLimiterParam_DecayTime, 0.01), (kLimiterParam_PreGain, 0)],
            controls: [
                Control(parameter: kLimiterParam_PreGain, title: String(localized: "Gain"), range: -10...20, unit: .decibels),
                Control(parameter: kLimiterParam_AttackTime, title: String(localized: "Lookahead"), range: 0.0005...0.03, unit: .milliseconds, isLogarithmic: true),
                Control(parameter: kLimiterParam_DecayTime, title: String(localized: "Release"), range: 0.001...0.04, unit: .milliseconds, isLogarithmic: true),
            ]
        ),
    ]

    private static let roomReverb = SamplerBuiltInEffect(
        kind: .roomReverb,
        subType: kAudioUnitSubType_MatrixReverb,
        startingSettings: [
            (kReverbParam_DryWetMix, 30), (kReverbParam_LargeSize, 0.06), (kReverbParam_PreDelay, 0.015),
            (kReverbParam_LargeBrightness, 0.65), (kReverbParam_SmallLargeMix, 35),
        ],
        controls: [
            Control(parameter: kReverbParam_LargeSize, title: String(localized: "Size"), range: 0.005...0.15, unit: .milliseconds, isLogarithmic: true),
            Control(parameter: kReverbParam_PreDelay, title: String(localized: "Pre-delay"), range: 0.001...0.03, unit: .milliseconds, isLogarithmic: true),
            Control(parameter: kReverbParam_LargeBrightness, title: String(localized: "Damping"), range: 0.1...1, unit: .amount),
            Control(parameter: kReverbParam_SmallLargeMix, title: String(localized: "Room"), range: 0...100, unit: .percent),
            Control(parameter: kReverbParam_DryWetMix, title: String(localized: "Mix"), range: 0...100, unit: .percent),
        ]
    )

    /// The built-in effect a plug-in is, if it's one of these.
    static func matching(type: OSType, subType: OSType, manufacturer: OSType) -> SamplerBuiltInEffect? {
        guard type == kAudioUnitType_Effect, manufacturer == kAudioUnitManufacturer_Apple else { return nil }
        return (all + [roomReverb]).first { $0.subType == subType }
    }

    /// For one just added, and for Reset. One brought back from a saved kit keeps the settings it was saved with.
    func applyStartingSettings(to unit: AVAudioUnit) {
        apply(hiddenSettings + startingSettings, to: unit)
    }

    func applyHiddenSettings(to unit: AVAudioUnit) {
        apply(hiddenSettings, to: unit)
    }

    private func apply(_ settings: [(AudioUnitParameterID, AudioUnitParameterValue)], to unit: AVAudioUnit) {
        // These are Audio Units of the older kind, where a setting's address is its plain parameter ID.
        let tree = unit.auAudioUnit.parameterTree
        for (parameter, value) in settings {
            tree?.parameter(withAddress: AUParameterAddress(parameter))?.value = value
        }
    }

    // MARK: - Drawing what a filter does

    /// How much a filter raises or lowers each frequency, in decibels. `amount` is the resonance in decibels for the
    /// low-pass and high-pass filters, and the width in cents for the band-pass one.
    static func filterResponse(_ kind: Kind, frequency: Double, amount: Double, at frequencies: [Double], rate: Double = 48000) -> [Double] {
        let center = min(max(frequency, 10), rate * 0.49)
        let angle = 2 * Double.pi * center / rate
        let (cosine, sine) = (cos(angle), sin(angle))
        let coefficients: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)
        switch kind {
        case .bandPass:
            let octaves = max(amount, 1) / 1200
            let alpha = sine * sinh(log(2) / 2 * octaves * angle / sine)
            coefficients = (alpha, 0, -alpha, 1 + alpha, -2 * cosine, 1 - alpha)
        case .highPass:
            let alpha = sine / (2 * max(pow(10, amount / 20), 0.1))
            coefficients = ((1 + cosine) / 2, -(1 + cosine), (1 + cosine) / 2, 1 + alpha, -2 * cosine, 1 - alpha)
        default:
            let alpha = sine / (2 * max(pow(10, amount / 20), 0.1))
            coefficients = ((1 - cosine) / 2, 1 - cosine, (1 - cosine) / 2, 1 + alpha, -2 * cosine, 1 - alpha)
        }
        return frequencies.map { frequency in
            let w = 2 * Double.pi * min(frequency, rate / 2) / rate
            let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
            let c = coefficients
            let numerator = pow(c.b0 + c.b1 * c1 + c.b2 * c2, 2) + pow(c.b1 * s1 + c.b2 * s2, 2)
            let denominator = pow(c.a0 + c.a1 * c1 + c.a2 * c2, 2) + pow(c.a1 * s1 + c.a2 * s2, 2)
            return 10 * log10(max(numerator, 1e-12) / max(denominator, 1e-12))
        }
    }
}
