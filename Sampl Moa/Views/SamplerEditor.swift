import SwiftUI

/// The selected pad or the keyboard's sound: its waveform and how it plays. How it's mixed is in the inspector.
struct SamplerEditor: View {
    let sampler: SamplerStore
    let slotIndex: Int

    private var slot: SamplerSlot { sampler.slots[slotIndex] }
    private var isKeyboard: Bool { slotIndex == SamplerSlot.keyboardIndex }
    private var hasSound: Bool { slot.path != nil }

    var body: some View {
        VStack(spacing: 8) {
            if hasSound {
                title
                SamplerWaveformEditor(sampler: sampler, slotIndex: slotIndex)
                    .id("\(slotIndex).\(sampler.editorGeneration)")
                Divider()
                settings
            } else {
                emptyHint
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: isKeyboard ? "pianokeys" : "square.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Drag a sample from the list onto a pad. You can also select samples and click an empty pad.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
    }

    private var title: some View {
        HStack(spacing: 8) {
            Group {
                if isKeyboard {
                    Text("Keyboard")
                } else {
                    Text("Pad \(slotIndex + 1)")
                }
            }
            .font(.headline)

            Text(verbatim: slot.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if sampler.canUndoChop {
                Button("Undo Chop", action: sampler.undoChop)
                    .controlSize(.small)
            }
            if !isKeyboard {
                Button("Send to Keyboard") { sampler.copyToKeyboard(slotIndex) }
                    .controlSize(.small)
                    .help("Plays this sound on the keys too, in tune.")
            }
            Button {
                sampler.beginChop(slotIndex)
            } label: {
                Label("Chop", systemImage: "scissors")
            }
            .controlSize(.small)
            .disabled(sampler.chopSession != nil)
            .help("Mark out slices on the waveform, then put one on each pad (C).")
        }
    }

    /// How the sound itself plays, as opposed to how it's mixed. One row when there's room, otherwise two.
    private var settings: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                playMode
                knobs
                extraSettings
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 18) {
                    playMode
                    knobs
                    Spacer(minLength: 0)
                }
                extraSettings
            }
        }
    }

    private var playMode: some View {
        labeled("Play Mode") {
            Picker("Play Mode", selection: Binding(
                get: { slot.mode },
                set: { sampler.setMode($0, of: slotIndex) }
            )) {
                ForEach(SamplerPlayMode.allCases) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var knobs: some View {
        HStack(spacing: 4) {
            soundKnob(.pitch)
            soundKnob(.speed)
        }
        .frame(width: 104)
    }

    @ViewBuilder
    private var extraSettings: some View {
        if isKeyboard {
            HStack(alignment: .top, spacing: 18) {
                labeled("Keys") {
                    Picker("Keys", selection: Binding(
                        get: { slot.keepsLength },
                        set: { sampler.setKeepsLength($0) }
                    )) {
                        Text("Keep Length").tag(true)
                        Text("Repitch").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Keep Length keeps the notes of a chord together. Repitch changes speed with pitch, like speeding up a record.")
                }

                labeled("Root Note") {
                    Picker("Root Note", selection: Binding(
                        get: { slot.rootNote },
                        set: { sampler.setRootNote($0, of: slotIndex) }
                    )) {
                        ForEach(SamplerNote.middleC..<(SamplerNote.middleC + 12), id: \.self) { note in
                            Text(verbatim: SamplerNote.name(of: note)).tag(note)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("The key that plays this sound at its original pitch.")
                }
            }
        } else {
            labeled("Choke Group") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Picker("Choke Group", selection: Binding(
                        get: { slot.cutGroup },
                        set: { sampler.setCutGroup($0, of: slotIndex) }
                    )) {
                        Text("None").tag(0)
                        ForEach(1...4, id: \.self) { group in
                            Text(verbatim: "\(group)").tag(group)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Text("Pads with the same number silence each other, like a closed hi-hat stopping an open one.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(minWidth: 150, maxWidth: 260, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func labeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func soundKnob(_ knob: SamplerKnob) -> some View {
        SamplerKnobView(
            title: knob.title,
            position: slot.position(of: knob),
            neutral: knob.neutralValue,
            reading: slot.reading(of: knob),
            isBeingLearned: sampler.learning == .knob(knob),
            diameter: 30,
            onChange: { sampler.setKnob(knob, toPosition: $0, of: slotIndex) }
        )
    }
}
