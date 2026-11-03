import SwiftUI

/// Shown on first launch, and again if macOS no longer honors the saved folder permission.
struct OnboardingView: View {
    let store: LibraryStore

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.tint)

                Text("Welcome to Sampl Moa")
                    .font(.largeTitle.bold())

                Text("Sampl Moa needs permission to read your user folder so it can gather the samples from all of your Splice accounts in one place.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    symbol: "folder",
                    title: "Finds every Splice folder",
                    detail: "Looks only for the Splice and Splice - user-… folders in your user folder."
                )
                PermissionRow(
                    symbol: "lock",
                    title: "Read-only",
                    detail: "Your samples are never changed, moved or deleted."
                )
                PermissionRow(
                    symbol: "laptopcomputer",
                    title: "Stays on your Mac",
                    detail: "Sampl Moa doesn’t use the network, so nothing is uploaded."
                )
            }

            VStack(spacing: 10) {
                Button("Choose User Folder") {
                    Task { await store.chooseFolder() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Text("Your user folder will already be selected in the next window. Just click Allow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let problem = store.accessProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: 460)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    OnboardingView(store: LibraryStore())
}
