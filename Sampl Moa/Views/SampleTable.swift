import AppKit
import SwiftUI

/// An AppKit table because dragging is the point of this list: each dragged row must put a real file URL on
/// the pasteboard, the same way Finder does, for apps like Logic Pro and Premiere Pro to accept the drop.
struct SampleTable: NSViewRepresentable {
    let samples: [Sample]
    @Binding var sort: SampleSort

    func makeCoordinator() -> Coordinator {
        Coordinator(sort: $sort)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = SampleTableView()
        tableView.style = .fullWidth
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // Copy only. Allowing a move would let a drop on Finder pull the file out of the Splice folder.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        for column in SampleColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableColumn.headerCell.alignment = column.alignment
            tableView.addTableColumn(tableColumn)
        }

        // Set before the delegate so this first assignment doesn't report back as a user's sort.
        tableView.sortDescriptors = [NSSortDescriptor(key: sort.column.rawValue, ascending: sort.ascending)]
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.autosaveName = "SampleTable"
        tableView.autosaveTableColumns = true
        context.coordinator.tableView = tableView

        let scrollView = SampleScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        context.coordinator.update(samples)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(samples)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?

        private var samples: [Sample] = []
        private let sort: Binding<SampleSort>

        init(sort: Binding<SampleSort>) {
            self.sort = sort
        }

        func update(_ newSamples: [Sample]) {
            guard newSamples != samples, let tableView else { return }

            let previousSamples = samples
            samples = newSamples

            if newSamples.map(\.id) == previousSamples.map(\.id) {
                reloadDurations(in: tableView)
            } else {
                reloadKeepingSelection(in: tableView, previousSamples: previousSamples)
            }
        }

        /// Lengths arrive in batches while the user may be mid-drag, so this leaves everything else alone.
        private func reloadDurations(in tableView: NSTableView) {
            let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(SampleColumn.duration.rawValue))
            guard column >= 0, let rows = Range(tableView.rows(in: tableView.visibleRect)) else { return }
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows), columnIndexes: IndexSet(integer: column))
        }

        private func reloadKeepingSelection(in tableView: NSTableView, previousSamples: [Sample]) {
            let selectedIDs = Set(tableView.selectedRowIndexes.map { previousSamples[$0].id })
            tableView.reloadData()

            guard !selectedIDs.isEmpty else { return }
            let rows = samples.indices.filter { selectedIDs.contains(samples[$0].id) }
            tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            samples.count
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            samples[row].url as NSURL
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = SampleColumn(rawValue: tableColumn.identifier.rawValue) else {
                return nil
            }

            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? SampleCell
                ?? SampleCell(column: column)
            cell.identifier = tableColumn.identifier
            cell.textField?.stringValue = column.text(for: samples[row])
            cell.toolTip = column == .name ? samples[row].url.lastPathComponent : nil
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let column = descriptor.key.flatMap(SampleColumn.init(rawValue:))
            else { return }
            sort.wrappedValue = SampleSort(column: column, ascending: descriptor.ascending)
        }
    }
}

/// Gives the name column whatever width the other columns leave, so the table always fits its window.
/// AppKit's own column autoresizing can't do this: it also squeezes the other columns while SwiftUI is still
/// settling on a size, and those squeezed widths then get saved.
private final class SampleScrollView: NSScrollView {
    private var fittedWidth: CGFloat = 0

    override func layout() {
        super.layout()

        let width = contentView.bounds.width
        guard width != fittedWidth,
              let tableView = documentView as? NSTableView,
              let nameColumn = tableView.tableColumns.first(where: { $0.identifier.rawValue == SampleColumn.name.rawValue })
        else { return }

        fittedWidth = width
        let spacing = tableView.intercellSpacing.width * CGFloat(tableView.numberOfColumns)
        let otherColumns = tableView.tableColumns.filter { $0 !== nameColumn }.reduce(0) { $0 + $1.width }
        nameColumn.width = max(nameColumn.minWidth, width - otherColumns - spacing)
    }
}

/// `NSTableView` picks the dragged row from where the first drag event lands, so a quick downward flick
/// would grab the sample below the one the user pressed. This pins that lookup to the pressed row.
private final class SampleTableView: NSTableView {
    private var pressedRow: Int?

    override func mouseDown(with event: NSEvent) {
        let pressed = row(at: convert(event.locationInWindow, from: nil))
        pressedRow = pressed >= 0 ? pressed : nil
        super.mouseDown(with: event)
        pressedRow = nil
    }

    override func row(at point: NSPoint) -> Int {
        pressedRow ?? super.row(at: point)
    }
}

private final class SampleCell: NSTableCellView {
    init(column: SampleColumn) {
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = column.alignment
        label.lineBreakMode = .byTruncatingTail
        label.textColor = column == .name ? .labelColor : .secondaryLabelColor
        if column.alignment == .right {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        addSubview(label)
        textField = label

        var leadingAnchor = self.leadingAnchor
        if column == .name {
            let icon = NSImageView(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage())
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentTintColor = .secondaryLabelColor
            addSubview(icon)
            imageView = icon

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
            ])
            leadingAnchor = icon.trailingAnchor
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension SampleColumn {
    var defaultWidth: CGFloat {
        switch self {
        case .name: 240
        case .pack: 200
        case .account: 130
        case .duration, .format: 56
        case .size: 72
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: 140
        case .pack, .account: 90
        case .duration, .format, .size: 48
        }
    }

    var alignment: NSTextAlignment {
        switch self {
        case .duration, .size: .right
        case .name, .pack, .account, .format: .left
        }
    }

    func text(for sample: Sample) -> String {
        switch self {
        case .name: return sample.name
        case .pack: return sample.pack
        case .account: return sample.accountName
        case .format: return sample.format
        case .size: return ByteCountFormatter.string(fromByteCount: sample.fileSize, countStyle: .file)
        case .duration:
            guard let duration = sample.duration else { return "–" }
            let seconds = Int(duration.rounded(.up))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }
}
