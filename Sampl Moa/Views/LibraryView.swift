import SwiftUI

struct LibraryView: View {
    @Bindable var store: LibraryStore

    @State private var filterBarHeight: CGFloat = 0
    @State private var bottomBarHeight: CGFloat = 0

    private var visibleCategories: [SampleCategory] {
        SampleCategory.allCases.filter { store.categoryCounts[$0, default: 0] > 0 || $0 == store.category }
    }

    /// Changes when the user asks for a different list, which should start again from the top.
    private var listIdentity: AnyHashable {
        [
            AnyHashable(store.tab), AnyHashable(store.scope), AnyHashable(store.category),
            AnyHashable(store.genre), AnyHashable(store.searchText),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The list runs the full height of the window, so rows scroll beneath the glass bars above it.
                SampleTable(
                    samples: store.visibleSamples,
                    selection: Set(store.selection.map(\.id)),
                    nowPlaying: store.player.sample?.id,
                    isPlaying: store.player.isPlaying,
                    listIdentity: listIdentity,
                    focusRequest: store.listFocusRequest,
                    collectionTitle: store.tab == .splice ? String(localized: "Pack") : String(localized: "Folder"),
                    topInset: geometry.safeAreaInsets.top + (store.tabSampleCount > 0 ? filterBarHeight : 0),
                    bottomInset: bottomBarHeight,
                    sort: $store.sort,
                    onSelect: store.updateSelection(to:viaKeyboard:),
                    onTogglePlayback: store.togglePlayback(of:),
                    onDownload: store.download,
                    onDoubleClick: store.play
                )
                .ignoresSafeArea(.container, edges: [.top, .bottom])

                if store.visibleSamples.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                }

                VStack(spacing: 0) {
                    if store.tabSampleCount > 0 {
                        filterBar
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { filterBarHeight = $0 }
                    }
                    Spacer(minLength: 0)
                    bottomBar
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { bottomBarHeight = $0 }
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: store.player.sample != nil)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if store.player.sample != nil {
                PlayerBar(player: store.player, onTogglePlayback: store.toggleCurrentPlayback)
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if store.tabSampleCount > 0 {
                Text("Press Space to preview · Drag into your project")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .floatingGlass(cornerRadius: 15)
                    .padding(.bottom, 12)
            }
        }
    }

    /// A scope bar, the standard way to narrow a list on the Mac.
    private var filterBar: some View {
        HStack(alignment: .top, spacing: 12) {
            FlowLayout(spacing: 2) {
                filterButton(title: String(localized: "All"), isOn: store.category == nil) {
                    store.category = nil
                }
                ForEach(visibleCategories) { category in
                    filterButton(title: category.title, isOn: store.category == category) {
                        store.category = category
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Genre", selection: $store.genre) {
                Text("All Genres").tag(SampleGenre?.none)
                Divider()
                ForEach(store.genreCounts, id: \.genre) { entry in
                    Text(verbatim: "\(entry.genre.title)  \(entry.count)").tag(Optional(entry.genre))
                }
                if let genre = store.genre, !store.genreCounts.contains(where: { $0.genre == genre }) {
                    Text(verbatim: genre.title).tag(Optional(genre))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .floatingGlass(cornerRadius: 20)
    }

    private func filterButton(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in action() })) {
            Text(verbatim: title)
        }
        .toggleStyle(.button)
        .buttonStyle(.accessoryBar)
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.tabSampleCount > 0 {
            if !store.searchText.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            } else {
                ContentUnavailableView {
                    Label("No Matching Samples", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Clear Filters", action: store.clearFilters)
                }
            }
        } else if !store.hasFinishedFirstScan || (store.tab == .folders && store.isScanning && !store.folders.isEmpty) {
            ProgressView("Looking for your samples…")
        } else if store.tab == .splice {
            logoMessage(
                title: "No Splice Samples Found",
                detail: "Download samples in the Splice app and they’ll show up here automatically."
            )
        } else if !store.folders.isEmpty {
            logoMessage(
                title: "No Audio Files Found",
                detail: "The folders you added don’t contain any audio files."
            )
        } else {
            logoMessage(
                title: "Add Your Own Samples",
                detail: "Choose a folder and every audio file in it, including subfolders, will appear here."
            )
        }
    }

    private func logoMessage(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                Image("LogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56)
                    .foregroundStyle(.secondary)
            }
        } description: {
            Text(detail)
        } actions: {
            Button("Add Samples…") {
                Task { await store.addFolders() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Lays filter buttons out in rows, wrapping when the window is too narrow for them all.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let origins = origins(for: subviews, width: width)
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let right = zip(origins, sizes).map { $0.x + $1.width }.max() ?? 0
        let bottom = zip(origins, sizes).map { $0.y + $1.height }.max() ?? 0
        return CGSize(width: right, height: bottom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (origin, subview) in zip(origins(for: subviews, width: bounds.width), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func origins(for subviews: Subviews, width: CGFloat) -> [CGPoint] {
        var origins: [CGPoint] = []
        var cursor = CGPoint.zero
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > width {
                cursor = CGPoint(x: 0, y: cursor.y + size.height + spacing)
            }
            origins.append(cursor)
            cursor.x += size.width + spacing
        }
        return origins
    }
}
