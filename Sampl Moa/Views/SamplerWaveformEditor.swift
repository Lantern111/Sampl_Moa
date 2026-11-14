import AppKit
import SwiftUI

/// A sound's whole file, with a handle at each end of the part that plays. The mouse wheel zooms around the pointer,
/// sideways scrolling moves along, and the overview underneath works like the scroll bar in Logic Pro's editors.
struct SamplerWaveformEditor: View {
    private enum Drag {
        case nothing, startHandle, endHandle
        case part(grabbedAt: Double, start: Double, end: Double)
        case marker(Int)
    }

    private struct PeaksRequest: Hashable {
        let path: String?
        let range: ClosedRange<Double>
        let width: Int
        let status: SamplerPadState.Status
    }

    private static let wholeFile = 0.0...1.0
    /// A slice this small a part of its file is hard to see, so it opens up close.
    private static let largestPartToOpenZoomed = 0.3
    private static let handleReach: CGFloat = 9
    private static let shortestVisibleSeconds = 0.02
    private static let doubleClickSeconds = 0.3

    let sampler: SamplerStore
    let slotIndex: Int

    @State private var visible: ClosedRange<Double>
    @State private var peaks: [Float] = []
    /// What part of the file `peaks` covers. Old peaks are stretched to fit until new ones arrive, so zooming is smooth.
    @State private var peaksRange = wholeFile
    @State private var wholeFilePeaks: [Float] = []
    @State private var viewWidth: CGFloat = 0
    @State private var drag = Drag.nothing
    @State private var lastClick = Date.distantPast
    @State private var didDrag = false

    init(sampler: SamplerStore, slotIndex: Int) {
        self.sampler = sampler
        self.slotIndex = slotIndex
        let slot = sampler.slot(slotIndex)
        _visible = State(initialValue: slot.end - slot.start < Self.largestPartToOpenZoomed
            ? Self.closeUp(start: slot.start, end: slot.end)
            : Self.wholeFile)
    }

    private var slot: SamplerSlot { sampler.slots[slotIndex] }
    private var session: SamplerStore.ChopSession? {
        sampler.chopSession?.slot == slotIndex ? sampler.chopSession : nil
    }
    private var span: Double { visible.upperBound - visible.lowerBound }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                Canvas { context, size in
                    drawWaveform(in: &context, size: size)
                }
                .overlay {
                    SamplerPlayheadLine(
                        ticker: sampler.ticker,
                        progress: { [state = sampler.padStates[slotIndex]] in state.progress },
                        start: slot.start,
                        end: slot.end,
                        visible: visible
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .gesture(waveformGesture(width: geometry.size.width))
                .onContinuousHover { phase in
                    updateCursor(phase, width: geometry.size.width)
                }
                .background(ScrollCatcher { dx, dy, pointer, isPrecise in
                    handleScroll(dx: dx, dy: dy, pointer: pointer, isPrecise: isPrecise, width: geometry.size.width)
                } onMagnify: { amount, pointer in
                    zoom(by: 1 - amount, around: pointer)
                })
                .onChange(of: geometry.size.width, initial: true) { viewWidth = geometry.size.width }
            }
            .frame(minHeight: 60, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 5))
            .accessibilityLabel(Text("Waveform"))

            SamplerOverview(peaks: wholeFilePeaks, start: slot.start, end: slot.end, visible: $visible, shortestVisible: shortestVisibleSpan)
                .frame(height: 16)

            if session != nil {
                chopControls
            } else {
                caption
            }
        }
        .task(id: PeaksRequest(path: slot.path, range: visible, width: Int(viewWidth), status: sampler.padStates[slotIndex].status)) {
            guard viewWidth > 0 else { return }
            let range = visible
            let count = max(40, Int(viewWidth / 2.5))
            let loaded = await sampler.peaks(of: slotIndex, from: range.lowerBound, to: range.upperBound, count: count)
            guard !Task.isCancelled else { return }
            peaks = loaded
            peaksRange = range
            if wholeFilePeaks.isEmpty {
                wholeFilePeaks = await sampler.peaks(of: slotIndex, from: 0, to: 1, count: 300)
            }
        }
    }

    private var caption: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("Scroll to zoom, or drag the bar below.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Spacer(minLength: 8)
                zoomButtons
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                zoomButtons
            }
        }
    }

    private var zoomButtons: some View {
        HStack(spacing: 8) {
            if visible != Self.wholeFile {
                Button("Show Whole File") { visible = Self.wholeFile }
                    .controlSize(.mini)
            }
            Button("Zoom to Selection") { visible = Self.closeUp(start: slot.start, end: slot.end) }
                .controlSize(.mini)
            if let reading {
                Text(verbatim: reading)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    private var chopControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chopSettings
                Spacer(minLength: 8)
                chopButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                chopSettings
                HStack {
                    Spacer(minLength: 0)
                    chopButtons
                }
            }
        }
    }

    private var chopSettings: some View {
        HStack(spacing: 8) {
            Picker("Cut", selection: Binding(
                get: { session?.style ?? .atHits },
                set: { sampler.setChopStyle($0) }
            )) {
                Text("At Hits").tag(SamplerStore.ChopStyle.atHits)
                Text(verbatim: "4").tag(SamplerStore.ChopStyle.equalParts(4))
                Text(verbatim: "8").tag(SamplerStore.ChopStyle.equalParts(8))
                Text(verbatim: "16").tag(SamplerStore.ChopStyle.equalParts(16))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 180)

            if session?.style == .atHits {
                Text("Sensitivity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { session?.sensitivity ?? 0.5 },
                    set: { sampler.setChopSensitivity($0) }
                ), in: 0...1)
                .controlSize(.mini)
                .frame(width: 80)
                .accessibilityLabel(Text("Sensitivity"))
            }

            Text("\(session?.markers.count ?? 0) slices")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Click a slice to hear it. Drag a line to move it. Double-click to add or remove a line.")
        }
        .fixedSize()
    }

    private var chopButtons: some View {
        HStack(spacing: 8) {
            Button("Cancel", action: sampler.cancelChop)
                .controlSize(.small)
                .help("Cancel (esc)")
            Button("Put on Pads", action: sampler.applyChop)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled((session?.markers.count ?? 0) < 2)
        }
        .fixedSize()
    }

    /// How long the chosen part lasts, after any change of speed or pitch.
    private var reading: String? {
        guard let duration = sampler.fileDuration(of: slotIndex) else { return nil }
        let seconds = duration * (slot.end - slot.start) / slot.speed / pow(2, Double(slot.tune) / 12)
        return String(format: String(localized: "%.2f sec"), seconds)
    }

    private var shortestVisibleSpan: Double {
        guard let duration = sampler.fileDuration(of: slotIndex), duration > 0 else { return 0.001 }
        return min(1, Self.shortestVisibleSeconds / duration)
    }

    private static func closeUp(start: Double, end: Double) -> ClosedRange<Double> {
        let margin = (end - start) * 0.15
        return max(0, start - margin)...min(1, end + margin)
    }

    private func fraction(at x: CGFloat, width: CGFloat) -> Double {
        min(max(visible.lowerBound + Double(x / max(width, 1)) * span, 0), 1)
    }

    private func x(for fraction: Double, width: CGFloat) -> CGFloat {
        CGFloat((fraction - visible.lowerBound) / span) * width
    }

    // MARK: - Drawing

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        let startX = x(for: slot.start, width: size.width)
        let endX = x(for: slot.end, width: size.width)

        if !peaks.isEmpty {
            let drawnSpan = peaksRange.upperBound - peaksRange.lowerBound
            let step = drawnSpan / Double(peaks.count)
            let barWidth = max(1, CGFloat(step / span) * size.width - 0.5)
            for (index, peak) in peaks.enumerated() {
                let barX = x(for: peaksRange.lowerBound + Double(index) * step, width: size.width)
                guard barX + barWidth >= 0, barX <= size.width else { continue }
                let height = max(1.5, CGFloat(peak) * (size.height - 6))
                let rect = CGRect(x: barX, y: (size.height - height) / 2, width: barWidth, height: height)
                let isInside = barX + barWidth > startX && barX < endX
                context.fill(Path(rect), with: .color(isInside ? Color.accentColor : Color.secondary.opacity(0.35)))
            }
        }

        if let session {
            for (index, marker) in session.markers.enumerated() {
                let markerX = x(for: marker, width: size.width)
                guard markerX >= -1, markerX <= size.width + 1 else { continue }
                context.fill(Path(CGRect(x: markerX - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.orange))
                context.draw(
                    Text(verbatim: "\(index + 1)").font(.system(size: 9, weight: .medium)).foregroundStyle(.orange),
                    at: CGPoint(x: markerX + 3, y: 2),
                    anchor: .topLeading
                )
            }
        }

        drawHandle(at: startX, pointsRight: true, in: &context, size: size)
        drawHandle(at: endX, pointsRight: false, in: &context, size: size)
    }

    /// A line with a flag at the top, big enough to see and to grab.
    private func drawHandle(at handleX: CGFloat, pointsRight: Bool, in context: inout GraphicsContext, size: CGSize) {
        guard handleX >= -1, handleX <= size.width + 1 else { return }
        context.fill(Path(CGRect(x: handleX - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
        var flag = Path()
        flag.move(to: CGPoint(x: handleX, y: 0))
        flag.addLine(to: CGPoint(x: handleX + (pointsRight ? 9 : -9), y: 0))
        flag.addLine(to: CGPoint(x: handleX, y: 10))
        flag.closeSubpath()
        context.fill(flag, with: .color(.primary))
    }

    // MARK: - Mouse

    private func whatsAt(_ location: CGPoint, width: CGFloat) -> Drag {
        if let session {
            for (index, marker) in session.markers.enumerated().dropFirst() where abs(x(for: marker, width: width) - location.x) < Self.handleReach {
                return .marker(index)
            }
        }
        let startDistance = abs(x(for: slot.start, width: width) - location.x)
        let endDistance = abs(x(for: slot.end, width: width) - location.x)
        if min(startDistance, endDistance) < Self.handleReach {
            return startDistance <= endDistance ? .startHandle : .endHandle
        }
        let fractionHere = fraction(at: location.x, width: width)
        if session == nil, fractionHere > slot.start, fractionHere < slot.end {
            return .part(grabbedAt: fractionHere, start: slot.start, end: slot.end)
        }
        return .nothing
    }

    private func updateCursor(_ phase: HoverPhase, width: CGFloat) {
        switch phase {
        case .active(let location):
            switch whatsAt(location, width: width) {
            case .startHandle, .endHandle, .marker: NSCursor.resizeLeftRight.set()
            case .part: NSCursor.openHand.set()
            case .nothing: NSCursor.arrow.set()
            }
        case .ended:
            NSCursor.arrow.set()
        }
    }

    private func waveformGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if case .nothing = drag, !didDrag {
                    drag = whatsAt(value.startLocation, width: width)
                }
                if abs(value.translation.width) > 2 { didDrag = true }
                guard didDrag else { return }

                let here = fraction(at: value.location.x, width: width)
                let gap = sampler.shortestRegion(of: slotIndex)
                switch drag {
                case .nothing:
                    break
                case .startHandle:
                    sampler.setRegion(start: min(here, slot.end - gap), end: slot.end, of: slotIndex, isFinished: false)
                case .endHandle:
                    sampler.setRegion(start: slot.start, end: max(here, slot.start + gap), of: slotIndex, isFinished: false)
                case .part(let grabbedAt, let start, let end):
                    let shift = min(max(here - grabbedAt, -start), 1 - end)
                    sampler.setRegion(start: start + shift, end: end + shift, of: slotIndex, isFinished: false)
                case .marker(let index):
                    drag = .marker(sampler.moveChopMarker(index, to: here))
                }
            }
            .onEnded { value in
                switch drag {
                case .startHandle, .endHandle, .part:
                    if didDrag { sampler.setRegion(start: slot.start, end: slot.end, of: slotIndex, isFinished: true) }
                default:
                    break
                }
                if !didDrag { clicked(at: value.location, width: width) }
                drag = .nothing
                didDrag = false
            }
    }

    /// A click plays a slice while chopping, and a second click soon after adds or removes a line.
    private func clicked(at location: CGPoint, width: CGFloat) {
        guard session != nil else { return }
        let here = fraction(at: location.x, width: width)
        if Date().timeIntervalSince(lastClick) < Self.doubleClickSeconds {
            sampler.toggleChopMarker(at: here, within: Double(Self.handleReach / max(width, 1)) * span)
            lastClick = .distantPast
        } else {
            sampler.auditionChopSlice(at: here)
            lastClick = Date()
        }
    }

    // MARK: - Wheel

    private func handleScroll(dx: CGFloat, dy: CGFloat, pointer: CGFloat, isPrecise: Bool, width: CGFloat) {
        let scale: CGFloat = isPrecise ? 1 : 6
        if abs(dx) > abs(dy) {
            pan(byFraction: Double(-dx * scale / max(width, 1)) * span)
        } else {
            zoom(by: pow(1.012, -dy * scale), around: pointer)
        }
    }

    private func zoom(by factor: CGFloat, around pointer: CGFloat) {
        let anchor = visible.lowerBound + Double(pointer) * span
        let newSpan = min(max(span * Double(factor), shortestVisibleSpan), 1)
        var lower = anchor - Double(pointer) * newSpan
        lower = min(max(lower, 0), 1 - newSpan)
        visible = lower...(lower + newSpan)
    }

    private func pan(byFraction amount: Double) {
        let lower = min(max(visible.lowerBound + amount, 0), 1 - span)
        visible = lower...(lower + span)
    }
}

/// The whole file in a thin strip, with a box showing the part in view. Drag the box to move along, or its edges to
/// zoom.
private struct SamplerOverview: View {
    private enum Drag {
        case nothing, lowerEdge, upperEdge
        case box(grabbedAt: Double, lower: Double, upper: Double)
    }

    private static let edgeReach: CGFloat = 6

    let peaks: [Float]
    let start: Double
    let end: Double
    @Binding var visible: ClosedRange<Double>
    let shortestVisible: Double

    @State private var drag = Drag.nothing

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let step = size.width / CGFloat(max(1, peaks.count))
                for (index, peak) in peaks.enumerated() {
                    let height = max(1, CGFloat(peak) * (size.height - 2))
                    let barX = CGFloat(index) * step
                    let fraction = Double(index) / Double(peaks.count)
                    let isInside = fraction >= start && fraction <= end
                    let rect = CGRect(x: barX, y: (size.height - height) / 2, width: max(0.8, step - 0.3), height: height)
                    context.fill(Path(rect), with: .color(isInside ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35)))
                }
                let box = CGRect(
                    x: CGFloat(visible.lowerBound) * size.width,
                    y: 0,
                    width: max(6, CGFloat(visible.upperBound - visible.lowerBound) * size.width),
                    height: size.height
                )
                context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.primary.opacity(0.14)))
                context.stroke(Path(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(.primary.opacity(0.55)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(gesture(width: geometry.size.width))
        }
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 3))
        .accessibilityLabel(Text("Overview"))
    }

    private func gesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let safeWidth = max(width, 1)
                let here = min(max(Double(value.location.x / safeWidth), 0), 1)

                if case .nothing = drag {
                    let lowerX = CGFloat(visible.lowerBound) * width
                    let upperX = CGFloat(visible.upperBound) * width
                    let start = value.startLocation.x
                    if abs(start - lowerX) < Self.edgeReach {
                        drag = .lowerEdge
                    } else if abs(start - upperX) < Self.edgeReach {
                        drag = .upperEdge
                    } else {
                        // A click outside the box brings that part into view.
                        if start < lowerX || start > upperX {
                            let span = visible.upperBound - visible.lowerBound
                            let lower = min(max(here - span / 2, 0), 1 - span)
                            visible = lower...(lower + span)
                        }
                        drag = .box(grabbedAt: here, lower: visible.lowerBound, upper: visible.upperBound)
                    }
                }

                switch drag {
                case .nothing:
                    break
                case .lowerEdge:
                    visible = min(here, visible.upperBound - shortestVisible)...visible.upperBound
                case .upperEdge:
                    visible = visible.lowerBound...max(here, visible.lowerBound + shortestVisible)
                case .box(let grabbedAt, let lower, let upper):
                    let shift = min(max(here - grabbedAt, -lower), 1 - upper)
                    visible = (lower + shift)...(upper + shift)
                }
            }
            .onEnded { _ in drag = .nothing }
    }
}

/// SwiftUI has no way to hear the mouse wheel on Macs this app supports, so this listens in on the window's events and
/// takes those that are over this view.
private struct ScrollCatcher: NSViewRepresentable {
    /// Sideways and up-and-down movement, where the pointer is from 0 to 1 across the view, and whether the input is
    /// fine-grained like a trackpad rather than in steps like a wheel.
    let onScroll: (CGFloat, CGFloat, CGFloat, Bool) -> Void
    let onMagnify: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, CGFloat, Bool) -> Void)?
        var onMagnify: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, event.window === self.window, self.bounds.width > 0 else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }

                let pointer = point.x / self.bounds.width
                if event.type == .magnify {
                    self.onMagnify?(event.magnification, pointer)
                } else {
                    self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, pointer, event.hasPreciseScrollingDeltas)
                }
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        deinit {
            MainActor.assumeIsolated {
                if let monitor { NSEvent.removeMonitor(monitor) }
            }
        }
    }
}
