import Combine
import Sparkle
import SwiftUI

/// The menu command that looks for a new version. It's dimmed while a check is already running.
struct CheckForUpdatesButton: View {
    let updater: SPUUpdater

    @StateObject private var availability = UpdateAvailability()

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!availability.canCheck)
            .onAppear { availability.follow(updater) }
    }
}

private final class UpdateAvailability: ObservableObject {
    @Published var canCheck = false

    func follow(_ updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }
}
