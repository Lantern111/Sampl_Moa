import SwiftUI

struct ContentView: View {
    let store: LibraryStore

    var body: some View {
        Group {
            if store.hasAccess {
                LibraryView(store: store)
            } else {
                OnboardingView(store: store)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}

#Preview {
    ContentView(store: LibraryStore())
}
