import AppKit
import Sparkle
import SwiftUI

struct SettingsView: View {
    let updater: SPUUpdater

    @State private var language = AppLanguage.saved

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                Text("Same as System").tag(AppLanguage.system)
                // Each in its own language, so people can find theirs whatever the app is showing now.
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "한국어").tag(AppLanguage.korean)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: language) {
                language.save()
            }

            if language != AppLanguage.inUse {
                HStack {
                    Text("Restart Sampl Moa to use the new language.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now", action: restart)
                }
            }

            AutomaticUpdatesToggle(updater: updater)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = NSApp.isActive
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NSAlert(error: error).runModal()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
