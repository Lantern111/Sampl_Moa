import AppKit
import SwiftUI

/// Tells the parts of the sampler that move with the sound, its meters and playheads, when to look again: about 30
/// times a second while anything is heard, and not at all otherwise.
///
/// Those parts are plain layers that listen here, rather than SwiftUI views that watch the store. Going through SwiftUI
/// made it work the whole window out again for every one of those looks, which kept a processor core busy by a sixth
/// just to play a loop.
@MainActor final class SamplerTicker {
    private var listeners: [ObjectIdentifier: () -> Void] = [:]

    func add(_ listener: AnyObject, _ look: @escaping () -> Void) {
        listeners[ObjectIdentifier(listener)] = look
    }

    func remove(_ listener: AnyObject) {
        listeners[ObjectIdentifier(listener)] = nil
    }

    func tick() {
        for look in listeners.values { look() }
    }
}

/// A view made of layers that redraws itself on the sampler's ticks. Clicks pass through it to whatever it lies over.
class SamplerLiveView: NSView {
    var ticker: SamplerTicker? {
        didSet {
            guard ticker !== oldValue else { return }
            oldValue?.remove(self)
            listenIfShown()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        // Choosing another accent color in System Settings changes the colors these layers were given.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemColorsChanged),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func systemColorsChanged() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            withoutAnimation { recolor() }
        }
    }

    /// Sets the layers from what's being shown now. Called on every tick, and whenever the size or colors change.
    func refresh() {}

    /// Colors that follow light and dark mode and the accent color have to be asked for again when those change.
    func recolor() {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        listenIfShown()
    }

    override func layout() {
        super.layout()
        withoutAnimation { refresh() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            withoutAnimation { recolor() }
        }
    }

    private func listenIfShown() {
        guard let ticker else { return }
        if window == nil {
            ticker.remove(self)
        } else {
            ticker.add(self) { [weak self] in
                guard let self else { return }
                self.withoutAnimation { self.refresh() }
            }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                withoutAnimation {
                    recolor()
                    refresh()
                }
            }
        }
    }

    /// Layers ease to new places by default, which would smear a meter.
    func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

// MARK: - Meters

/// A strip's two meters, left and right. Green up to -12 dB, yellow up to 0 dB, and red above, where it's about to
/// clip, on the fader's scale.
struct SamplerLevelBars: NSViewRepresentable {
    let ticker: SamplerTicker
    let level: () -> SamplerLevel

    func makeNSView(context: Context) -> Bars { Bars() }

    func updateNSView(_ bars: Bars, context: Context) {
        bars.level = level
        bars.ticker = ticker
    }

    static func dismantleNSView(_ bars: Bars, coordinator: ()) {
        bars.ticker = nil
    }

    final class Bars: SamplerLiveView {
        private static let yellowFrom = SamplerFaderScale.position(of: Float(pow(10, -12.0 / 20)))
        private static let redFrom = SamplerFaderScale.unityPosition
        private static let gap: CGFloat = 2

        var level: () -> SamplerLevel = { .silent }
        private var shown = SamplerLevel(left: -1, right: -1)
        private var shownSize = CGSize.zero

        /// For each side: the track, then what's lit of the green, yellow and red parts.
        private let sides: [(track: CALayer, green: CALayer, yellow: CALayer, red: CALayer)] = (0..<2).map { _ in
            (CALayer(), CALayer(), CALayer(), CALayer())
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            for side in sides {
                side.track.cornerRadius = 2
                side.track.masksToBounds = true
                layer?.addSublayer(side.track)
                for part in [side.green, side.yellow, side.red] { side.track.addSublayer(part) }
            }
            setAccessibilityElement(false)
        }

        override func recolor() {
            for side in sides {
                side.track.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18).cgColor
                side.green.backgroundColor = NSColor.systemGreen.cgColor
                side.yellow.backgroundColor = NSColor.systemYellow.cgColor
                side.red.backgroundColor = NSColor.systemRed.cgColor
            }
        }

        override func refresh() {
            let now = level()
            guard now != shown || bounds.size != shownSize else { return }
            shown = now
            shownSize = bounds.size

            let width = max(0, (bounds.width - Self.gap) / 2)
            let height = bounds.height
            for (index, side) in sides.enumerated() {
                side.track.frame = CGRect(x: CGFloat(index) * (width + Self.gap), y: 0, width: width, height: height)
                let reach = SamplerFaderScale.position(of: index == 0 ? now.left : now.right)
                Self.light(side.green, from: 0, to: min(reach, Self.yellowFrom), width: width, height: height)
                Self.light(side.yellow, from: Self.yellowFrom, to: min(reach, Self.redFrom), width: width, height: height)
                Self.light(side.red, from: Self.redFrom, to: reach, width: width, height: height)
            }
        }

        private static func light(_ part: CALayer, from: Double, to: Double, width: CGFloat, height: CGFloat) {
            let bottom = CGFloat(from) * height
            part.frame = CGRect(x: 0, y: bottom, width: width, height: max(0, CGFloat(to) * height - bottom))
        }
    }
}

// MARK: - A pad's outline

/// The outline of a pad's sound, which fills with the accent color as the sound plays.
struct SamplerPadWave: NSViewRepresentable {
    let ticker: SamplerTicker
    let peaks: [Float]
    /// How far through the sound has got, from 0 to 1, or nil when it's silent.
    let progress: () -> Double?

    func makeNSView(context: Context) -> Wave { Wave() }

    func updateNSView(_ wave: Wave, context: Context) {
        wave.progress = progress
        wave.peaks = peaks
        wave.ticker = ticker
    }

    static func dismantleNSView(_ wave: Wave, coordinator: ()) {
        wave.ticker = nil
    }

    final class Wave: SamplerLiveView {
        var progress: () -> Double? = { nil }
        var peaks: [Float] = [] {
            didSet {
                guard peaks != oldValue else { return }
                drawnSize = .zero
                needsLayout = true
            }
        }

        private let outline = CAShapeLayer()
        private let played = CAShapeLayer()
        private let playedPart = CALayer()
        private var drawnSize = CGSize.zero
        private var shown: Double? = -1

        override init(frame: NSRect) {
            super.init(frame: frame)
            playedPart.backgroundColor = NSColor.black.cgColor
            played.mask = playedPart
            layer?.addSublayer(outline)
            layer?.addSublayer(played)
            setAccessibilityElement(false)
        }

        override func recolor() {
            outline.fillColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor
            played.fillColor = NSColor.controlAccentColor.cgColor
        }

        override func refresh() {
            if bounds.size != drawnSize {
                drawnSize = bounds.size
                let path = Self.path(of: peaks, in: bounds.size)
                outline.frame = bounds
                played.frame = bounds
                outline.path = path
                played.path = path
                shown = -1
            }
            let now = progress()
            guard now != shown else { return }
            shown = now
            playedPart.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(min(max(now ?? 0, 0), 1)), height: bounds.height)
        }

        private static func path(of peaks: [Float], in size: CGSize) -> CGPath {
            let path = CGMutablePath()
            guard !peaks.isEmpty, size.width > 0 else { return path }
            let step = size.width / CGFloat(peaks.count)
            for (index, peak) in peaks.enumerated() {
                let height = max(1, CGFloat(peak) * size.height)
                path.addRect(CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1, step - 0.5), height: height))
            }
            return path
        }
    }
}

// MARK: - The waveform's playhead

/// The line that crosses the waveform as its sound plays.
struct SamplerPlayheadLine: NSViewRepresentable {
    let ticker: SamplerTicker
    /// How far through the sound has got, from 0 to 1, or nil when it's silent.
    let progress: () -> Double?
    /// The part of the file that plays, and the part of it on screen, as fractions of the whole file.
    let start: Double
    let end: Double
    let visible: ClosedRange<Double>

    func makeNSView(context: Context) -> Line { Line() }

    func updateNSView(_ line: Line, context: Context) {
        line.progress = progress
        line.place = Line.Place(start: start, end: end, visible: visible)
        line.ticker = ticker
    }

    static func dismantleNSView(_ line: Line, coordinator: ()) {
        line.ticker = nil
    }

    final class Line: SamplerLiveView {
        struct Place: Equatable {
            var start = 0.0
            var end = 1.0
            var visible = 0.0...1.0
        }

        var progress: () -> Double? = { nil }
        var place = Place() {
            didSet {
                guard place != oldValue else { return }
                shown = -1
                withoutAnimation { refresh() }
            }
        }

        private let line = CALayer()
        private var shown: Double? = -1
        private var shownSize = CGSize.zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer?.masksToBounds = true
            line.backgroundColor = NSColor.white.cgColor
            line.shadowColor = NSColor.black.cgColor
            line.shadowOpacity = 0.5
            line.shadowRadius = 1
            line.shadowOffset = .zero
            line.isHidden = true
            layer?.addSublayer(line)
            setAccessibilityElement(false)
        }

        override func refresh() {
            let now = progress()
            guard now != shown || bounds.size != shownSize else { return }
            shown = now
            shownSize = bounds.size
            guard let now else {
                line.isHidden = true
                return
            }
            let span = place.visible.upperBound - place.visible.lowerBound
            let fraction = place.start + now * (place.end - place.start)
            let x = CGFloat((fraction - place.visible.lowerBound) / span) * bounds.width
            line.isHidden = false
            line.frame = CGRect(x: x - 1, y: 0, width: 2, height: bounds.height)
        }
    }
}
