import SwiftUI
import AppKit

private final class TranscriptScrollView: NSScrollView {
    var resized: (() -> Void)?
    override func setFrameSize(_ size: NSSize) {
        let changed = frame.width != size.width
        super.setFrameSize(size)
        if changed { resized?() }
    }
}

struct TranscriptTable: NSViewRepresentable {
    let scope: String
    let rows: [DisplayRow]
    let revision: Int, structure: Int
    let changed: Set<String>
    var applied: (Set<String>) -> Void
    let expanded: Bool
    let tailRequest: Int
    @Binding var following: Bool
    var loadHistory: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TranscriptScrollView(), table = NSTableView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let column = NSTableColumn(identifier: .init("transcript")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.usesAutomaticRowHeights = false; table.autoresizingMask = [.width]
        table.backgroundColor = .clear; table.selectionHighlightStyle = .none; table.style = .plain
        table.intercellSpacing = .zero; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        scroll.resized = { [weak coordinator = context.coordinator] in coordinator?.resize() }
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator else { return }
                coordinator.readAnchor = nil
                coordinator.parent.following = table.bounds.height - scroll.contentView.bounds.maxY < 48
            }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) } }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: TranscriptTable
        weak var table: NSTableView?
        var rows: [DisplayRow] = []
        var positions: [String: Int] = [:]
        var heights: [String: [CGFloat: CGFloat]] = [:]
        var pending = Set<String>(), resizePending = false
        var observer: NSObjectProtocol?
        var expansions = Set<String>()
        var readAnchor: (String, CGFloat)?
        var tailRequest = -1
        init(_ parent: TranscriptTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { heights[rows[row].id]?[tableView.bounds.width] ?? heights[rows[row].id]?.values.first ?? 44 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("message")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSHostingView<AnyView> ?? NSHostingView(rootView: AnyView(EmptyView()))
            cell.identifier = id; configure(cell, row: row); return cell
        }
        func expansionChanged(_ id: String, open: Bool) {
            if open { expansions.insert(id) } else { expansions.remove(id) }
            readAnchor = nil
            guard !parent.following, let table, let scroll = table.enclosingScrollView, let row = positions[id] else { return }
            if table.rect(ofRow: row).minY >= scroll.contentView.bounds.minY {
                readAnchor = (id, scroll.contentView.bounds.minY - table.rect(ofRow: row).minY)
            } else { captureAnchor() }
        }
        private func configure(_ cell: NSHostingView<AnyView>, row: Int) {
            guard let table else { return }
            let item = rows[row], width = table.bounds.width
            cell.sizingOptions = []; cell.autoresizingMask = [.width, .height]
            cell.rootView = AnyView(MessageView(row: item, expanded: expansions.contains(item.id) || parent.expanded, loadHistory: parent.loadHistory, expansionChanged: { [weak self] open in
                self?.expansionChanged(item.id, open: open)
            }).id(item.id).disclosureGroupStyle(InlineDisclosureStyle())
                .frame(width: max(1, width - 24), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 12).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    self?.measured(item, width: width, height: ceil(max(32, size.height)))
                })
            cell.frame.size.width = width
        }
        func measured(_ item: DisplayRow, width: CGFloat, height: CGFloat) {
            guard let index = positions[item.id], rows[index] == item, heights[item.id]?[width] != height else { return }
            captureAnchor()
            if heights[item.id]?[width] == nil, heights[item.id]?.count ?? 0 >= 2 { heights[item.id] = [:] }
            heights[item.id, default: [:]][width] = height
            let scheduled = !pending.isEmpty; pending.insert(item.id)
            guard !scheduled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }
                self.captureAnchor()
                table.noteHeightOfRows(withIndexesChanged: IndexSet(self.pending.compactMap { self.positions[$0] }))
                for id in self.pending {
                    if let row = self.positions[id], let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) {
                        cell.frame.size.height = table.rect(ofRow: row).height
                    }
                }
                self.pending.removeAll(); self.restore()
            }
        }
        func resize() {
            guard !resizePending else { return }; resizePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }; self.resizePending = false
                self.captureAnchor()
                if let width = table.enclosingScrollView?.contentView.bounds.width { table.tableColumns[0].width = width; table.frame.size.width = width }
                let range = table.rows(in: table.visibleRect)
                for row in range.location..<(range.location + range.length) where self.rows.indices.contains(row) {
                    if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSHostingView<AnyView> { self.configure(cell, row: row) }
                }
            }
        }
        func update(_ value: TranscriptTable) {
            guard let table else { return }
            let old = rows, oldExpanded = parent.expanded, oldRevision = parent.revision, oldScope = parent.scope, oldStructure = parent.structure
            let follow = value.following || value.tailRequest != tailRequest || rows.isEmpty || parent.scope != value.scope
            parent = value; tailRequest = value.tailRequest
            if follow && !value.following { DispatchQueue.main.async { [weak self] in self?.parent.following = true } }
            guard oldRevision != value.revision || oldScope != value.scope || rows.isEmpty || oldExpanded != value.expanded else { restore(); return }
            if follow { readAnchor = nil } else { captureAnchor() }
            rows = value.rows
            if oldStructure != value.structure || old.count != rows.count || value.changed.contains(where: { id in positions[id].map { rows[$0].id != id } ?? true }) || oldScope != value.scope {
                let oldIDs = old.map(\.id), newIDs = rows.map(\.id)
                positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
                let prefix = zip(oldIDs, newIDs).prefix { $0 == $1 }.count
                let suffix = zip(oldIDs.dropFirst(prefix).reversed(), newIDs.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
                table.beginUpdates()
                if old.count - suffix > prefix { table.removeRows(at: IndexSet(integersIn: prefix..<(old.count - suffix)), withAnimation: []) }
                if rows.count - suffix > prefix { table.insertRows(at: IndexSet(integersIn: prefix..<(rows.count - suffix)), withAnimation: []) }
                table.endUpdates()
                heights = heights.filter { positions[$0.key] != nil }; expansions.formIntersection(newIDs)
            }
            let changed = oldExpanded != value.expanded ? IndexSet(rows.indices) : IndexSet(value.changed.compactMap { positions[$0] })
            for row in changed {
                let id = rows[row].id
                heights[id] = heights[id].map { $0.filter { $0.key == table.bounds.width } }
            }
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
            restore(follow: follow); value.applied(value.changed)
        }
        func captureAnchor() {
            guard !parent.following, readAnchor == nil, let table, let scroll = table.enclosingScrollView else { return }
            var row = max(0, table.row(at: scroll.contentView.bounds.origin))
            if rows.indices.contains(row), case .history = rows[row].content { row = min(row + 1, rows.count - 1) }
            if rows.indices.contains(row) { readAnchor = (rows[row].id, scroll.contentView.bounds.minY - table.rect(ofRow: row).minY) }
        }
        func restore(follow: Bool? = nil) {
            guard let table, let scroll = table.enclosingScrollView else { return }
            if follow ?? parent.following { readAnchor = nil }
            let y = readAnchor.flatMap { id, offset in positions[id].map { table.rect(ofRow: $0).minY + offset } }
            guard let y = y ?? ((follow ?? parent.following) ? max(0, table.bounds.height - scroll.contentView.bounds.height) : nil) else { return }
            let target = max(0, min(y, max(0, table.bounds.height - scroll.contentView.bounds.height)))
            if target != y, let (id, _) = readAnchor, let row = positions[id] { readAnchor = (id, target - table.rect(ofRow: row).minY) }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target)); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
