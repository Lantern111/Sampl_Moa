import SwiftUI
import UniformTypeIdentifiers

/// The recorder: record, play, tempo, and getting a beat out to a DAW.
struct SamplerTransportBar: View {
    private static let swingChoices = [0.5, 0.54, 0.58, 0.62, 0.66, 0.7, 0.75]

    let sampler: SamplerStore
    let sequencer: SamplerSequencer

    @State private var showsExport = false

    var body: some View {
        HStack(spacing: 10) {
            transportButtons
            SamplerPositionReadout(sequencer: sequencer)

            Divider().frame(height: 18)

            tempo
            patternOptions

            Spacer(minLength: 6)

            Button(action: sequencer.undoLastTake) {
                Image(systemName: "arrow.uturn.backward")
            }
            .controlSize(.small)
            .disabled(!sequencer.hasNotes)
            .help("Undo: removes everything from the last time you recorded.")
            .accessibilityLabel(Text("Undo"))

            Button(action: sequencer.clear) {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(!sequencer.hasNotes)
            .help("Clear Pattern")
            .accessibilityLabel(Text("Clear"))

            Button {
                showsExport = true
            } label: {
                Label("Send to DAW", systemImage: "square.and.arrow.up")
            }
            .controlSize(.small)
            .disabled(!sequencer.hasNotes)
            .popover(isPresented: $showsExport, arrowEdge: .bottom) {
                SamplerExportView(sampler: sampler)
            }
        }
        .frame(height: 26)
        .font(.callout)
    }

    private var transportButtons: some View {
        HStack(spacing: 4) {
            Button {
                sequencer.toggleRecording()
                sampler.startFollowingPlayheads()
            } label: {
                Image(systemName: "record.circle")
                    .foregroundStyle(sequencer.isRecording ? Color.red : Color.primary)
                    .symbolEffect(.pulse, isActive: sequencer.isRecording)
            }
            .help("Record (R). Starts after four clicks if nothing’s playing. Press again to stop recording and keep playing.")
            .accessibilityLabel(Text("Record"))

            Button {
                sequencer.togglePlayback()
                sampler.startFollowingPlayheads()
            } label: {
                Image(systemName: sequencer.isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 14)
            }
            .help("Play or Stop (Return)")
            .accessibilityLabel(Text(sequencer.isPlaying ? "Stop" : "Play"))
        }
        .controlSize(.small)
    }

    private var tempo: some View {
        HStack(spacing: 4) {
            SamplerNumberField(value: sequencer.pattern.bpm, range: SamplerSequencer.bpmRange) { bpm in
                if let bpm { sequencer.setBPM(bpm) }
            }
            .controlSize(.small)
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
            .accessibilityLabel(Text("Tempo"))

            Stepper("BPM", value: Binding(
                get: { sequencer.pattern.bpm },
                set: { sequencer.setBPM($0) }
            ), in: 30...300)
            .labelsHidden()
            .controlSize(.mini)

            Text(verbatim: "BPM")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()

            Button("Tap") { sequencer.tapTempo() }
                .controlSize(.small)
                .help("Tap along with the beat to set the tempo (T).")
        }
    }

    private var patternOptions: some View {
        HStack(spacing: 6) {
            Picker("Bars", selection: Binding(
                get: { sequencer.pattern.bars },
                set: { sequencer.setBars($0) }
            )) {
                ForEach([1, 2, 4, 8], id: \.self) { bars in
                    Text("\(bars) bars").tag(bars)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("How long the loop is.")

            Picker("Timing", selection: Binding(
                get: { sequencer.pattern.quantize },
                set: { sequencer.setQuantize($0) }
            )) {
                ForEach(SamplerQuantize.allCases) { quantize in
                    Text(verbatim: quantize.title).tag(quantize)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Pulls what you recorded onto the beat. You can change this at any time.")

            Picker("Swing", selection: Binding(
                get: { sequencer.pattern.swing },
                set: { sequencer.setSwing($0) }
            )) {
                ForEach(Self.swingChoices, id: \.self) { swing in
                    Text(verbatim: String(format: "%.0f%%", swing * 100)).tag(swing)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Swing. 50% is straight, and higher makes the offbeats fall later.")

            Toggle(isOn: Binding(
                get: { sequencer.isMetronomeOn },
                set: { sequencer.isMetronomeOn = $0 }
            )) {
                Image(systemName: "metronome")
            }
            .toggleStyle(.button)
            .help("Click track (K). It’s never part of what gets recorded or exported.")
            .accessibilityLabel(Text("Click Track"))
        }
        .controlSize(.small)
    }
}

/// Where the music is, in bars and beats. Kept apart, because it changes many times a second while playing, and
/// redrawing the whole bar that often would also reset what's being typed in the tempo field.
private struct SamplerPositionReadout: View {
    let sequencer: SamplerSequencer

    var body: some View {
        Text(verbatim: sequencer.positionReading)
            .font(.callout.monospacedDigit())
            .foregroundStyle(sequencer.isPlaying ? .primary : .secondary)
            .frame(width: 42, alignment: .leading)
    }
}

/// Choosing what to export, then dragging it out or opening it in a DAW.
private struct SamplerExportView: View {
    let sampler: SamplerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send to DAW")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                exportRow("Whole Beat", detail: "One audio file with all effects.", action: sampler.exportMix)
                exportRow("Each Pad Separately", detail: "One audio file per pad, lined up.", action: sampler.exportStems)
                exportRow("Notes Only", detail: "A MIDI file to play with your own sounds.", action: sampler.exportMIDI)
            }

            if sampler.isExporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Exporting…").foregroundStyle(.secondary)
                }
            } else if sampler.exportFailed {
                Label("Couldn’t export that.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if let result = sampler.exportResult {
                Divider()
                resultView(result)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 330)
    }

    private func exportRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Export", action: action)
                .controlSize(.small)
                .disabled(sampler.isExporting)
        }
    }

    private func resultView(_ result: SamplerStore.ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag into your DAW:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(result.files, id: \.self) { file in
                        Label(file.lastPathComponent, systemImage: file.pathExtension == "mid" ? "pianokeys" : "waveform")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 5))
                            .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)

            HStack(spacing: 6) {
                Button("Show in Finder") { sampler.showInFinder(result.files) }
                    .controlSize(.small)

                let apps = sampler.installedDAWs
                if !apps.isEmpty {
                    Menu("Open In") {
                        ForEach(apps, id: \.name) { app in
                            Button(app.name) { sampler.open(result.files, in: app.url) }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
    }
}
