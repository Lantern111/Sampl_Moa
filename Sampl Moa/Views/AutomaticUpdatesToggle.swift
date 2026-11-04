import Combine
import Sparkle
import SwiftUI

/// Lets people choose whether new versions download and install on their own. Sparkle remembers the choice.
struct AutomaticUpdatesToggle: View {
    let updater: SPUUpdater

    @State private var isOn = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Download and install updates automatically")
                Text("New versions install when you quit Sampl Moa.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(updater.publisher(for: \.automaticallyDownloadsUpdates)) { isOn = $0 }
        .onChange(of: isOn) {
            // Sparkle treats every write as the person's choice, so only write when it actually changed.
            if updater.automaticallyDownloadsUpdates != isOn {
                updater.automaticallyDownloadsUpdates = isOn
            }
        }
    }
}
