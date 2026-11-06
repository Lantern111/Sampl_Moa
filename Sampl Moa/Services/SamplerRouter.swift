import Foundation
import os

/// Decides what each incoming MIDI message does. Runs on the MIDI thread, straight on to the mixer, so a busy screen
/// can never delay a hit.
nonisolated final class SamplerRouter: @unchecked Sendable {
    enum Learning: Sendable {
        case nothing, pads, knobs
    }

    private struct State {
        /// The pad each channel and note plays, or -1 for the keyboard's sound.
        var pads = [Int](repeating: -1, count: 16 * 128)
        /// The knob each controller number turns, or -1.
        var knobs = [Int](repeating: -1, count: 128)
        /// What each controller last sent, or -1 if it hasn't been heard from.
        var lastControllerValues = [Int](repeating: -1, count: 128)
        var isEnabled = false
        var learning = Learning.nothing
        var isSustainDown = false
        var sustainedNotes: Set<Int> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let mixer: SamplerMixer
    private let onHit: @Sendable (Int) -> Void
    private let onKnob: @Sendable (SamplerKnob, Int, Int) -> Void
    private let onLearnPad: @Sendable (SamplerPadBinding) -> Void
    private let onLearnKnob: @Sendable (Int) -> Void

    /// All of these run on the MIDI thread. `onKnob` gets the value a knob moved from and the value it moved to.
    init(
        mixer: SamplerMixer,
        onHit: @escaping @Sendable (Int) -> Void,
        onKnob: @escaping @Sendable (SamplerKnob, Int, Int) -> Void,
        onLearnPad: @escaping @Sendable (SamplerPadBinding) -> Void,
        onLearnKnob: @escaping @Sendable (Int) -> Void
    ) {
        self.mixer = mixer
        self.onHit = onHit
        self.onKnob = onKnob
        self.onLearnPad = onLearnPad
        self.onLearnKnob = onLearnKnob
    }

    func setPadBindings(_ bindings: [SamplerPadBinding]) {
        state.withLock { state in
            state.pads = [Int](repeating: -1, count: 16 * 128)
            for (pad, binding) in bindings.enumerated() {
                state.pads[Self.key(channel: binding.channel, note: binding.note)] = pad
            }
        }
    }

    func setKnobControllers(_ controllers: [Int]) {
        state.withLock { state in
            state.knobs = [Int](repeating: -1, count: 128)
            for (knob, controller) in controllers.enumerated() {
                state.knobs[controller] = knob
            }
        }
    }

    /// Other apps get the same MIDI messages. While this is off, playing a device in Logic Pro won't also play the
    /// sampler. Letting go of a note still works, so nothing is left ringing.
    func setEnabled(_ isEnabled: Bool) {
        state.withLock { $0.isEnabled = isEnabled }
    }

    func setLearning(_ learning: Learning) {
        state.withLock { $0.learning = learning }
    }

    func handle(_ event: MIDIInput.Event) {
        switch event {
        case .noteOn(let channel, let note, let velocity):
            handleNoteOn(channel: channel, note: note, velocity: velocity)

        case .noteOff(let channel, let note):
            let pad = state.withLock { $0.pads[Self.key(channel: channel, note: note)] }
            if pad >= 0 {
                mixer.noteOff(slot: pad)
            } else {
                let keepsRinging = state.withLock { state -> Bool in
                    if state.isSustainDown { state.sustainedNotes.insert(note) }
                    return state.isSustainDown
                }
                if !keepsRinging { mixer.noteOff(slot: SamplerSlot.keyboardIndex, note: note) }
            }

        case .sustain(let isDown):
            let released = state.withLock { state -> Set<Int> in
                state.isSustainDown = isDown
                guard !isDown else { return [] }
                defer { state.sustainedNotes = [] }
                return state.sustainedNotes
            }
            for note in released {
                mixer.noteOff(slot: SamplerSlot.keyboardIndex, note: note)
            }

        case .pitchBend(let value):
            mixer.setPitchBend(value: value)

        case .controlChange(let controller, let value):
            handleController(controller, value: value)
        }
    }

    private func handleNoteOn(channel: Int, note: Int, velocity: Int) {
        let target = state.withLock { state -> (pad: Int, learning: Learning)? in
            guard state.isEnabled else { return nil }
            return (state.pads[Self.key(channel: channel, note: note)], state.learning)
        }
        guard let target else { return }

        if target.learning == .pads {
            onLearnPad(SamplerPadBinding(channel: channel, note: note))
        } else if target.pad >= 0 {
            if mixer.noteOn(slot: target.pad, velocity: velocity) { onHit(target.pad) }
        } else {
            state.withLock { _ = $0.sustainedNotes.remove(note) }
            if mixer.noteOn(slot: SamplerSlot.keyboardIndex, velocity: velocity, note: note) {
                onHit(SamplerSlot.keyboardIndex)
            }
        }
    }

    private func handleController(_ controller: Int, value: Int) {
        enum Action {
            case none, learn
            case turn(SamplerKnob, from: Int)
        }

        let action = state.withLock { state -> Action in
            let last = state.lastControllerValues[controller]
            state.lastControllerValues[controller] = value

            if state.learning == .knobs { return .learn }
            guard state.isEnabled, last >= 0, let knob = SamplerKnob(rawValue: state.knobs[controller]) else { return .none }
            return .turn(knob, from: last)
        }

        switch action {
        case .none: break
        case .learn: onLearnKnob(controller)
        case .turn(let knob, let from): onKnob(knob, from, value)
        }
    }

    private static func key(channel: Int, note: Int) -> Int {
        channel * 128 + note
    }
}
