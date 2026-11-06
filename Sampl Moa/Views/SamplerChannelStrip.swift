import SwiftUI

/// The column at the side of the window, like the inspector in Logic Pro: the selected sound's channel strip beside the
/// master's, both the full height of the window so they can be read at a glance.
struct SamplerInspector: View {
    static let width: CGFloat = 290

    let sampler: SamplerStore

    var body: some View {
        // Both strips leave room for the same number of plug-ins, so their faders line up as on a desk.
        let pluginRows = max(
            sampler.effects.chain(for: sampler.selectedSlot).count,
            sampler.effects.chain(for: nil).count
        )
        HStack(spacing: 0) {
            SamplerChannelStrip(sampler: sampler, kind: .sound(sampler.selectedSlot), pluginRows: pluginRows)
            Divider()
            SamplerChannelStrip(sampler: sampler, kind: .master, pluginRows: pluginRows)
        }
        .frame(width: Self.width)
        .background(.background)
    }
}

/// A channel strip in the manner of Logic Pro's: EQ, plug-ins, sends, then a fader with a meter. There's one for the
/// selected sound and one for the master, which everything passes through, so the two never get mixed up.
struct SamplerChannelStrip: View {
    enum Kind: Equatable {
        case sound(Int)
        case master
    }

    let sampler: SamplerStore
    let kind: Kind
    /// How many plug-in rows to leave room for, the same on every strip.
    let pluginRows: Int

    private var isMaster: Bool { kind == .master }
    /// Whether a device's knobs are turning this strip.
    private var hasDeviceKnobs: Bool { sampler.knobsTurnMaster == isMaster }

    var body: some View {
        VStack(spacing: 10) {
            deviceKnobsButton

            section("EQ") {
                VStack(spacing: 6) {
                    eqCurve
                        .frame(height: 40)
                    HStack(spacing: 0) {
                        knob(.low)
                        knob(.mid)
                        knob(.high)
                    }
                }
            }

            section("Audio FX") {
                SamplerPluginSlots(effects: sampler.effects, slot: slotForPlugins, rows: pluginRows)
            }

            // Like Stereo Out in Logic Pro, the master has no sends. The space stays, so the faders still line up.
            section("Sends") {
                HStack(spacing: 0) {
                    knob(.delay)
                    knob(.reverb)
                }
            }
            .opacity(isMaster ? 0 : 1)
            .allowsHitTesting(!isMaster)
            .accessibilityHidden(isMaster)

            SamplerFader(
                position: position(of: .volume),
                neutral: SamplerFaderScale.unityPosition,
                reading: reading(of: .volume),
                level: level,
                loudest: loudest,
                onResetLoudest: { [sampler] in sampler.resetLoudest(of: slotForPlugins) },
                onChange: { set(.volume, to: $0) }
            )
            .frame(maxHeight: .infinity)

            nameLabel
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceKnobsButton: some View {
        Button {
            sampler.knobsTurnMaster = isMaster
        } label: {
            Label("Device Knobs", systemImage: hasDeviceKnobs ? "dial.medium.fill" : "dial.medium")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(hasDeviceKnobs ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    hasDeviceKnobs ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                    in: .rect(cornerRadius: 4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hasDeviceKnobs ? "Your device’s knobs turn this strip." : "Click to turn this strip with your device’s knobs.")
        .accessibilityLabel(Text("Use Device Knobs Here"))
        .accessibilityAddTraits(hasDeviceKnobs ? .isSelected : [])
    }

    private var nameLabel: some View {
        Group {
            switch kind {
            case .master: Text("Master")
            case .sound(SamplerSlot.keyboardIndex): Text("Keyboard")
            case .sound(let pad): Text("Pad \(pad + 1)")
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(isMaster ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.35), in: .rect(cornerRadius: 4))
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eqCurve: SamplerEQCurve {
        switch kind {
        case .master:
            SamplerEQCurve(low: sampler.master.eqLow, mid: sampler.master.eqMid, high: sampler.master.eqHigh)
        case .sound(let index):
            SamplerEQCurve(low: sampler.slots[index].eqLow, mid: sampler.slots[index].eqMid, high: sampler.slots[index].eqHigh)
        }
    }

    private var slotForPlugins: Int? {
        if case .sound(let index) = kind { return index }
        return nil
    }

    /// Read by the fader alone, so the rest of the strip doesn't redraw as the meter moves.
    private var level: () -> Float {
        switch kind {
        case .master: { [sampler] in sampler.masterLevel }
        case .sound(let index): { [sampler] in sampler.padStates[index].level }
        }
    }

    private var loudest: () -> Float {
        switch kind {
        case .master: { [sampler] in sampler.masterLoudest }
        case .sound(let index): { [sampler] in sampler.padStates[index].loudest }
        }
    }

    private func position(of knob: SamplerKnob) -> Double {
        switch kind {
        case .master: sampler.master.position(of: knob) ?? 0
        case .sound(let index): sampler.slots[index].position(of: knob)
        }
    }

    private func reading(of knob: SamplerKnob) -> String {
        switch kind {
        case .master: sampler.master.reading(of: knob)
        case .sound(let index): sampler.slots[index].reading(of: knob)
        }
    }

    private func set(_ knob: SamplerKnob, to position: Double) {
        switch kind {
        case .master: sampler.setMasterKnob(knob, toPosition: position)
        case .sound(let index): sampler.setKnob(knob, toPosition: position, of: index)
        }
    }

    private func knob(_ knob: SamplerKnob) -> some View {
        SamplerKnobView(
            title: knob.title,
            position: position(of: knob),
            neutral: knob.neutralValue,
            reading: reading(of: knob),
            isBeingLearned: sampler.learning == .knob(knob),
            diameter: 28,
            onChange: { set(knob, to: $0) }
        )
    }
}

/// What the three EQ bands do together, from the lowest frequencies on the left to the highest on the right.
private struct SamplerEQCurve: View {
    let low: Double
    let mid: Double
    let high: Double

    private static let frequencies = (0..<64).map { 20 * pow(1000, Double($0) / 63) }
    private static let gridFrequencies = [100.0, 1000, 10000]
    private static let range = 15.0

    var body: some View {
        let response = SamplerMixer.eqResponse(low: low, mid: mid, high: high, at: Self.frequencies)
        let isFlat = low == 0 && mid == 0 && high == 0

        Canvas { context, size in
            let middle = size.height / 2
            func x(_ frequency: Double) -> CGFloat { CGFloat(log10(frequency / 20) / 3) * size.width }
            func y(_ decibels: Double) -> CGFloat { middle - CGFloat(min(max(decibels / Self.range, -1), 1)) * (middle - 3) }

            var grid = Path()
            for frequency in Self.gridFrequencies {
                grid.move(to: CGPoint(x: x(frequency), y: 0))
                grid.addLine(to: CGPoint(x: x(frequency), y: size.height))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: middle))
            centerLine.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(centerLine, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)

            var curve = Path()
            for (index, decibels) in response.enumerated() {
                let point = CGPoint(x: x(Self.frequencies[index]), y: y(decibels))
                if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            var area = curve
            area.addLine(to: CGPoint(x: size.width, y: middle))
            area.addLine(to: CGPoint(x: 0, y: middle))
            area.closeSubpath()
            context.fill(area, with: .color(.accentColor.opacity(0.18)))
            context.stroke(curve, with: .color(isFlat ? Color.secondary : Color.accentColor), lineWidth: 1.5)
        }
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 4))
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

/// The plug-ins on one strip, in order. Click one to open its window.
private struct SamplerPluginSlots: View {
    let effects: SamplerEffects
    /// The pad or keyboard, or nil for the master.
    let slot: Int?
    /// Room for this many plug-ins, which can be more than this strip has. Past five, the list scrolls.
    let rows: Int

    private static let rowHeight: CGFloat = 22
    private static let mostRowsShown = 5

    var body: some View {
        VStack(spacing: 3) {
            let chain = effects.chain(for: slot)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(chain) { plugin in
                        HStack(spacing: 4) {
                            Button {
                                effects.openEditor(of: plugin)
                            } label: {
                                Text(verbatim: plugin.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(plugin.isOn ? Color.primary : Color.secondary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(plugin.name)")

                            Button {
                                effects.setOn(!plugin.isOn, for: plugin)
                            } label: {
                                Image(systemName: "power")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(plugin.isOn ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(plugin.isOn ? "Bypass" : "Turn On")
                        }
                        .padding(.horizontal, 6)
                        .frame(height: Self.rowHeight - 3)
                        .background(Color.secondary.opacity(0.16), in: .rect(cornerRadius: 4))
                        .contextMenu {
                            Button("Remove Plug-in") { effects.remove(plugin) }
                        }
                    }
                    // Empty slots, as on a desk, where the other strip has plug-ins this one doesn't.
                    ForEach(chain.count..<max(chain.count, min(rows, Self.mostRowsShown)), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.06))
                            .frame(height: Self.rowHeight - 3)
                    }
                }
            }
            .frame(height: rows == 0 ? 0 : CGFloat(min(rows, Self.mostRowsShown)) * Self.rowHeight - 3, alignment: .top)
            .scrollIndicators(chain.count > Self.mostRowsShown ? .automatic : .never)

            Menu {
                Section("Built-in Effects") {
                    ForEach(SamplerBuiltInEffect.all) { effect in
                        Button(effect.title) { effects.add(effect, to: slot) }
                    }
                }
                if !effects.manufacturers.isEmpty {
                    Section("Audio Units") {
                        ForEach(effects.manufacturers, id: \.self) { manufacturer in
                            Menu(manufacturer) {
                                ForEach(effects.available.filter { $0.manufacturer == manufacturer }) { plugin in
                                    Button(plugin.name) { effects.add(plugin, to: slot) }
                                }
                            }
                        }
                    }
                }
            } label: {
                Text(effects.isAdding ? "Loading…" : "Add Plug-in")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(maxWidth: .infinity)
            .frame(height: Self.rowHeight - 3)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 4))
            .disabled(effects.isAdding)
        }
        .onAppear(perform: effects.findAvailablePlugins)
    }
}

/// A desk-style fader with a scale and a meter beside it. Drag the cap, or double-click it to go back to 0 dB. Above it
/// are the fader's level and the loudest the sound has been, which turns red if it went over and can be clicked to reset.
struct SamplerFader: View {
    let position: Double
    let neutral: Double
    let reading: String
    let level: () -> Float
    let loudest: () -> Float
    let onResetLoudest: () -> Void
    let onChange: (Double) -> Void

    @State private var positionAtDragStart: Double?

    private static let capHeight: CGFloat = 24
    private static let marks: [(decibels: Double, label: String)] = [
        (6, "+6"), (0, "0"), (-6, "-6"), (-12, "-12"), (-24, "-24"), (-48, "-48"),
    ]

    var body: some View {
        let current = level()
        let peak = loudest()

        VStack(spacing: 6) {
            HStack(spacing: 4) {
                readout(reading)
                Button(action: onResetLoudest) {
                    readout(SamplerFaderScale.reading(of: peak), isWarning: peak > 1)
                }
                .buttonStyle(.plain)
                .help("The loudest it has been. Click to start again.")
                .accessibilityLabel(Text("Peak"))
            }

            GeometryReader { geometry in
                let travel = max(geometry.size.height - Self.capHeight, 1)
                HStack(spacing: 4) {
                    track(travel: travel)
                        .frame(width: 34)
                    scale(travel: travel)
                        .frame(width: 22)
                    SamplerMeter(level: current)
                        .frame(width: 7)
                        .padding(.vertical, Self.capHeight / 2)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 120)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Volume"))
        .accessibilityValue(Text(verbatim: "\(reading) dB"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(position + 0.02, 1))
            case .decrement: onChange(max(position - 0.02, 0))
            @unknown default: break
            }
        }
    }

    private func readout(_ text: String, isWarning: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(isWarning ? Color.red : Color.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(isWarning ? Color.red.opacity(0.15) : Color.secondary.opacity(0.14), in: .rect(cornerRadius: 3))
    }

    private func track(travel: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 4)
                .padding(.vertical, Self.capHeight / 2)
                .frame(maxHeight: .infinity)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .controlColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.6))
                    Rectangle().fill(Color.primary.opacity(0.75)).frame(height: 1.5)
                }
                .frame(width: 30, height: Self.capHeight)
                .offset(y: (1 - position) * travel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = positionAtDragStart ?? position
                    positionAtDragStart = start
                    onChange(min(max(start - Double(value.translation.height / travel), 0), 1))
                }
                .onEnded { _ in positionAtDragStart = nil }
        )
        .onTapGesture(count: 2) { onChange(neutral) }
    }

    /// The same scale serves the fader and the meter, so a sound peaking at 0 on the meter lines up with 0 on the fader.
    private func scale(travel: CGFloat) -> some View {
        Canvas { context, size in
            for mark in Self.marks {
                let position = SamplerFaderScale.position(of: Float(pow(10, mark.decibels / 20)))
                let y = Self.capHeight / 2 + (1 - position) * travel
                var tick = Path()
                tick.move(to: CGPoint(x: 0, y: y))
                tick.addLine(to: CGPoint(x: 3, y: y))
                context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 0.5)
                let label = context.resolve(
                    Text(verbatim: mark.label)
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(mark.decibels == 0 ? Color.primary : Color.secondary)
                )
                context.draw(label, at: CGPoint(x: size.width, y: y), anchor: .trailing)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Green up to -12 dB, yellow up to 0 dB, and red above, where it's about to clip. Drawn on the fader's scale.
private struct SamplerMeter: View {
    private static let yellowFrom = SamplerFaderScale.position(of: Float(pow(10, -12.0 / 20)))
    private static let redFrom = SamplerFaderScale.unityPosition

    let level: Float

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(SamplerFaderScale.position(of: level))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.18))
                LinearGradient(
                    stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: Self.yellowFrom - 0.02),
                        .init(color: .yellow, location: Self.yellowFrom + 0.02),
                        .init(color: .yellow, location: Self.redFrom - 0.015),
                        .init(color: .red, location: Self.redFrom + 0.005),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: geometry.size.height * fraction)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A round knob, turned by dragging up and down. Double-click to put it back in its neutral place.
struct SamplerKnobView: View {
    let title: String
    let position: Double
    let neutral: Double
    let reading: String
    let isBeingLearned: Bool
    var diameter: CGFloat = 30
    let onChange: (Double) -> Void

    @State private var positionAtDragStart: Double?

    private static let sweep = 270.0
    private static let startAngle = 135.0
    private static let dragDistanceForFullTurn = 170.0

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: title)
                .font(.system(size: 10))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            dial
                .frame(width: diameter, height: diameter)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = positionAtDragStart ?? position
                            positionAtDragStart = start
                            onChange(min(max(start + (value.translation.width - value.translation.height) / Self.dragDistanceForFullTurn, 0), 1))
                        }
                        .onEnded { _ in positionAtDragStart = nil }
                )
                .onTapGesture(count: 2) { onChange(neutral) }
                .help(reading)

            // An empty reading still keeps its line, so knobs side by side stay the same height.
            Text(verbatim: reading.isEmpty ? " " : reading)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: reading))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(position + 0.05, 1))
            case .decrement: onChange(max(position - 0.05, 0))
            @unknown default: break
            }
        }
    }

    private var dial: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 2.5

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

            let style = StrokeStyle(lineWidth: 2.5, lineCap: .round)
            context.stroke(arc(from: 0, to: 1), with: .color(.secondary.opacity(0.3)), style: style)

            // Knobs with a middle fill outward from it, since either way is a change from neutral.
            let anchor = neutral == 0.5 ? 0.5 : 0
            if position != anchor {
                context.stroke(arc(from: min(anchor, position), to: max(anchor, position)), with: .color(.accentColor), style: style)
            }

            let angle = Angle.degrees(Self.startAngle + position * Self.sweep).radians
            var pointer = Path()
            pointer.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.3, y: center.y + sin(angle) * radius * 0.3))
            pointer.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 0.8, y: center.y + sin(angle) * radius * 0.8))
            context.stroke(pointer, with: .color(.primary), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .overlay {
            if isBeingLearned {
                Circle().strokeBorder(.orange, lineWidth: 2)
            }
        }
    }
}
