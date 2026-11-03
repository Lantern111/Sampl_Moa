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
        position = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            position = 0
            stopTimer()
        }
    }
}
