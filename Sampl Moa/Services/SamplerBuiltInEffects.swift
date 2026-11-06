import AVFoundation

/// Effects that come with every Mac, offered before any other plug-ins and under plain names. Each starts with
/// settings that can be heard straight away: left alone, Apple's reverb is all reverb and its filters barely do anything.
nonisolated struct SamplerBuiltInEffect: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case reverb, delay, lowPass, highPass, bandPass, distortion, compressor, limiter
    }

    let kind: Kind
    let subType: OSType
    let startingSettings: [(AudioUnitParameterID, AudioUnitParameterValue)]

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .reverb: String(localized: "Reverb")
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

    static let all: [SamplerBuiltInEffect] = [
        SamplerBuiltInEffect(kind: .reverb, subType: kAudioUnitSubType_MatrixReverb, startingSettings: [
            (kReverbParam_DryWetMix, 30),
        ]),
        SamplerBuiltInEffect(kind: .delay, subType: kAudioUnitSubType_Delay, startingSettings: [
            (kDelayParam_WetDryMix, 30),
            (kDelayParam_DelayTime, 0.375),
            (kDelayParam_Feedback, 35),
            (kDelayParam_LopassCutoff, 9000),
        ]),
        SamplerBuiltInEffect(kind: .lowPass, subType: kAudioUnitSubType_LowPassFilter, startingSettings: [
            (kLowPassParam_CutoffFrequency, 1200),
            (kLowPassParam_Resonance, 6),
        ]),
        SamplerBuiltInEffect(kind: .highPass, subType: kAudioUnitSubType_HighPassFilter, startingSettings: [
            (kHipassParam_CutoffFrequency, 400),
            (kHipassParam_Resonance, 3),
        ]),
        SamplerBuiltInEffect(kind: .bandPass, subType: kAudioUnitSubType_BandPassFilter, startingSettings: [
            (kBandpassParam_CenterFrequency, 1000),
            (kBandpassParam_Bandwidth, 1200),
        ]),
        SamplerBuiltInEffect(kind: .distortion, subType: kAudioUnitSubType_Distortion, startingSettings: []),
        SamplerBuiltInEffect(kind: .compressor, subType: kAudioUnitSubType_DynamicsProcessor, startingSettings: []),
        SamplerBuiltInEffect(kind: .limiter, subType: kAudioUnitSubType_PeakLimiter, startingSettings: []),
    ]

    /// The built-in effect a plug-in is, if it's one of these.
    static func matching(type: OSType, subType: OSType, manufacturer: OSType) -> SamplerBuiltInEffect? {
        guard type == kAudioUnitType_Effect, manufacturer == kAudioUnitManufacturer_Apple else { return nil }
        return all.first { $0.subType == subType }
    }

    /// Only for one just added. One brought back from a saved kit keeps the settings it was saved with.
    func applyStartingSettings(to unit: AVAudioUnit) {
        // These are Audio Units of the older kind, where a setting's address is its plain parameter ID.
        let settings = unit.auAudioUnit.parameterTree
        for (parameter, value) in startingSettings {
            settings?.parameter(withAddress: AUParameterAddress(parameter))?.value = value
        }
    }
}
