import AVFoundation
import Accelerate
import Foundation

nonisolated enum Waveform {
    private static let peakCount = 512

    /// Reads a file's loudness outline as values from 0 to 1. Each value is the loudest point in one slice of the file.
    /// Returns nil if the task is cancelled, since people often skip past a sample long before it could finish.
    @concurrent static func readPeaks(of url: URL) async -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }

        let framesPerPeak = AVAudioFrameCount(max(1, file.length / Int64(peakCount)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesPerPeak) else {
            return nil
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(peakCount + 1)
        while file.framePosition < file.length {
            if Task.isCancelled { return nil }

            guard (try? file.read(into: buffer, frameCount: framesPerPeak)) != nil,
                  buffer.frameLength > 0,
                  let channels = buffer.floatChannelData
            else { break }

            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(buffer.frameLength))
                peak = max(peak, channelPeak)
            }
            peaks.append(peak)
        }

        guard let loudest = peaks.max(), loudest > 0 else { return peaks }
        return peaks.map { $0 / loudest }
    }

    /// Shrinks peaks to the number of bars that fit, keeping the loudest value of each group so transients stay visible.
    static func bars(from peaks: [Float], count: Int) -> [Float] {
        guard !peaks.isEmpty, count > 0 else { return [] }
        return (0..<count).map { bar in
            let start = bar * peaks.count / count
            let end = max(start + 1, (bar + 1) * peaks.count / count)
            return peaks[start..<min(end, peaks.count)].max() ?? 0
        }
    }
}

final class WaveformCache {
    static let shared = WaveformCache()

    private final class Peaks {
        let values: [Float]
        init(_ values: [Float]) { self.values = values }
    }

    private let cache: NSCache<NSURL, Peaks> = {
        let cache = NSCache<NSURL, Peaks>()
        cache.countLimit = 3000
        return cache
    }()

    func cachedPeaks(for url: URL) -> [Float]? {
        cache.object(forKey: url as NSURL)?.values
    }

    /// Cancelling the task that called this stops the reading too.
    func peaks(for url: URL) async -> [Float]? {
        if let cached = cachedPeaks(for: url) { return cached }

        let peaks = await Waveform.readPeaks(of: url)
        if let peaks { cache.setObject(Peaks(peaks), forKey: url as NSURL) }
        return peaks
    }
}
