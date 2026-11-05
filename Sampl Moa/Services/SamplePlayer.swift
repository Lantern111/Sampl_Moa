import AVFoundation
import Foundation
import Observation

@Observable
final class SamplePlayer {
    private static let volumeKey = "playerVolume"

    private(set) var sample: Sample?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var peaks: [Float] = []
    private(set) var couldNotPlay = false
    /// True while the sample in the bar is coming down from iCloud, to start playing once it arrives.
    private(set) var isWaitingForDownload = false
    /// True while the user is listening their way through samples. It stays on after a sample ends by itself, which
    /// for a one-shot takes under a second, so the arrow keys keep working. Pausing or closing turns it off.
    private(set) var isAuditioning = false

    var volume: Float = UserDefaults.standard.object(forKey: volumeKey) as? Float ?? 0.8 {
        didSet {
            player?.volume = volume
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var peaksTask: Task<Void, Never>?

    init() {
        Self.warmUpAudio()
    }

    /// The first player in a run of the app has to load the system's audio code, which would otherwise freeze the
    /// window for a moment the first time someone presses Space. This does that ahead of time, without making a sound.
    private static func warmUpAudio() {
        Task.detached(priority: .utility) {
            // One channel of 16-bit silence at 44.1 kHz, 0.1 seconds long.
            let frames = 4410
            var wav = Data("RIFF".utf8)
            func append<Number: FixedWidthInteger>(_ number: Number) {
                withUnsafeBytes(of: number.littleEndian) { wav.append(contentsOf: $0) }
            }
            append(UInt32(36 + frames * 2))
            wav.append(contentsOf: Data("WAVEfmt ".utf8))
            append(UInt32(16))
            append(UInt16(1))
            append(UInt16(1))
            append(UInt32(44100))
            append(UInt32(88200))
            append(UInt16(2))
            append(UInt16(16))
            wav.append(contentsOf: Data("data".utf8))
            append(UInt32(frames * 2))
            wav.append(Data(count: frames * 2))

            _ = (try? AVAudioPlayer(data: wav))?.prepareToPlay()
        }
    }

    /// Fills the bar for a sample that's still downloading, silencing whatever was playing.
    func waitForDownload(of sample: Sample) {
        player?.stop()
        player = nil
        stopTimer()
        peaksTask?.cancel()
        self.sample = sample
        position = 0
        duration = 0
        peaks = []
        couldNotPlay = false
        isPlaying = false
        isWaitingForDownload = true
        isAuditioning = true
    }

    func downloadFailed() {
        isWaitingForDownload = false
        couldNotPlay = true
    }

    func play(_ sample: Sample) {
        self.sample = sample
        isWaitingForDownload = false
        isAuditioning = true
        position = 0
        peaks = WaveformCache.shared.cachedPeaks(for: sample.url) ?? []

        do {
            let player = try AVAudioPlayer(contentsOf: sample.url)
            player.volume = volume
            player.play()
            self.player?.stop()
            self.player = player
            duration = player.duration
            couldNotPlay = false
            isPlaying = true
            startTimer()
        } catch {
            self.player?.stop()
            self.player = nil
            duration = sample.duration ?? 0
            couldNotPlay = true
            isPlaying = false
            stopTimer()
        }

        peaksTask?.cancel()
        peaksTask = Task {
            let loaded = await WaveformCache.shared.peaks(for: sample.url)
            guard !Task.isCancelled else { return }
            peaks = loaded ?? []
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            isAuditioning = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            isAuditioning = true
            startTimer()
        }
    }

    /// Jumps to a point in the sample and plays from there, the way clicking a waveform is expected to work.
    func seek(toFraction fraction: Double) {
        guard let player else { return }
        player.currentTime = min(max(fraction, 0), 1) * player.duration
        position = player.currentTime
        if !player.isPlaying { toggle() }
    }

    func close() {
        peaksTask?.cancel()
        player?.stop()
        player = nil
        stopTimer()
        isPlaying = false
        isAuditioning = false
        isWaitingForDownload = false
        sample = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` keeps the playhead moving while the user scrolls or drags.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        // Every change redraws the waveform, and a long song barely moves between ticks.
        let smallestVisibleStep = min(0.5, player.duration / 400)
        if abs(player.currentTime - position) >= smallestVisibleStep {
            position = player.currentTime
        }
        if !player.isPlaying {
            isPlaying = false
            position = 0
            stopTimer()
        }
    }
}
