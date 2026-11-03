import SwiftUI

struct PlayerBar: View {
    @Bindable var player: SamplePlayer
    let onTogglePlayback: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onTogglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22, height: 22)
            }
            .prominentGlassButton()
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(player.couldNotPlay || player.isWaitingForDownload)
            .help("Play or Pause (Space)")
            .accessibilityLabel(Text(player.isPlaying ? "Pause" : "Play"))

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: player.sample?.name ?? "")
                    .font(.callout.weight(.medium))
                Text(verbatim: player.sample?.collection ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 190, alignment: .leading)

            if player.couldNotPlay {
                Text("This file can’t be previewed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else if player.isWaitingForDownload {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading from iCloud…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            } else {
                PlaybackTimeline(player: player)
            }

            HStack(spacing: 6) {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 72)
                    .accessibilityLabel(Text("Volume"))
            }

            Button(action: player.close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .glassButton()
            .buttonBorderShape(.circle)
            .help("Close Player")
            .accessibilityLabel(Text("Close Player"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingGlass(cornerRadius: 24)
    }
}

/// Split out of `PlayerBar` so that only this part redraws on every tick of the playhead.
private struct PlaybackTimeline: View {
    let player: SamplePlayer

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: formattedLength(player.position.rounded(.down)))
                .frame(width: 32, alignment: .trailing)

            WaveformView(
                peaks: player.peaks,
                progress: player.duration > 0 ? player.position / player.duration : 0,
                onSeek: player.seek(toFraction:)
            )
            .frame(height: 36)

            Text(verbatim: formattedLength(player.duration))
                .frame(width: 32, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// The sample's waveform as a row of mirrored bars. The played part takes the system accent color.
struct WaveformView: View {
    let peaks: [Float]
    let progress: Double
    let onSeek: (Double) -> Void

    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let step = Self.barWidth + Self.barGap
                let count = Int(size.width / step)
                let levels = Waveform.bars(from: peaks, count: count)
                let playedBars = Double(count) * progress

                for bar in 0..<count {
                    let level = bar < levels.count ? CGFloat(levels[bar]) : 0
                    let height = max(2, level * size.height)
                    let rect = CGRect(
                        x: CGFloat(bar) * step,
                        y: (size.height - height) / 2,
                        width: Self.barWidth,
                        height: height
                    )
                    let color = Double(bar) < playedBars ? Color.accentColor : Color.secondary.opacity(0.4)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    onSeek(value.location.x / geometry.size.width)
                }
            )
        }
    }
}
