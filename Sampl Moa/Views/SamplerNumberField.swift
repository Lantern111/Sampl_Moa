import AppKit
import SwiftUI

/// A number typed in, like a tempo. What's typed stays as typed until Return or clicking away, so neither the value
/// changing meanwhile nor the screen redrawing as the music plays can get mixed into it. Clicking in selects the whole
/// number, so typing replaces it, and Escape puts it back.
struct SamplerNumberField: View {
    let value: Double?
    let range: ClosedRange<Double>
    /// Whether it can be left empty, which gives nil.
    var allowsEmpty = false
    let onCommit: (Double?) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(verbatim: "–"))
            .focused($isFocused)
            .onAppear { text = Self.format(value) }
            .onChange(of: value) {
                if !isFocused { text = Self.format(value) }
            }
            .onChange(of: isFocused) {
                if isFocused {
                    // After the click that focused it has placed the cursor.
                    DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
                } else {
                    commit()
                }
            }
            .onSubmit {
                commit()
                // Return finishes, so the sampler's keys work again straight after.
                isFocused = false
            }
            .onExitCommand {
                text = Self.format(value)
                isFocused = false
            }
    }

    private func commit() {
        let typed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if typed.isEmpty, allowsEmpty {
            onCommit(nil)
            return
        }
        guard let number = Double(typed), range.contains(number) else {
            if typed != Self.format(value) { NSSound.beep() }
            text = Self.format(value)
            return
        }
        let rounded = (number * 100).rounded() / 100
        text = Self.format(rounded)
        if rounded != value { onCommit(rounded) }
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%g", (value * 100).rounded() / 100)
    }
}
