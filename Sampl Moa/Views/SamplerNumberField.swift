import AppKit
import SwiftUI

/// A number typed in, like a tempo. What's typed stays as typed until Return, Tab, or clicking anywhere else, so
/// neither the value changing meanwhile nor the screen redrawing as the music plays can get mixed into it. Clicking in
/// selects the whole number, so typing replaces it, and Escape puts it back.
///
/// AppKit's own text field, because SwiftUI's leaves the cursor where the click landed, inside the old number, and
/// keeps what's typed until something else takes the focus.
struct SamplerNumberField: NSViewRepresentable {
    let value: Double?
    let range: ClosedRange<Double>
    /// Whether it can be left empty, which gives nil.
    var allowsEmpty = false
    let onCommit: (Double?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.placeholderString = "–"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = Self.format(value)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        let size = NSControl.ControlSize(context.environment.controlSize)
        if field.controlSize != size {
            field.controlSize = size
            field.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        }
        field.alignment = switch context.environment.multilineTextAlignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
        // While typing, the number shown is the one being typed.
        if !field.isEditing, field.stringValue != Self.format(value) {
            field.stringValue = Self.format(value)
        }
    }

    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        coordinator.stopWatchingClicks()
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%g", (value * 100).rounded() / 100)
    }

    final class Field: NSTextField {
        var isEditing: Bool { currentEditor() != nil }

        private var clickStartedTyping = false

        /// The window gives the field the focus before the click reaches it.
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            clickStartedTyping = became && NSApp.currentEvent?.type == .leftMouseDown
            return became
        }

        /// AppKit puts the cursor where the click lands once the click is over, so the whole number is selected after.
        /// Clicks once typing has started go to the text itself, so placing the cursor still works then.
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if clickStartedTyping { currentEditor()?.selectAll(nil) }
            clickStartedTyping = false
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SamplerNumberField
        weak var field: Field?
        private var clickMonitor: Any?

        init(_ parent: SamplerNumberField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            watchClicks()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            stopWatchingClicks()
            commit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Return finishes, so the sampler's keys work again straight after.
                finishTyping()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard let field else { return false }
                field.abortEditing()
                stopWatchingClicks()
                field.stringValue = SamplerNumberField.format(parent.value)
                field.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        /// Clicking anywhere else counts as done, as it does in Logic, rather than leaving the number half typed.
        private func watchClicks() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, let field = self.field else { return event }
                let isInField = event.window === field.window
                    && field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                if !isInField { self.finishTyping() }
                return event
            }
        }

        func stopWatchingClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        private func finishTyping() {
            guard let field, field.isEditing, let window = field.window else { return }
            // Ending the typing commits it, in controlTextDidEndEditing.
            if !window.makeFirstResponder(nil) { window.endEditing(for: nil) }
        }

        private func commit() {
            guard let field else { return }
            let value = parent.value
            let typed = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if typed.isEmpty, parent.allowsEmpty {
                if value != nil { parent.onCommit(nil) }
                return
            }
            guard let number = Double(typed), parent.range.contains(number) else {
                if typed != SamplerNumberField.format(value) { NSSound.beep() }
                field.stringValue = SamplerNumberField.format(value)
                return
            }
            let rounded = (number * 100).rounded() / 100
            field.stringValue = SamplerNumberField.format(rounded)
            if rounded != value { parent.onCommit(rounded) }
        }
    }
}

private extension NSControl.ControlSize {
    init(_ size: ControlSize) {
        self = switch size {
        case .mini: .mini
        case .small: .small
        case .regular: .regular
        case .large: .large
        default: .regular
        }
    }
}
