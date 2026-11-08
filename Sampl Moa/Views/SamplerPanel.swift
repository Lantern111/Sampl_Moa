import AppKit
import SwiftUI

/// The sampler, docked under the sample list: the recorder along the top, then the pads, and beside them the selected
/// sound. Its channel strips are in the inspector at the side of the window.
struct SamplerPanel: View {
    static let height: CGFloat = 436

    @Bindable var sampler: SamplerStore
    /// What's selected in the sample list, so that clicking an empty pad can fill it.
    let selectedSamples: [Sample]

    var body: some View {
        VStack(spacing: 8) {
            SamplerTransportBar(sampler: sampler, sequencer: sampler.sequencer)
            Divider()

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    deviceRow
                    notices
                    padGrid
                    SamplerKeyboardRow(sampler: sampler, selectedSamples: selectedSamples)
                }
                .frame(width: 300)
                .frame(maxHeight: .infinity, alignment: .top)

                Divider()

                SamplerEditor(sampler: sampler, slotIndex: sampler.selectedSlot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(12)
        .frame(height: Self.height)
        .background(.background)
        .onHover { if $0 { sampler.wakeAudio() } }
        .sheet(isPresented: Binding(
            get: { sampler.showsGuide },
            set: { if !$0 { sampler.guideWasClosed() } }
        )) {
            SamplerGuideView(onAskForAccess: sampler.askForFolderAccess)
        }
    }

    /// Playing a pad means the hands have left the search field, so the sampler's keys should work again.
    static func stopTyping() {
        guard let window = NSApp.keyWindow, window.firstResponder is NSText else { return }
        window.makeFirstResponder(nil)
    }

    private var deviceRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sampler.devices.isEmpty ? Color.secondary.opacity(0.4) : Color.green)
                .frame(width: 8, height: 8)
            Text(verbatim: sampler.devices.isEmpty ? String(localized: "No MIDI Device") : sampler.devices.formatted(.list(type: .and)))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)

            Toggle(isOn: $sampler.playsFromComputerKeyboard) {
                Label("Mac Keyboard", systemImage: "keyboard")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Play the pads and keys from your Mac’s keyboard. Each pad shows its key.")
            .onChange(of: sampler.playsFromComputerKeyboard) {
                if sampler.playsFromComputerKeyboard { Self.stopTyping() }
            }

            Menu {
                Button("Map Pads", action: sampler.startLearningPads)
                Button("Map Knobs", action: sampler.startLearningKnobs)
                Divider()
                Button("Reset Mapping", action: sampler.useStandardDeviceLayout)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("MIDI mapping for your device’s pads and knobs. Each device’s mapping is remembered.")
            .accessibilityLabel(Text("MIDI Mapping"))

            Button {
                sampler.showsGuide = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("How to Use the Sampler")
            .accessibilityLabel(Text("How to Use the Sampler"))
        }
    }

    /// Only ever one line, and only when there's something to say.
    @ViewBuilder
    private var notices: some View {
        if let learning = sampler.learning {
            HStack(spacing: 8) {
                Group {
                    switch learning {
                    case .pad(let pad):
                        Text("Now hit the pad on your device for pad \(pad + 1).")
                    case .knob(let knob):
                        Text("Now turn the knob on your device for \(knob.title).")
                    }
                }
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Done", action: sampler.finishLearning)
                    .controlSize(.small)
            }
            .font(.callout)
        } else if let device = sampler.unfamiliarDevice {
            VStack(alignment: .leading, spacing: 4) {
                Text("Teach \(device) its pads and knobs?")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Pads", action: sampler.startLearningPads)
                    Button("Knobs", action: sampler.startLearningKnobs)
                    Button("Not Now", action: sampler.dismissUnfamiliarDevice)
                }
                .controlSize(.small)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if sampler.isWaitingForAudio {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your Mac’s audio output…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .help("If this doesn’t go away, try reconnecting your audio interface or choosing another output in System Settings.")
        } else if sampler.couldNotOpenAudio {
            Label("Couldn’t open your Mac’s audio output.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if sampler.playsFromComputerKeyboard {
            Text("Hold Shift for shortcuts: ⇧R record, ⇧K click, ⇧C chop. − and = change the octave.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Pad 1 sits at the bottom left and pad 16 at the top right, the same as on hardware. On a device with 8 pads
    /// and two banks, bank A is the bottom half of this grid and bank B is the top half.
    private var padGrid: some View {
        Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach([12, 8, 4, 0], id: \.self) { firstPad in
                GridRow {
                    ForEach(firstPad..<(firstPad + 4), id: \.self) { pad in
                        SamplerPad(
                            sampler: sampler,
                            index: pad,
                            state: sampler.padStates[pad],
                            selectedSamples: selectedSamples
                        )
                    }
                }
            }
        }
    }
}

/// One pad, which shows its sound's outline and name, flashes when it's played, and fills as the sound plays.
private struct SamplerPad: View {
    let sampler: SamplerStore
    let index: Int
    let state: SamplerPadState
    let selectedSamples: [Sample]

    @State private var flash = 0.0
    @State private var isPressed = false
    @State private var isDropTarget = false

    private var isLearningHere: Bool { sampler.learning == .pad(index) }
    private var isSelected: Bool { sampler.selectedSlot == index }
    private var slot: SamplerSlot { sampler.slots[index] }

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(fill)
            .overlay {
                SamplerPadOutline(state: state)
                    .padding(.horizontal, 6)
                    .padding(.top, 16)
                    .padding(.bottom, 17)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(flash * 0.7))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: isSelected || isDropTarget || isLearningHere ? 2 : 0.5)
            }
            .overlay(alignment: .topLeading) {
                Text(verbatim: "\(index + 1)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if state.isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(3)
                } else if sampler.playsFromComputerKeyboard {
                    SamplerKeyCap(label: SamplerComputerKeyboard.label(forPad: index))
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) { label.padding(.horizontal, 4).padding(.bottom, 3) }
            .frame(minHeight: 44, maxHeight: 68)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .gesture(pressGesture)
            .contextMenu { menu }
            .dropDestination(for: URL.self) { urls, _ in
                sampler.assign(urls, toSlot: index)
                return true
            } isTargeted: { isDropTarget = $0 }
            .onChange(of: state.hits) {
                flash = 1
                withAnimation(.easeOut(duration: 0.28)) { flash = 0 }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Pad \(index + 1)"))
            .accessibilityValue(Text(verbatim: slot.name))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                sampler.press(index)
                sampler.release(index)
            }
    }

    private var fill: Color {
        slot.path == nil ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.14)
    }

    private var borderColor: Color {
        if isLearningHere { return .orange }
        if isSelected || isDropTarget { return .accentColor }
        return Color.secondary.opacity(0.25)
    }

    @ViewBuilder
    private var label: some View {
        switch state.status {
        case .empty:
            EmptyView()
        case .loading:
            ProgressView().controlSize(.mini)
        case .downloading:
            Image(systemName: "icloud.and.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Downloading from iCloud…")
        case .unavailable:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("This file can’t be played.")
        case .ready:
            Text(verbatim: slot.name)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(slot.name)
        }
    }

    /// Goes down on touch rather than on release, because that's when a pad should sound.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                SamplerPanel.stopTyping()
                if slot.path == nil, !selectedSamples.isEmpty {
                    sampler.assign(selectedSamples.map(\.url), toSlot: index)
                } else {
                    sampler.press(index)
                }
            }
            .onEnded { _ in
                isPressed = false
                sampler.release(index)
            }
    }

    @ViewBuilder
    private var menu: some View {
        if slot.path != nil {
            Button("Play on Keyboard") { sampler.copyToKeyboard(index) }
            Divider()
            Button("Remove from Pad") { sampler.clear(index) }
        }
    }
}

/// Split out of the pad, so that only this part redraws as the sound plays.
private struct SamplerPadOutline: View {
    let state: SamplerPadState

    var body: some View {
        Canvas { context, size in
            let count = state.peaks.count
            guard count > 0 else { return }
            let step = size.width / CGFloat(count)
            let progress = state.progress

            for (index, peak) in state.peaks.enumerated() {
                let height = max(1, CGFloat(peak) * size.height)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1, step - 0.5), height: height)
                let isPlayed = progress.map { Double(index) / Double(count) <= $0 } ?? false
                context.fill(Path(rect), with: .color(isPlayed ? Color.accentColor : Color.secondary.opacity(0.45)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The sound the keyboard plays, shown as a wide bar under the pads.
private struct SamplerKeyboardRow: View {
    let sampler: SamplerStore
    let selectedSamples: [Sample]

    @State private var flash = 0.0
    @State private var isPressed = false
    @State private var isDropTarget = false

    private let index = SamplerSlot.keyboardIndex

    private var slot: SamplerSlot { sampler.slots[index] }
    private var state: SamplerPadState { sampler.padStates[index] }
    private var isSelected: Bool { sampler.selectedSlot == index }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pianokeys")
                .foregroundStyle(.secondary)

            Text("Keyboard")
                .font(.callout.weight(.medium))
            Text(verbatim: slot.path == nil ? String(localized: "Drop a sample here to play it on the keys") : slot.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            switch state.status {
            case .loading:
                ProgressView().controlSize(.mini)
            case .downloading:
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary)
            case .unavailable:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            case .ready:
                if sampler.isPreparingKeys {
                    ProgressView().controlSize(.mini)
                        .help("Getting every key ready to keep the same length…")
                }
                if sampler.playsFromComputerKeyboard {
                    let lowest = SamplerNote.name(of: sampler.computerKeyboardNote(semitone: 0))
                    SamplerKeyCap(label: "G = \(lowest)")
                        .help("G to ' play the keys, starting from \(lowest). − and = change the octave.")
                }
                Text(verbatim: SamplerNote.name(of: slot.rootNote))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("The key that plays this sound at its original pitch.")
            case .empty:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(slot.path == nil ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.14))
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(flash * 0.7))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected || isDropTarget ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: isSelected || isDropTarget ? 2 : 0.5
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    SamplerPanel.stopTyping()
                    if slot.path == nil, let first = selectedSamples.first {
                        sampler.assign([first.url], toSlot: index)
                    } else {
                        sampler.press(index)
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    sampler.release(index)
                }
        )
        .contextMenu {
            if slot.path != nil {
                Button("Remove from Keyboard") { sampler.clear(index) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            sampler.assign(urls, toSlot: index)
            return true
        } isTargeted: { isDropTarget = $0 }
        .onChange(of: state.hits) {
            flash = 1
            withAnimation(.easeOut(duration: 0.28)) { flash = 0 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Which key on the Mac's keyboard plays something, drawn like a key.
private struct SamplerKeyCap: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: .rect(cornerRadius: 3))
            .accessibilityHidden(true)
    }
}
