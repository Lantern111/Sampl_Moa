import AVFoundation
import Accelerate
import Foundation

/// A sound held in memory, ready to start the moment a pad is hit. Never changes once it's made.
nonisolated final class SamplerAudio: @unchecked Sendable {
    /// About 20 minutes of stereo at 48 kHz, which takes up close to half a gigabyte.
    private static let longestFile: AVAudioFramePosition = 60_000_000

    enum LoadError: Error {
        case tooLong, unreadable
    }

    private let buffer: AVAudioPCMBuffer

    private init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    var frameCount: Int { Int(buffer.frameLength) }
    var sampleRate: Double { buffer.format.sampleRate }
    var duration: TimeInterval { Double(frameCount) / sampleRate }
    var left: UnsafePointer<Float> { UnsafePointer(buffer.floatChannelData![0]) }
    /// The same as `left` for a mono file.
    var right: UnsafePointer<Float> {
        UnsafePointer(buffer.floatChannelData![buffer.format.channelCount > 1 ? 1 : 0])
    }

    static func load(_ url: URL) throws -> SamplerAudio {
        let file = try AVAudioFile(forReading: url)
        guard file.length <= longestFile else { throw LoadError.tooLong }
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw LoadError.unreadable }

        try file.read(into: buffer)
        guard buffer.frameLength > 0, buffer.floatChannelData != nil else { throw LoadError.unreadable }
        return SamplerAudio(buffer: buffer)
    }

    @concurrent static func loadInBackground(_ url: URL) async throws -> SamplerAudio {
        try load(url)
    }

    @concurrent func stretchedInBackground(from startFrame: Int, to endFrame: Int, speed: Double, pitchCents: Double = 0) async throws -> SamplerAudio {
        try stretched(from: startFrame, to: endFrame, speed: speed, pitchCents: pitchCents)
    }

    /// `start` and `end` are fractions of the whole sound.
    @concurrent func peaksInBackground(from start: Double, to end: Double, count: Int) async -> [Float] {
        peaks(from: Int(start * Double(frameCount)), to: Int(end * Double(frameCount)), count: count)
    }

    /// Plays a part of this sound at another speed or pitch, each without changing the other. Done ahead of time,
    /// because it sounds cleaner this way and leaves nothing for a pad hit to wait for.
    func stretched(from startFrame: Int, to endFrame: Int, speed: Double, pitchCents: Double = 0) throws -> SamplerAudio {
        let frames = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = input.floatChannelData
        else { throw LoadError.unreadable }

        input.frameLength = frames
        channels[0].update(from: left + startFrame, count: Int(frames))
        channels[1].update(from: right + startFrame, count: Int(frames))

        // This mode comes first, because asking for the mixer in any other mode opens the Mac's audio output, which has
        // nothing to do with this work and can hang for as long as the output takes to answer.
        let engine = AVAudioEngine()
        let chunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)

        let player = AVAudioPlayerNode()
        let stretcher = AVAudioUnitTimePitch()
        stretcher.rate = Float(speed)
        stretcher.pitch = Float(pitchCents)
        engine.attach(player)
        engine.attach(stretcher)
        engine.connect(player, to: stretcher, format: format)
        engine.connect(stretcher, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer {
            player.stop()
            engine.stop()
        }
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        // The stretcher starts late by a fixed amount, which would otherwise leave a gap at the start of every hit.
        let lead = Int((stretcher.latency * sampleRate).rounded())
        let wanted = Int((Double(frames) / speed).rounded())
        guard let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(lead + wanted) + chunk),
              let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk)
        else { throw LoadError.unreadable }

        while Int(rendered.frameLength) < lead + wanted {
            if Task.isCancelled { throw CancellationError() }
            let status = try engine.renderOffline(chunk, to: scratch)
            guard status == .success, scratch.frameLength > 0, let from = scratch.floatChannelData, let to = rendered.floatChannelData else {
                throw LoadError.unreadable
            }
            let offset = Int(rendered.frameLength)
            let count = Int(scratch.frameLength)
            to[0].advanced(by: offset).update(from: from[0], count: count)
            to[1].advanced(by: offset).update(from: from[1], count: count)
            rendered.frameLength += scratch.frameLength
        }

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted)),
              let finished = output.floatChannelData, let source = rendered.floatChannelData
        else { throw LoadError.unreadable }
        output.frameLength = AVAudioFrameCount(wanted)
        finished[0].update(from: source[0] + lead, count: wanted)
        finished[1].update(from: source[1] + lead, count: wanted)
        return SamplerAudio(buffer: output)
    }

    /// The loudest point in each of `count` equal parts of a range, as values from 0 to 1.
    func peaks(from startFrame: Int, to endFrame: Int, count: Int) -> [Float] {
        let start = min(max(startFrame, 0), frameCount)
        let length = min(max(endFrame, 0), frameCount) - start
        guard length > 0, count > 0 else { return [] }

        var peaks = (0..<count).map { part -> Float in
            let from = start + part * length / count
            let frames = vDSP_Length(max(1, start + (part + 1) * length / count - from))
            guard from < frameCount else { return 0 }
            var leftPeak: Float = 0
            var rightPeak: Float = 0
            vDSP_maxmgv(left + from, 1, &leftPeak, min(frames, vDSP_Length(frameCount - from)))
            vDSP_maxmgv(right + from, 1, &rightPeak, min(frames, vDSP_Length(frameCount - from)))
            return max(leftPeak, rightPeak)
        }
        if let loudest = peaks.max(), loudest > 0 {
            peaks = peaks.map { $0 / loudest }
        }
        return peaks
    }
}
