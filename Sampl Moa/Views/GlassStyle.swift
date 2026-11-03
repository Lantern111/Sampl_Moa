import SwiftUI

/// Liquid Glass where the system has it (macOS 26 and later), and the closest standard material elsewhere.
extension View {
    /// For a bar of controls that floats above the content.
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator)
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }

    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.borderless)
        }
    }
}
