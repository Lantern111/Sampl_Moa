import AppKit
import SwiftUI

/// The sampler's keys, mostly the same as Logic Pro's. They work while the sampler is open, and never while typing in
/// a field. Each also works with Shift, which is how they're reached while the Mac's keyboard is playing the pads.
/// Listed in one place so the guide shows the same ones.
enum SamplerShortcut: CaseIterable, Identifiable {
    case record, playOrStop, stopAll, clickTrack, tapTempo, chop

    var id: Self { self }

    /// Keys by where they are on the keyboard, so they work the same with a Korean or any other input source.
    private var keyCodes: [UInt16] {
        switch self {
        case .record: [15]
        case .playOrStop: [36, 76]
        case .stopAll: [53]
        case .clickTrack: [40]
        case .tapTempo: [17]
        case .chop: [8]
        }
    }

    var key: String {
        switch self {
        case .record: "R"
        case .playOrStop: "↩"
        case .stopAll: "esc"
        case .clickTrack: "K"
        case .tapTempo: "T"
        case .chop: "C"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .record: "Record"
        case .playOrStop: "Play / Stop"
        case .stopAll: "Stop All"
        case .clickTrack: "Click Track"
        case .tapTempo: "Tap Tempo"
        case .chop: "Chop"
        }
    }

    /// Whether the key was one of the sampler's, in which case it's been acted on.
    static func handle(_ event: NSEvent, in sampler: SamplerStore) -> Bool {
        guard sampler.isOpen,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              !(event.window?.firstResponder is NSText),
              let shortcut = allCases.first(where: { $0.keyCodes.contains(event.keyCode) })
        else { return false }

        // While chopping, Return puts the slices on the pads, as that button says.
        if shortcut == .playOrStop, sampler.chopSession != nil { return false }
        if !event.isARepeat { shortcut.perform(in: sampler, at: event.timestamp) }
        return true
    }

    /// `time` is when the key went down, which keeps tapped tempos steady however busy the app is.
    private func perform(in sampler: SamplerStore, at time: TimeInterval) {
        let sequencer = sampler.sequencer
        switch self {
        case .record:
            sequencer.toggleRecording()
            sampler.startFollowingPlayheads()
        case .playOrStop:
            sequencer.togglePlayback()
            sampler.startFollowingPlayheads()
        case .stopAll:
            if sampler.chopSession != nil {
                sampler.cancelChop()
            } else {
                sampler.stopEverything()
            }
        case .clickTrack:
            sequencer.isMetronomeOn.toggle()
        case .tapTempo:
            sequencer.tapTempo(at: time)
        case .chop:
            let index = sampler.selectedSlot
            if sampler.slots[index].path != nil, sampler.chopSession == nil {
                sampler.beginChop(index)
            }
        }
    }
}
