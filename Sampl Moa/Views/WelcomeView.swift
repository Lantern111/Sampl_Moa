import AppKit
import SwiftUI

/// Explains the app in a few lines. Shown once on first launch, and again from the Help menu.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                Text("Welcome to Sampl Moa")
                    .font(.largeTitle.bold())
                Text("All your samples in one place, ready to hear and use.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 20) {
                feature(
                    "Finds Your Samples Automatically",
                    detail: "Samples you’ve downloaded with Splice show up on their own. There’s nothing to set up.",
                    systemImage: "square.stack.3d.up"
                )
                feature(
                    "Add Your Own Folders",
                    detail: "Click Add Samples and choose a folder. All its audio files, including subfolders, appear under My Folders.",
                    systemImage: "folder.badge.plus"
                )
                feature(
                    "Listen with the Keyboard",
                    detail: "Press Space to play. ↓ or → moves to the next sample, and ← plays it again from the start.",
                    systemImage: "play.circle"
                )
                feature(
                    "Drag into Your Project",
                    detail: "Drop a sample straight into Logic Pro, Final Cut Pro, Premiere Pro, or After Effects.",
                    systemImage: "hand.draw"
                )
            }

            Button {
                dismiss()
            } label: {
                Text("Get Started")
                    .frame(minWidth: 160)
            }
            .prominentGlassButton()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(width: 580)
    }

    private func feature(_ title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
