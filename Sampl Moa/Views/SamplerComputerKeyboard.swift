import AppKit

/// Playing the sampler from the Mac's own keyboard, for when there's no device to hand. The left hand's keys sit the
/// same way as the pads on screen, as on an MPC. The right hand's are a piano's, the way Logic Pro's Musical Typing
/// lays them out: G is C, and the row above has the sharps.
enum SamplerComputerKeyboard {
    /// Keys by where they are on the keyboard, so they work the same with a Korean or any other input source.
    /// In pad order: Z X C V are pads 1 to 4, then A S D F, Q W E R, and 1 2 3 4 for pads 13 to 16.
    static let padKeys: [(keyCode: UInt16, label: String)] = [
        (6, "Z"), (7, "X"), (8, "C"), (9, "V"),
        (0, "A"), (1, "S"), (2, "D"), (3, "F"),
        (12, "Q"), (13, "W"), (14, "E"), (15, "R"),
        (18, "1"), (19, "2"), (20, "3"), (21, "4"),
    ]

    static let noteKeys: [(keyCode: UInt16, label: String, semitone: Int)] = [
        (5, "G", 0), (16, "Y", 1), (4, "H", 2), (32, "U", 3), (38, "J", 4), (40, "K", 5),
        (31, "O", 6), (37, "L", 7), (35, "P", 8), (41, ";", 9), (33, "[", 10), (39, "'", 11),
    ]

    private static let octaveDownKey: UInt16 = 27
    private static let octaveUpKey: UInt16 = 24

    /// The key for a pad in any bank, since each bank's pads sit in the same places.
    static func label(forPad pad: Int) -> String {
        let place = pad % SamplerSlot.padsPerBank
        return padKeys.indices.contains(place) ? padKeys[place].label : ""
    }

    /// Whether the key played something, or let go of something it played.
    static func handle(_ event: NSEvent, in sampler: SamplerStore) -> Bool {
        // Letting go always counts, even if a field has taken the focus since, so nothing is left ringing.
        if event.type == .keyUp { return sampler.computerKeyUp(event.keyCode) }

        guard event.type == .keyDown,
              sampler.isOpen,
              sampler.playsFromComputerKeyboard,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
              !(event.window?.firstResponder is NSText)
        else { return false }

        if event.keyCode == octaveDownKey || event.keyCode == octaveUpKey {
            if !event.isARepeat { sampler.shiftComputerKeyboardOctave(by: event.keyCode == octaveUpKey ? 1 : -1) }
            return true
        }

        let target: (slot: Int, note: Int?)
        if let pad = padKeys.firstIndex(where: { $0.keyCode == event.keyCode }) {
            // The bank on screen, the same as a device's pads.
            target = (SamplerSlot.pads(inBank: sampler.bank).lowerBound + pad, nil)
        } else if let key = noteKeys.first(where: { $0.keyCode == event.keyCode }) {
            target = (SamplerSlot.keyboardIndex, sampler.computerKeyboardNote(semitone: key.semitone))
        } else {
            return false
        }

        // Holding a key down repeats it, which would sound like a drum roll.
        if !event.isARepeat { sampler.computerKeyDown(event.keyCode, slot: target.slot, note: target.note) }
        return true
    }
}
