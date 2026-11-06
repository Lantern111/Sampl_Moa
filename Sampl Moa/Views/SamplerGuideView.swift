import SwiftUI

/// A short walk through the sampler. Shown the first time it's opened, and from the question mark in its panel.
struct SamplerGuideView: View {
    private struct Step {
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        let systemImage: String
        var asksForAccess = false
        var showsShortcuts = false
    }

    private static let steps = [
        Step(
            title: "Allow Access First",
            detail: "Plug-ins often keep their presets in your Documents and Music folders, and macOS asks about each folder once. Allow them now and you won’t be interrupted while you play.",
            systemImage: "checkmark.shield",
            asksForAccess: true
        ),
        Step(
            title: "Put Sounds on the Pads",
            detail: "Drag samples from the list onto a pad. Drag several at once and they fill the next pads too. You can also select samples and click an empty pad.",
            systemImage: "square.grid.4x3.fill"
        ),
        Step(
            title: "Play from Your Device",
            detail: "Connect any MIDI controller and it’s ready to play. On an MPK mini, bank A is the bottom two rows of pads here, and bank B is the top two. For other devices, use the gear button to teach it your pads and knobs. Each device’s setup is remembered.",
            systemImage: "pianokeys"
        ),
        Step(
            title: "Choose the Part That Plays",
            detail: "The pad you hit opens on the right, and a line shows the point you’re hearing. Drag the flags to choose the part that plays. Scroll to zoom, and drag the bar below the waveform to move along.",
            systemImage: "waveform"
        ),
        Step(
            title: "Mix Like in Logic Pro",
            detail: "Down the side of the window, like the inspector in Logic Pro, are the selected sound’s channel strip and the Master’s. The Master shapes everything together without touching each pad’s balance. Click Device Knobs on a strip to turn it with your device’s knobs. Double-click any control to put it back.",
            systemImage: "slider.vertical.3"
        ),
        Step(
            title: "Chop a Loop or a Song",
            detail: "Put a drum loop or a whole song on a pad and press Chop. Lines mark the slices. Click a slice to hear it, drag a line to move it, and double-click to add or remove one. Then choose Put on Pads.",
            systemImage: "scissors"
        ),
        Step(
            title: "Play It on the Keys",
            detail: "Drop a sample on Keyboard and every key plays it in tune. Keep Length holds the notes of a chord together. Repitch changes speed with pitch, like speeding up a record.",
            systemImage: "music.note"
        ),
        Step(
            title: "Add Effects",
            detail: "Under Audio FX on a strip, choose a built-in effect like reverb, delay, or a filter, or the Audio Units you use in Logic Pro. On a pad’s strip they change that pad. On the Master they change everything.",
            systemImage: "puzzlepiece.extension"
        ),
        Step(
            title: "Record a Beat",
            detail: "Press record or R, wait for the four clicks, and play. The loop keeps going, so you can add more each time around. Undo takes back the last pass.",
            systemImage: "record.circle"
        ),
        Step(
            title: "Keyboard Shortcuts",
            detail: "These work while the sampler is open, except when you’re typing in a field.",
            systemImage: "keyboard",
            showsShortcuts: true
        ),
        Step(
            title: "Carry On in Your DAW",
            detail: "Press Send to DAW for the whole beat, each pad separately, or just the notes. Drag the files into Logic Pro or any other DAW.",
            systemImage: "square.and.arrow.up"
        ),
    ]

    let onAskForAccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stepIndex = 0
    @State private var didAskForAccess = false

    private var step: Step { Self.steps[stepIndex] }

    /// Two columns, so all of them fit on one page.
    private var shortcutList: some View {
        let rows: [(key: String, title: LocalizedStringKey)] = SamplerShortcut.allCases.map { ($0.key, $0.title) }
            + [(String(localized: "Space"), "Preview Sample")]
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { index in
                GridRow {
                    shortcutCell(rows[index])
                    if index + 1 < rows.count {
                        shortcutCell(rows[index + 1])
                    }
                }
            }
        }
    }

    private func shortcutCell(_ row: (key: String, title: LocalizedStringKey)) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: row.key)
                .font(.callout.weight(.semibold))
                .frame(minWidth: 52)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: .rect(cornerRadius: 5))
            Text(row.title)
                .foregroundStyle(.secondary)
        }
        .frame(width: 190, alignment: .leading)
    }
    private var isLastStep: Bool { stepIndex == Self.steps.count - 1 }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: step.systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .frame(height: 56)

            VStack(spacing: 8) {
                Text(step.title)
                    .font(.title2.bold())
                Text(step.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if step.showsShortcuts {
                    shortcutList
                        .padding(.top, 6)
                }

                if step.asksForAccess {
                    Button(didAskForAccess ? "Asked" : "Allow Access") {
                        didAskForAccess = true
                        onAskForAccess()
                    }
                    .disabled(didAskForAccess)
                    .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxHeight: .infinity, alignment: .top)

            Text(verbatim: "\(stepIndex + 1) / \(Self.steps.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack {
                Button("Skip") { dismiss() }
                    .opacity(isLastStep ? 0 : 1)
                    .disabled(isLastStep)

                Spacer()

                if stepIndex > 0 {
                    Button("Back") { stepIndex -= 1 }
                }

                Button {
                    if isLastStep {
                        dismiss()
                    } else {
                        stepIndex += 1
                    }
                } label: {
                    Text(isLastStep ? "Done" : "Next")
                        .frame(minWidth: 60)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480, height: 370)
    }
}
