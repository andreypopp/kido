import SwiftUI
import AppKit

private final class TranscriptCell: NSTableCellView {
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    var resized: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        host.view.autoresizingMask = [.width, .height]
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout(); host.view.frame = bounds
        DispatchQueue.main.async { [weak self] in self?.resized?() }
    }
    override var fittingSize: NSSize { host.sizeThatFits(in: NSSize(width: frame.width, height: .greatestFiniteMagnitude)) }
}

private final class TranscriptNativeTable: NSTableView {
    var resized: (() -> Void)?
    override func setFrameSize(_ size: NSSize) {
        let changed = frame.width != size.width
        super.setFrameSize(size)
        if changed { DispatchQueue.main.async { [weak self] in self?.resized?() } }
    }
}

struct TranscriptTable: NSViewRepresentable {
    let scope: String
    let rows: [DisplayRow]
    let expanded: Bool
    let tailRequest: Int
    @Binding var following: Bool
    var loadHistory: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let table = TranscriptNativeTable()
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.headerView = nil
        table.usesAutomaticRowHeights = false
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.table = table
        table.resized = { [weak coordinator = context.coordinator, weak scroll] in
            if let coordinator, let scroll { coordinator.update(coordinator.parent, scroll: scroll) }
        }
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator, !coordinator.updating else { return }
                if let event = NSApp.currentEvent, [.scrollWheel, .keyDown, .leftMouseDragged].contains(event.type) { coordinator.readAnchor = nil }
                coordinator.parent.following = table.bounds.height - scroll.contentView.bounds.maxY < 48
            }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self, scroll: scroll) }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) } }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: TranscriptTable
        weak var table: NSTableView?
        var rows: [DisplayRow] = []
        var heights: [String: CGFloat] = [:]
        var width: CGFloat = 0
        var observer: NSObjectProtocol?
        var updating = false
        var expansions = Set<String>()
        var readAnchor: (String, CGFloat)?
        var tailRequest = -1
        init(_ parent: TranscriptTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { heights[rows[row].id] ?? 44 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("message")
            let host = tableView.makeView(withIdentifier: identifier, owner: self) as? TranscriptCell ?? TranscriptCell(frame: .zero)
            host.identifier = identifier
            let item = rows[row]
            host.host.rootView = AnyView(MessageView(row: item, expanded: expansions.contains(item.id) || parent.expanded, loadHistory: parent.loadHistory, expansionChanged: { [weak self, weak host] open in
                    if open { self?.expansions.insert(item.id) } else { self?.expansions.remove(item.id) }
                    DispatchQueue.main.async { host?.resized?() }
                }).id(item.id)
                .disclosureGroupStyle(InlineDisclosureStyle())
                .frame(width: max(1, min(tableView.bounds.width - 32, 760)), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8).frame(width: max(1, tableView.bounds.width))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak host] _ in
                    DispatchQueue.main.async { host?.resized?() }
                })
            host.frame.size.width = tableView.bounds.width
            host.resized = { [weak self, weak host, weak tableView] in
                guard let self, let host, let tableView, let index = self.rows.firstIndex(where: { $0.id == item.id }) else { return }
                let height = max(32, host.fittingSize.height)
                guard self.heights[item.id] != height else { return }
                let scroll = tableView.enclosingScrollView
                var visible = max(0, tableView.row(at: scroll?.contentView.bounds.origin ?? .zero))
                if self.rows.indices.contains(visible), case .history = self.rows[visible].content { visible = min(visible + 1, self.rows.count - 1) }
                let anchor = self.rows.indices.contains(visible) ? self.rows[visible].id : nil
                let offset = (scroll?.contentView.bounds.origin.y ?? 0) - tableView.rect(ofRow: visible).minY
                self.heights[item.id] = height; self.updating = true
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
                if self.parent.following { self.bottom() }
                else if !self.restoreAnchor(), let scroll, let anchor, let row = self.rows.firstIndex(where: { $0.id == anchor }) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: row).minY + offset)); scroll.reflectScrolledClipView(scroll.contentView)
                }
                self.updating = false
            }
            let height = max(32, host.fittingSize.height)
            if heights[item.id] != height {
                heights[item.id] = height
                DispatchQueue.main.async { [weak self, weak tableView] in
                    guard let self, let tableView, row < self.rows.count, self.rows[row].id == item.id else { return }
                    let scroll = tableView.enclosingScrollView
                    let origin = scroll?.contentView.bounds.origin ?? .zero
                    self.updating = true
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                    if self.parent.following { self.bottom() }
                    else if !self.restoreAnchor() { scroll?.contentView.scroll(to: origin); if let scroll { scroll.reflectScrolledClipView(scroll.contentView) } }
                    self.updating = false
                }
            }
            return host
        }
        func update(_ value: TranscriptTable, scroll: NSScrollView) {
            guard let table else { return }
            updating = true
            let old = rows
            var visible = max(0, table.row(at: scroll.contentView.bounds.origin))
            if old.indices.contains(visible), case .history = old[visible].content { visible = min(visible + 1, old.count - 1) }
            let anchor = old.indices.contains(visible) ? old[visible].id : nil
            let offset = old.indices.contains(visible) ? scroll.contentView.bounds.origin.y - table.rect(ofRow: visible).minY : 0
            let initial = rows.isEmpty
            let generationChanged = parent.scope != value.scope
            let follow = parent.following || value.tailRequest != tailRequest || initial || generationChanged
            if generationChanged { DispatchQueue.main.async { [weak self] in self?.parent.following = true } }
            parent = value; tailRequest = value.tailRequest
            let resized = width != table.bounds.width || parent.expanded != value.expanded
            if resized { width = table.bounds.width; heights.removeAll() }
            rows = value.rows
            let oldIDs = old.map(\.id), newIDs = rows.map(\.id)
            if follow { readAnchor = nil }
            else if oldIDs != newIDs, let anchor { readAnchor = (anchor, offset) }
            if oldIDs != newIDs {
                let prefix = zip(oldIDs, newIDs).prefix { $0 == $1 }.count
                let suffix = zip(oldIDs.dropFirst(prefix).reversed(), newIDs.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
                table.beginUpdates()
                if old.count - suffix > prefix { table.removeRows(at: IndexSet(integersIn: prefix..<(old.count - suffix)), withAnimation: []) }
                if rows.count - suffix > prefix { table.insertRows(at: IndexSet(integersIn: prefix..<(rows.count - suffix)), withAnimation: []) }
                table.endUpdates()
                let ids = Set(newIDs)
                heights = heights.filter { ids.contains($0.key) }; expansions.formIntersection(ids)
            }
            let changed = IndexSet(rows.indices.filter { index in index < old.count && rows[index].id == old[index].id && rows[index] != old[index] })
            for index in changed { heights[rows[index].id] = nil }
            if resized { table.reloadData() }
            else if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)); table.noteHeightOfRows(withIndexesChanged: changed) }
            if follow { bottom() }
            else if !restoreAnchor(), let anchor, let index = rows.firstIndex(where: { $0.id == anchor }) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: index).minY + offset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            updating = false
        }
        func restoreAnchor() -> Bool {
            guard let table, let scroll = table.enclosingScrollView, let (id, offset) = readAnchor, let row = rows.firstIndex(where: { $0.id == id }) else { return false }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row).minY + offset)); scroll.reflectScrolledClipView(scroll.contentView)
            return true
        }
        func bottom() {
            guard let table, let scroll = table.enclosingScrollView else { return }
            table.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, table.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
