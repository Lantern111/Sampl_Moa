import AVFoundation
import SwiftUI

/// The window for one of the built-in effects, in the manner of Logic Pro's plug-ins: a picture of what the effect is
/// doing, and big knobs for only the settings that matter. It's always dark, as Logic's are.
struct SamplerEffectEditor: View {
    let effect: SamplerBuiltInEffect
    let plugin: SamplerEffects.Loaded
    let onTurnOn: (Bool) -> Void
    /// The recorder's tempo, for setting a delay in time with it.
    let tempo: () -> Double

    @State private var values: [AudioUnitParameterID: AUValue] = [:]

    private var accent: Color { Self.accent(for: effect.kind) }

    var body: some View {
        VStack(spacing: 0) {
            header

            SamplerEffectGraph(effect: effect, values: values, accent: accent, onChange: set)
                .frame(height: 170)
                .background(Color(white: 0.09), in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.06)) }
                .padding([.horizontal, .top], 16)

            HStack(spacing: 0) {
                ForEach(effect.controls) { control in
                    SamplerEffectKnob(
                        control: control,
                        value: values[control.parameter] ?? control.range.lowerBound,
                        neutral: effect.startingValue(of: control.parameter) ?? control.range.lowerBound,
                        accent: accent,
                        onChange: { set(control.parameter, to: $0) }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, effect.kind == .delay ? 10 : 20)

            if effect.kind == .delay {
                tempoNotes
                    .padding(.bottom, 18)
            }
        }
        .frame(width: CGFloat(max(effect.controls.count, 4)) * 104 + 32)
        .background(Color(white: 0.17))
        .environment(\.colorScheme, .dark)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                onTurnOn(!plugin.isOn)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(plugin.isOn ? accent : Color.white.opacity(0.35))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08), in: .circle)
            }
            .buttonStyle(.plain)
            .help(plugin.isOn ? "Bypass" : "Turn On")

            Text(verbatim: effect.title)
                .font(.headline)
                .foregroundStyle(plugin.isOn ? Color.white : Color.white.opacity(0.45))

            Spacer()

            Button("Reset") {
                effect.applyStartingSettings(to: plugin.unit)
                load()
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Color.white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 5))
            .help("Puts every setting back where it started.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.12))
    }

    /// Sets the delay to a note length at the recorder's tempo, as a one-off rather than following it.
    private var tempoNotes: some View {
        let beat = 60 / max(tempo(), 1)
        let notes: [(label: String, beats: Double)] = [("1/2", 2), ("1/4", 1), ("1/8.", 0.75), ("1/8", 0.5), ("1/16", 0.25)]
        let time = values[kDelayParam_DelayTime] ?? 0
        return HStack(spacing: 6) {
            Text("At the Tempo")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.5))
            ForEach(notes, id: \.label) { note in
                let seconds = AUValue(min(beat * note.beats, 2))
                let isChosen = abs(time - seconds) < 0.001
                Button {
                    set(kDelayParam_DelayTime, to: seconds)
                } label: {
                    Text(verbatim: note.label)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(isChosen ? Color.black : Color.white.opacity(0.8))
                        .frame(width: 38, height: 20)
                        .background(isChosen ? accent : Color.white.opacity(0.08), in: .rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() {
        effect.applyHiddenSettings(to: plugin.unit)
        let tree = plugin.unit.auAudioUnit.parameterTree
        var loaded: [AudioUnitParameterID: AUValue] = [:]
        for control in effect.controls {
            if let parameter = tree?.parameter(withAddress: AUParameterAddress(control.parameter)) {
                loaded[control.parameter] = parameter.value
            }
        }
        values = loaded
    }

    private func set(_ parameter: AudioUnitParameterID, to value: AUValue) {
        values[parameter] = value
        plugin.unit.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(parameter))?.value = value
    }

    static func accent(for kind: SamplerBuiltInEffect.Kind) -> Color {
        switch kind {
        case .reverb, .roomReverb: Color(red: 0.62, green: 0.52, blue: 1)
        case .delay: Color(red: 0.3, green: 0.82, blue: 0.82)
        case .lowPass, .highPass, .bandPass: Color(red: 1, green: 0.62, blue: 0.25)
        case .distortion: Color(red: 1, green: 0.38, blue: 0.32)
        case .compressor: Color(red: 1, green: 0.8, blue: 0.3)
        case .limiter: Color(red: 0.42, green: 0.86, blue: 0.45)
        }
    }
}

/// A big knob in the manner of Logic Pro's: a ring that fills with colour, a dark cap, and the setting below it.
/// Drag up or down to turn it, and double-click to put it back where it started.
private struct SamplerEffectKnob: View {
    let control: SamplerBuiltInEffect.Control
    let value: AUValue
    let neutral: AUValue
    let accent: Color
    let onChange: (AUValue) -> Void

    @State private var positionAtDragStart: Double?

    private static let diameter: CGFloat = 54
    private static let sweep = 270.0
    private static let startAngle = 135.0
    private static let dragDistanceForFullTurn = 200.0

    private var position: Double { control.position(of: value) }

    /// A control that goes both ways from 0, like a gain, fills outward from there.
    private var anchor: Double {
        control.range.contains(0) && control.range.lowerBound < 0 ? control.position(of: 0) : 0
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: control.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.65))
                .lineLimit(1)

            dial
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            let start = positionAtDragStart ?? position
                            positionAtDragStart = start
                            let moved = (drag.translation.width - drag.translation.height) / Self.dragDistanceForFullTurn
                            onChange(control.value(at: start + moved))
                        }
                        .onEnded { _ in positionAtDragStart = nil }
                )
                .onTapGesture(count: 2) { onChange(neutral) }

            Text(verbatim: control.reading(of: value))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.3), in: .rect(cornerRadius: 4))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: control.title))
        .accessibilityValue(Text(verbatim: control.reading(of: value)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(control.value(at: position + 0.04))
            case .decrement: onChange(control.value(at: position - 0.04))
            @unknown default: break
            }
        }
    }

    private var dial: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 3

            func arc(from: Double, to: Double) -> Path {
                var path = Path()
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(Self.startAngle + from * Self.sweep),
                    endAngle: .degrees(Self.startAngle + to * Self.sweep),
                    clockwise: false
                )
                return path
            }

            let ring = StrokeStyle(lineWidth: 4, lineCap: .round)
            context.stroke(arc(from: 0, to: 1), with: .color(.white.opacity(0.1)), style: ring)
            if abs(position - anchor) > 0.001 {
                context.stroke(arc(from: min(anchor, position), to: max(anchor, position)), with: .color(accent), style: ring)
            }

            let cap = Path(ellipseIn: CGRect(x: center.x - radius + 7, y: center.y - radius + 7, width: (radius - 7) * 2, height: (radius - 7) * 2))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.6), radius: 3, y: 2))
                layer.fill(cap, with: .linearGradient(
                    Gradient(colors: [Color(white: 0.36), Color(white: 0.18)]),
                    startPoint: CGPoint(x: center.x, y: center.y - radius),
                    endPoint: CGPoint(x: center.x, y: center.y + radius)
                ))
            }
            context.stroke(cap, with: .color(.white.opacity(0.08)), lineWidth: 1)

            let angle = Angle.degrees(Self.startAngle + position * Self.sweep).radians
            var pointer = Path()
            pointer.move(to: CGPoint(x: center.x + cos(angle) * (radius - 7) * 0.25, y: center.y + sin(angle) * (radius - 7) * 0.25))
            pointer.addLine(to: CGPoint(x: center.x + cos(angle) * (radius - 9), y: center.y + sin(angle) * (radius - 9)))
            context.stroke(pointer, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}

/// A picture of what the effect is doing, drawn from its settings. A filter's can be dragged, like Logic's EQ.
private struct SamplerEffectGraph: View {
    let effect: SamplerBuiltInEffect
    let values: [AudioUnitParameterID: AUValue]
    let accent: Color
    let onChange: (AudioUnitParameterID, AUValue) -> Void

    private static let gridColor = Color.white.opacity(0.07)
    private static let labelColor = Color.white.opacity(0.35)

    private func value(_ parameter: AudioUnitParameterID) -> Double {
        Double(values[parameter] ?? effect.startingValue(of: parameter) ?? 0)
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 14, dy: 14)
            Canvas { context, _ in
                switch effect.kind {
                case .lowPass, .highPass, .bandPass: drawFilter(in: &context, plot: plot)
                case .delay: drawDelay(in: &context, plot: plot)
                case .reverb, .roomReverb: drawReverb(in: &context, plot: plot)
                case .distortion: drawDistortion(in: &context, plot: plot)
                case .compressor, .limiter: drawDynamics(in: &context, plot: plot)
                }
            }
            .contentShape(Rectangle())
            .gesture(filterDrag(plot: plot), including: isFilter ? .all : .none)
        }
        .accessibilityHidden(true)
    }

    private var isFilter: Bool { [.lowPass, .highPass, .bandPass].contains(effect.kind) }

    // MARK: Filters

    private static let lowestFrequency = 20.0
    private static let highestFrequency = 20000.0
    private static let filterRange = -36.0...24.0

    private func x(ofFrequency frequency: Double, in plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(log10(frequency / Self.lowestFrequency) / log10(Self.highestFrequency / Self.lowestFrequency)) * plot.width
    }

    private func frequency(atX x: CGFloat, in plot: CGRect) -> Double {
        Self.lowestFrequency * pow(Self.highestFrequency / Self.lowestFrequency, Double((x - plot.minX) / plot.width))
    }

    private func y(ofDecibels decibels: Double, range: ClosedRange<Double>, in plot: CGRect) -> CGFloat {
        let clamped = min(max(decibels, range.lowerBound), range.upperBound)
        return plot.maxY - CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound)) * plot.height
    }

    private func drawFilter(in context: inout GraphicsContext, plot: CGRect) {
        for frequency in [100.0, 1000, 10000] {
            line(in: &context, from: CGPoint(x: x(ofFrequency: frequency, in: plot), y: plot.minY), to: CGPoint(x: x(ofFrequency: frequency, in: plot), y: plot.maxY))
            label(in: &context, frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))", at: CGPoint(x: x(ofFrequency: frequency, in: plot) + 3, y: plot.maxY - 6), anchor: .leading)
        }
        for decibels in [-24.0, -12, 0, 12] {
            let y = y(ofDecibels: decibels, range: Self.filterRange, in: plot)
            line(in: &context, from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), strong: decibels == 0)
            label(in: &context, decibels == 0 ? "0" : String(format: "%+.0f", decibels), at: CGPoint(x: plot.minX + 2, y: y - 6), anchor: .leading)
        }

        let (frequencyParameter, amountParameter) = parameters
        let center = value(frequencyParameter), amount = value(amountParameter)
        let frequencies = (0...120).map { Self.lowestFrequency * pow(Self.highestFrequency / Self.lowestFrequency, Double($0) / 120) }
        let response = SamplerBuiltInEffect.filterResponse(effect.kind, frequency: center, amount: amount, at: frequencies)
        var curve = Path()
        for (index, decibels) in response.enumerated() {
            let point = CGPoint(x: x(ofFrequency: frequencies[index], in: plot), y: y(ofDecibels: decibels, range: Self.filterRange, in: plot))
            if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        fill(curve, in: &context, plot: plot, baseline: y(ofDecibels: Self.filterRange.lowerBound, range: Self.filterRange, in: plot))
        context.stroke(curve, with: .color(accent), lineWidth: 2)

        let peak = SamplerBuiltInEffect.filterResponse(effect.kind, frequency: center, amount: amount, at: [center])[0]
        let handle = CGPoint(x: x(ofFrequency: center, in: plot), y: y(ofDecibels: peak, range: Self.filterRange, in: plot))
        context.fill(Path(ellipseIn: CGRect(x: handle.x - 7, y: handle.y - 7, width: 14, height: 14)), with: .color(accent))
        context.stroke(Path(ellipseIn: CGRect(x: handle.x - 7, y: handle.y - 7, width: 14, height: 14)), with: .color(.white), lineWidth: 1.5)
    }

    private var parameters: (frequency: AudioUnitParameterID, amount: AudioUnitParameterID) {
        switch effect.kind {
        case .highPass: (kHipassParam_CutoffFrequency, kHipassParam_Resonance)
        case .bandPass: (kBandpassParam_CenterFrequency, kBandpassParam_Bandwidth)
        default: (kLowPassParam_CutoffFrequency, kLowPassParam_Resonance)
        }
    }

    /// Left and right set the frequency. Up and down set the resonance, or for the band-pass filter, how narrow it is.
    private func filterDrag(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard isFilter else { return }
                let (frequencyParameter, amountParameter) = parameters
                let frequency = frequency(atX: min(max(drag.location.x, plot.minX), plot.maxX), in: plot)
                onChange(frequencyParameter, AUValue(min(max(frequency, Self.lowestFrequency), Self.highestFrequency)))
                guard let amount = effect.controls.first(where: { $0.parameter == amountParameter }) else { return }
                let height = Double(1 - (min(max(drag.location.y, plot.minY), plot.maxY) - plot.minY) / plot.height)
                if effect.kind == .bandPass {
                    onChange(amountParameter, amount.value(at: 1 - height))
                } else {
                    let decibels = Self.filterRange.lowerBound + height * (Self.filterRange.upperBound - Self.filterRange.lowerBound)
                    onChange(amountParameter, AUValue(min(max(decibels, Double(amount.range.lowerBound)), Double(amount.range.upperBound))))
                }
            }
    }

    // MARK: Delay

    private func drawDelay(in context: inout GraphicsContext, plot: CGRect) {
        let time = max(value(kDelayParam_DelayTime), 0.01)
        let feedback = min(max(value(kDelayParam_Feedback) / 100, 0), 0.99)
        let mix = value(kDelayParam_WetDryMix) / 100
        let span = min(max(time * 6, 1), 6)
        func x(_ seconds: Double) -> CGFloat { plot.minX + CGFloat(seconds / span) * plot.width }

        for second in stride(from: 0.0, through: span, by: span > 3 ? 1 : 0.5) {
            line(in: &context, from: CGPoint(x: x(second), y: plot.minY), to: CGPoint(x: x(second), y: plot.maxY))
            label(in: &context, String(format: second == second.rounded() ? "%.0f s" : "%.1f s", second), at: CGPoint(x: x(second) + 3, y: plot.maxY - 6), anchor: .leading)
        }
        line(in: &context, from: CGPoint(x: plot.minX, y: plot.maxY), to: CGPoint(x: plot.maxX, y: plot.maxY), strong: true)

        // Heights in decibels, as a meter shows them, so the quieter echoes can still be seen.
        let floor = -48.0
        func height(of level: Double) -> Double { max(0, (20 * log10(max(level, 1e-6)) - floor) / -floor) }
        func bar(at seconds: Double, level: Double, color: Color) {
            let top = plot.maxY - CGFloat(height(of: level)) * plot.height
            context.fill(Path(roundedRect: CGRect(x: x(seconds) - 3, y: top, width: 6, height: plot.maxY - top), cornerRadius: 2), with: .color(color))
        }
        if mix < 1 { bar(at: 0, level: 1 - mix, color: .white.opacity(0.8)) }
        var level = mix
        var echo = 1
        while Double(echo) * time <= span, height(of: level) > 0 {
            bar(at: Double(echo) * time, level: level, color: accent.opacity(0.4 + 0.6 * height(of: level)))
            level *= feedback
            echo += 1
        }
    }

    // MARK: Reverb

    private func drawReverb(in context: inout GraphicsContext, plot: CGRect) {
        let isRoom = effect.kind == .roomReverb
        let decay = isRoom ? value(kReverbParam_LargeSize) * 25 : value(kReverb2Param_DecayTimeAt0Hz)
        let highDecay = isRoom ? decay * (1.1 - value(kReverbParam_LargeBrightness)) : value(kReverb2Param_DecayTimeAtNyquist)
        let start = isRoom ? value(kReverbParam_PreDelay) : value(kReverb2Param_MinDelayTime)
        let span = max(max(decay, highDecay) * 1.15 + start, 0.5)
        func x(_ seconds: Double) -> CGFloat { plot.minX + CGFloat(seconds / span) * plot.width }
        func y(_ decibels: Double) -> CGFloat { plot.minY + CGFloat(-decibels / 60) * plot.height }

        let step = span > 6 ? 2.0 : span > 2 ? 1 : 0.25
        for second in stride(from: 0.0, through: span, by: step) {
            line(in: &context, from: CGPoint(x: x(second), y: plot.minY), to: CGPoint(x: x(second), y: plot.maxY))
            label(in: &context, String(format: step < 1 ? "%.2f s" : "%.0f s", second), at: CGPoint(x: x(second) + 3, y: plot.maxY - 6), anchor: .leading)
        }
        for decibels in [-20.0, -40] {
            line(in: &context, from: CGPoint(x: plot.minX, y: y(decibels)), to: CGPoint(x: plot.maxX, y: y(decibels)))
        }

        func tail(lasting seconds: Double) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: x(0), y: plot.maxY))
            path.addLine(to: CGPoint(x: x(start), y: plot.maxY))
            path.addLine(to: CGPoint(x: x(start), y: y(0)))
            path.addLine(to: CGPoint(x: x(min(start + seconds, span)), y: y(-60 * min(seconds, span - start) / seconds)))
            return path
        }
        var low = tail(lasting: decay)
        let lowLine = low
        low.addLine(to: CGPoint(x: x(min(start + decay, span)), y: plot.maxY))
        low.closeSubpath()
        context.fill(low, with: .linearGradient(Gradient(colors: [accent.opacity(0.45), accent.opacity(0.05)]), startPoint: CGPoint(x: plot.minX, y: plot.minY), endPoint: CGPoint(x: plot.maxX, y: plot.maxY)))
        context.stroke(lowLine, with: .color(accent), lineWidth: 2)
        context.stroke(tail(lasting: highDecay), with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        label(in: &context, String(localized: "Highs"), at: CGPoint(x: x(min(start + highDecay * 0.5, span * 0.85)) + 6, y: y(-30) - 8), anchor: .leading)
    }

    // MARK: Distortion

    private func drawDistortion(in context: inout GraphicsContext, plot: CGRect) {
        let square = CGRect(x: plot.midX - plot.height / 2, y: plot.minY, width: plot.height, height: plot.height)
        line(in: &context, from: CGPoint(x: square.minX, y: square.midY), to: CGPoint(x: square.maxX, y: square.midY), strong: true)
        line(in: &context, from: CGPoint(x: square.midX, y: square.minY), to: CGPoint(x: square.midX, y: square.maxY), strong: true)
        var straight = Path()
        straight.move(to: CGPoint(x: square.minX, y: square.maxY))
        straight.addLine(to: CGPoint(x: square.maxX, y: square.minY))
        context.stroke(straight, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        // An outline of the shape, not a measurement: more drive rounds the curve over, warmth tilts it, and crushing
        // turns it into steps.
        let drive = 1 + value(kDistortionParam_CubicTerm) / 3
        let warmth = value(kDistortionParam_SquaredTerm) / 40
        let crush = value(kDistortionParam_DecimationMix) / 100
        let mix = value(kDistortionParam_FinalMix) / 100
        let steps = 4 + (1 - crush) * 60
        var curve = Path()
        for index in 0...160 {
            let input = Double(index) / 80 - 1
            var shaped = tanh(drive * (input + warmth * input * abs(input))) / tanh(drive * (1 + warmth))
            if crush > 0 { shaped = shaped * (1 - crush) + (shaped * steps).rounded() / steps * crush }
            let output = mix * shaped + (1 - mix) * input
            let point = CGPoint(x: square.midX + CGFloat(input) * square.width / 2, y: square.midY - CGFloat(max(min(output, 1), -1)) * square.height / 2)
            if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        context.stroke(curve, with: .color(accent), lineWidth: 2.5)
        label(in: &context, String(localized: "In"), at: CGPoint(x: square.maxX + 4, y: square.midY - 6), anchor: .leading)
        label(in: &context, String(localized: "Out"), at: CGPoint(x: square.midX + 4, y: square.minY + 4), anchor: .leading)
    }

    // MARK: Compressor and limiter

    private func drawDynamics(in context: inout GraphicsContext, plot: CGRect) {
        let square = CGRect(x: plot.midX - plot.height / 2, y: plot.minY, width: plot.height, height: plot.height)
        let range = -60.0...6.0
        func point(input: Double, output: Double) -> CGPoint {
            CGPoint(
                x: square.minX + CGFloat((input - range.lowerBound) / (range.upperBound - range.lowerBound)) * square.width,
                y: square.maxY - CGFloat((min(max(output, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)) * square.height
            )
        }
        for decibels in [-48.0, -36, -24, -12, 0] {
            line(in: &context, from: point(input: decibels, output: range.lowerBound), to: point(input: decibels, output: range.upperBound), strong: decibels == 0)
            line(in: &context, from: point(input: range.lowerBound, output: decibels), to: point(input: range.upperBound, output: decibels), strong: decibels == 0)
            label(in: &context, "\(Int(decibels))", at: CGPoint(x: square.minX - 4, y: point(input: 0, output: decibels).y), anchor: .trailing)
        }
        var straight = Path()
        straight.move(to: point(input: range.lowerBound, output: range.lowerBound))
        straight.addLine(to: point(input: range.upperBound, output: range.upperBound))
        context.stroke(straight, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        var curve = Path()
        for index in 0...132 {
            let input = range.lowerBound + Double(index) / 2
            let output: Double
            if effect.kind == .limiter {
                let gained = input + value(kLimiterParam_PreGain)
                output = gained < -6 ? gained : -6 + 5.9 * tanh((gained + 6) / 5.9)
            } else {
                let threshold = value(kDynamicsProcessorParam_Threshold)
                let headroom = max(value(kDynamicsProcessorParam_HeadRoom), 0.1)
                let squeezed = input <= threshold ? input : threshold + headroom * tanh((input - threshold) / headroom)
                output = squeezed + value(kDynamicsProcessorParam_OverallGain)
            }
            let next = point(input: input, output: output)
            if index == 0 { curve.move(to: next) } else { curve.addLine(to: next) }
        }
        context.stroke(curve, with: .color(accent), lineWidth: 2.5)
        if effect.kind == .compressor {
            let threshold = value(kDynamicsProcessorParam_Threshold)
            let mark = point(input: threshold, output: threshold + value(kDynamicsProcessorParam_OverallGain))
            context.fill(Path(ellipseIn: CGRect(x: mark.x - 4, y: mark.y - 4, width: 8, height: 8)), with: .color(accent))
        }
        label(in: &context, String(localized: "In"), at: CGPoint(x: square.maxX + 4, y: square.maxY - 6), anchor: .leading)
        label(in: &context, String(localized: "Out"), at: CGPoint(x: square.minX + 4, y: square.minY + 4), anchor: .leading)
    }

    // MARK: Shared

    private func line(in context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, strong: Bool = false) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(strong ? .white.opacity(0.18) : Self.gridColor), lineWidth: 1)
    }

    private func label(in context: inout GraphicsContext, _ text: String, at point: CGPoint, anchor: UnitPoint) {
        context.draw(Text(verbatim: text).font(.system(size: 9).monospacedDigit()).foregroundStyle(Self.labelColor), at: point, anchor: anchor)
    }

    private func fill(_ curve: Path, in context: inout GraphicsContext, plot: CGRect, baseline: CGFloat) {
        var area = curve
        area.addLine(to: CGPoint(x: plot.maxX, y: baseline))
        area.addLine(to: CGPoint(x: plot.minX, y: baseline))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [accent.opacity(0.4), accent.opacity(0.03)]), startPoint: CGPoint(x: plot.midX, y: plot.minY), endPoint: CGPoint(x: plot.midX, y: plot.maxY)))
    }
}
