import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An AppKit table because dragging is the point of this list: each drag must put a real file URL on the
/// pasteboard, the same way Finder does, for apps like Logic Pro and Premiere Pro to accept the drop.
struct SampleTable: NSViewRepresentable {
    let samples: [Sample]
    let selection: Set<Sample.ID>
    let nowPlaying: Sample.ID?
    let isPlaying: Bool
    let listIdentity: AnyHashable
    let focusRequest: Int
    let collectionTitle: String
    let topInset: CGFloat
    let bottomInset: CGFloat
    @Binding var sort: SampleSort
    let onSelect: ([Sample], Bool) -> Void
    let onTogglePlayback: (Sample) -> Void
    let onDownload: (Sample) -> Void
    let onDoubleClick: (Sample) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SampleScrollView {
        let tableView = SampleTableView()
        tableView.style = .inset
        tableView.rowHeight = 44
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsTypeSelect = false
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        for column in SampleColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minWidth
            tableColumn.headerCell.alignment = column.alignment
            if column == .play {
                tableColumn.resizingMask = []
                tableColumn.maxWidth = column.defaultWidth
            } else {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            }
            tableView.addTableColumn(tableColumn)
        }

        // Set before the delegate so this first assignment doesn't report back as a user's sort.
        tableView.sortDescriptors = [NSSortDescriptor(key: sort.column.rawValue, ascending: sort.ascending)]
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.autosaveName = "SampleColumnsWide"
        tableView.autosaveTableColumns = true
        tableView.onDragStart = { [weak coordinator = context.coordinator] rows, event in
            coordinator?.beginDrag(of: rows, with: event)
        }
        tableView.onDoubleClick = { [weak coordinator = context.coordinator] row in
            coordinator?.doubleClicked(row: row)
        }
        context.coordinator.tableView = tableView

        let scrollView = SampleScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.setInsets(top: topInset, bottom: bottomInset)

        apply(to: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: SampleScrollView, context: Context) {
        scrollView.setInsets(top: topInset, bottom: bottomInset)
        apply(to: context.coordinator)
    }

    private func apply(to coordinator: Coordinator) {
        coordinator.sort = $sort
        coordinator.onSelect = onSelect
        coordinator.onTogglePlayback = onTogglePlayback
        coordinator.onDownload = onDownload
        coordinator.onDoubleClick = onDoubleClick
        coordinator.update(
            samples: samples,
            selection: selection,
            nowPlaying: nowPlaying,
            isPlaying: isPlaying,
            listIdentity: listIdentity,
            focusRequest: focusRequest,
            collectionTitle: collectionTitle
        )
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSDraggingSource {
        weak var tableView: NSTableView?
        var sort: Binding<SampleSort>?
        var onSelect: ([Sample], Bool) -> Void = { _, _ in }
        var onTogglePlayback: (Sample) -> Void = { _ in }
        var onDownload: (Sample) -> Void = { _ in }
        var onDoubleClick: (Sample) -> Void = { _ in }

        private var samples: [Sample] = []
        private var nowPlaying: Sample.ID?
        private var isPlaying = false
        private var listIdentity: AnyHashable?
        private var focusRequest = 0
        private var isApplyingSelection = false

        func update(
            samples newSamples: [Sample],
            selection: Set<Sample.ID>,
            nowPlaying: Sample.ID?,
            isPlaying: Bool,
            listIdentity: AnyHashable,
            focusRequest: Int,
            collectionTitle: String
        ) {
            guard let tableView else { return }

            let listChanged = newSamples.count != samples.count || newSamples.map(\.id) != samples.map(\.id)
            let rowsChanged = newSamples != samples || nowPlaying != self.nowPlaying || isPlaying != self.isPlaying
            samples = newSamples
            self.nowPlaying = nowPlaying
            self.isPlaying = isPlaying

            let collectionColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(SampleColumn.collection.rawValue))
            if collectionColumn?.title != collectionTitle { collectionColumn?.title = collectionTitle }

            if listChanged {
                tableView.reloadData()
            } else if rowsChanged {
                // Lengths and play state change while the user may be mid-drag, so visible rows update in place.
                refreshVisibleRows(in: tableView)
            }

            if listIdentity != self.listIdentity {
                if self.listIdentity != nil, !samples.isEmpty { tableView.scrollRowToVisible(0) }
                self.listIdentity = listIdentity
            }
            apply(selection: selection, to: tableView)

            if focusRequest != self.focusRequest {
                self.focusRequest = focusRequest
                tableView.window?.makeFirstResponder(tableView)
            }
        }

        private func refreshVisibleRows(in tableView: NSTableView) {
            tableView.enumerateAvailableRowViews { rowView, row in
                for columnIndex in 0..<tableView.numberOfColumns {
                    if let cell = rowView.view(atColumn: columnIndex) as? NSTableCellView {
                        configure(cell, row: row)
                    }
                }
            }
        }

        private func apply(selection: Set<Sample.ID>, to tableView: NSTableView) {
            let rows = selection.isEmpty
                ? IndexSet()
                : IndexSet(samples.indices.filter { selection.contains(samples[$0].id) })
            guard rows != tableView.selectedRowIndexes else { return }

            isApplyingSelection = true
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            isApplyingSelection = false
            if let row = rows.first { tableView.scrollRowToVisible(row) }
        }

        private func configure(_ cell: NSTableCellView, row: Int) {
            let sample = samples[row]
            let isCurrent = sample.id == nowPlaying

            if let cell = cell as? PlayCell {
                cell.configure(availability: sample.availability, isCurrent: isCurrent, isPlaying: isCurrent && isPlaying)
                cell.onPress = { [weak self] in
                    if sample.availability == .inCloud {
                        self?.onDownload(sample)
                    } else {
                        self?.onTogglePlayback(sample)
                    }
                }
            } else if let cell = cell as? SampleTextCell {
                cell.configure(with: sample, isCurrent: isCurrent)
            }
        }

        func doubleClicked(row: Int) {
            onDoubleClick(samples[row])
        }

        // MARK: Table

        func numberOfRows(in tableView: NSTableView) -> Int {
            samples.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = SampleColumn(rawValue: tableColumn.identifier.rawValue) else {
                return nil
            }

            let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView
            let cell = reused ?? (column == .play ? PlayCell() : SampleTextCell(column: column))
            cell.identifier = tableColumn.identifier
            configure(cell, row: row)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let viaKeyboard = (tableView as? SampleTableView)?.isHandlingKeyPress ?? false
            onSelect(tableView.selectedRowIndexes.map { samples[$0] }, viaKeyboard)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let column = descriptor.key.flatMap(SampleColumn.init(rawValue:))
            else { return }
            sort?.wrappedValue = SampleSort(column: column, ascending: descriptor.ascending)
        }

        // MARK: Dragging

        func beginDrag(of rows: IndexSet, with event: NSEvent) {
            guard let tableView else { return }

            // The app it's dropped on will need the file, so one that's only in the cloud starts coming down now.
            rows.forEach { onDownload(samples[$0]) }

            let point = tableView.convert(event.locationInWindow, from: nil)
            let items = rows.map { row -> NSDraggingItem in
                let image = dragImage(for: samples[row])
                let item = NSDraggingItem(pasteboardWriter: samples[row].url as NSURL)
                let origin = NSPoint(x: point.x - 20, y: point.y - image.size.height / 2)
                item.setDraggingFrame(NSRect(origin: origin, size: image.size), contents: image)
                return item
            }
            let session = tableView.beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = .pile
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // Copy only. Allowing a move would let a drop on Finder pull the file out of the Splice folder.
            context == .outsideApplication ? .copy : []
        }

        /// A file icon and name, the same thing people see when dragging from Finder.
        private func dragImage(for sample: Sample) -> NSImage {
            let title = NSAttributedString(string: sample.name, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
            ])
            let icon = NSWorkspace.shared.icon(for: .audio)
            let size = NSSize(width: min(title.size().width, 300) + 30, height: 22)

            return NSImage(size: size, flipped: false) { rect in
                icon.draw(in: NSRect(x: 0, y: 1, width: 20, height: 20))
                title.draw(with: NSRect(x: 24, y: 4, width: rect.width - 26, height: 16), options: [
                    .usesLineFragmentOrigin, .truncatesLastVisibleLine,
                ])
                return true
            }
        }
    }
}

/// Handles presses itself so a drag always carries the row the user pressed. `NSTableView`'s own handling picks
/// the row under the first drag event instead, so a quick downward flick grabs the sample below.
private final class SampleTableView: NSTableView {
    var onDragStart: ((IndexSet, NSEvent) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    /// True while an arrow key is moving the selection, as opposed to a click.
    private(set) var isHandlingKeyPress = false

    private var hasTakenInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Otherwise a search field takes focus at launch.
        guard let window, !hasTakenInitialFocus else { return }
        hasTakenInitialFocus = true
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        isHandlingKeyPress = true
        super.keyDown(with: event)
        isHandlingKeyPress = false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let start = convert(event.locationInWindow, from: nil)
        let pressedRow = row(at: start)
        guard pressedRow >= 0, event.modifierFlags.isDisjoint(with: [.command, .shift]) else {
            super.mouseDown(with: event)
            return
        }

        let wasSelected = selectedRowIndexes.contains(pressedRow)
        if !wasSelected {
            selectRowIndexes(IndexSet(integer: pressedRow), byExtendingSelection: false)
        }
        if event.clickCount == 2 {
            onDoubleClick?(pressedRow)
            return
        }

        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                // A plain click on one of several selected rows narrows the selection to it, as in Finder.
                if wasSelected, selectedRowIndexes.count > 1 {
                    selectRowIndexes(IndexSet(integer: pressedRow), byExtendingSelection: false)
                }
                return
            }

            let location = convert(next.locationInWindow, from: nil)
            if hypot(location.x - start.x, location.y - start.y) >= 4 {
                onDragStart?(selectedRowIndexes, event)
                return
            }
        }
    }
}

/// Gives the name column whatever width the other columns leave, so the table always fits its window.
final class SampleScrollView: NSScrollView {
    private var fittedWidth: CGFloat = 0

    /// Keeps rows clear of the toolbar and the glass bars at rest, while letting them scroll underneath.
    func setInsets(top: CGFloat, bottom: CGFloat) {
        guard top != contentInsets.top || bottom != contentInsets.bottom else { return }
        contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    }

    override func layout() {
        super.layout()

        let width = contentView.bounds.width
        guard width != fittedWidth,
              let tableView = documentView as? NSTableView,
              let nameColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(SampleColumn.name.rawValue))
        else { return }

        fittedWidth = width
        let inset = tableView.rect(ofColumn: 0).minX
        let end = tableView.rect(ofColumn: tableView.numberOfColumns - 1).maxX
        nameColumn.width = max(nameColumn.minWidth, nameColumn.width + width - end - inset)
    }
}

private final class SampleTextCell: NSTableCellView {
    private let column: SampleColumn
    private var isCurrent = false

    init(column: SampleColumn) {
        self.column = column
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = column.alignment
        label.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        label.font = switch column {
        case .name: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        case .length: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        default: .systemFont(ofSize: NSFont.systemFontSize)
        }
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColor() }
    }

    func configure(with sample: Sample, isCurrent: Bool) {
        self.isCurrent = isCurrent
        textField?.stringValue = column.text(for: sample)
        toolTip = column == .name ? String(localized: "Drag into your project") : nil
        refreshColor()
    }

    private func refreshColor() {
        if backgroundStyle == .emphasized {
            textField?.textColor = .alternateSelectedControlTextColor
        } else if column == .name {
            textField?.textColor = isCurrent ? .controlAccentColor : .labelColor
        } else {
            textField?.textColor = .secondaryLabelColor
        }
    }
}

private final class PlayCell: NSTableCellView {
    var onPress: (() -> Void)?

    private let button = NSButton()
    private let spinner = NSProgressIndicator()
    private var availability = SampleAvailability.onThisMac
    private var isCurrent = false
    private var isPlaying = false

    init() {
        super.init(frame: .zero)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.target = self
        button.action = #selector(pressed)
        addSubview(button)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.toolTip = String(localized: "Downloading from iCloud…")
        addSubview(spinner)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refresh() }
    }

    func configure(availability: SampleAvailability, isCurrent: Bool, isPlaying: Bool) {
        self.availability = availability
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        refresh()
    }

    private func refresh() {
        let isDownloading = availability == .downloading
        button.isHidden = isDownloading
        if isDownloading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        let symbol: String
        let label: String
        switch (availability, isPlaying) {
        case (.inCloud, _), (.downloading, _):
            symbol = "icloud.and.arrow.down"
            label = String(localized: "Download from iCloud")
        case (.onThisMac, true):
            symbol = "pause.fill"
            label = String(localized: "Pause")
        case (.onThisMac, false):
            symbol = "play.fill"
            label = String(localized: "Play")
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.toolTip = availability == .onThisMac ? String(localized: "Play (Space)") : label

        if backgroundStyle == .emphasized {
            button.contentTintColor = .alternateSelectedControlTextColor
        } else if isCurrent {
            button.contentTintColor = .controlAccentColor
        } else {
            button.contentTintColor = .secondaryLabelColor
        }
    }

    @objc private func pressed() {
        onPress?()
    }
}

private extension SampleColumn {
    var defaultWidth: CGFloat {
        switch self {
        case .play: 38
        case .name: 340
        case .collection: 190
        case .category: 84
        case .genre: 110
        case .length: 48
        case .added: 92
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .play: 38
        case .name: 180
        case .collection: 70
        case .category, .genre, .added: 50
        case .length: 40
        }
    }

    var alignment: NSTextAlignment {
        self == .length ? .right : .left
    }

    func text(for sample: Sample) -> String {
        switch self {
        case .play: return ""
        case .name: return sample.name
        case .collection: return sample.collection
        case .category: return sample.category.title
        case .genre: return sample.genres.first?.title ?? "–"
        case .length: return sample.duration.map(formattedLength) ?? "–"
        case .added:
            return sample.addedAt == .distantPast ? "–" : sample.addedAt.formatted(date: .numeric, time: .omitted)
        }
    }
}
