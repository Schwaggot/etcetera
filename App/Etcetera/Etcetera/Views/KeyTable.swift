//
//  KeyTable.swift
//  Etcetera
//

import AppKit
import EtceteraCore
import SwiftUI

/// The key table on NSTableView, since SwiftUI's Table cannot size columns
/// to their content. The header's context menu fits columns; double-clicking
/// a column divider fits that column.
struct KeyTable: NSViewRepresentable {
    var rows: [KeyRow]
    @Binding var selection: Data?
    @Binding var sortOrder: [KeyPathComparator<KeyRow>]
    var separator: Character
    /// A mapping names keys, so the name column can show.
    var showsNames: Bool
    var onCopyValue: (Data) -> Void
    var onNameAction: (Data, KeyNameAction) -> Void
    var onExport: (ExportRequest) -> Void
    var onDelete: (Data) -> Void

    static let hiddenColumnsKey = "keyTable.hiddenColumns"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        // Only the key column follows the table's width; the numbers stay narrow.
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for column in KeyColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.minWidth = column == .key ? 120 : column == .name ? 60 : 44
            tableColumn.maxWidth = 10_000
            tableColumn.width = Coordinator.defaultWidth(of: column)
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if !Coordinator.isText(column) { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        table.autosaveName = "KeyTable"
        table.autosaveTableColumns = true
        table.dataSource = coordinator
        table.delegate = coordinator

        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        table.headerView?.menu = headerMenu
        let rowMenu = NSMenu()
        rowMenu.delegate = coordinator
        table.menu = rowMenu

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        // Columns fitted to long keys can be wider than the view.
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        coordinator.table = table
        coordinator.update()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
        // A disabled table also ignores keys, which the overlay cannot catch.
        context.coordinator.table?.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: KeyTable
        weak var table: NSTableView?
        private var rows: [KeyRow] = []
        /// Set while the table is brought in line with SwiftUI, whose own
        /// changes must not echo back into the bindings.
        private var syncing = false
        /// Whether the name column may show, as last applied.
        private var showsNames: Bool?

        /// Label insets plus the cell's own margin.
        private static let cellPadding: CGFloat = 10
        private static let keyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        init(_ parent: KeyTable) {
            self.parent = parent
        }

        static func defaultWidth(of column: KeyColumn) -> CGFloat {
            switch column {
            case .key: 260
            case .name: 180
            case .size: 70
            case .revision: 70
            case .lease: 60
            }
        }

        static func isText(_ column: KeyColumn) -> Bool {
            column == .key || column == .name
        }

        private static func font(for column: KeyColumn) -> NSFont {
            isText(column) ? keyFont : numberFont
        }

        /// The user's choice, stored on its own so the key column can never
        /// come back hidden; the name column also hides while nothing names keys.
        private func applyVisibility(resizing: Bool) {
            guard let table else { return }
            let hidden = Set(UserDefaults.standard.stringArray(forKey: KeyTable.hiddenColumnsKey) ?? [])
            for tableColumn in table.tableColumns {
                let id = tableColumn.identifier.rawValue
                tableColumn.isHidden =
                    id != KeyColumn.key.rawValue
                    && (hidden.contains(id) || (id == KeyColumn.name.rawValue && !parent.showsNames))
            }
            // The key column takes up or gives back the width.
            if resizing { table.sizeToFit() }
        }

        func update() {
            guard let table else { return }
            syncing = true
            defer { syncing = false }
            if showsNames != parent.showsNames {
                applyVisibility(resizing: showsNames != nil)
                showsNames = parent.showsNames
            }
            if rows != parent.rows {
                rows = parent.rows
                table.reloadData()
            }
            let descriptors = parent.sortOrder.first.flatMap(KeyColumn.sorting).map {
                [NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending)]
            } ?? []
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
            // By key, since a reload or a new sort moves the selected row.
            let wanted = parent.selection.flatMap { key in rows.firstIndex { $0.id == key } }
            if let wanted {
                if table.selectedRow != wanted { table.selectRowIndexes([wanted], byExtendingSelection: false) }
            } else if table.selectedRow >= 0 {
                table.deselectAll(nil)
            }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = KeyColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell =
                tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView
                ?? makeCell(for: column, identifier: tableColumn.identifier)
            let item = rows[row]
            cell.textField?.stringValue = column.text(for: item)
            let tooLarge = column == .size && item.size == nil
            cell.textField?.textColor = tooLarge ? .secondaryLabelColor : .labelColor
            cell.toolTip =
                column == .size
                ? item.size.map { String(localized: "\($0) bytes") }
                    ?? String(localized: "Too large to fetch through the etcd gateway") : nil
            return cell
        }

        private func makeCell(for column: KeyColumn, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.font = Self.font(for: column)
            // Keys often differ only at the end, so the middle gives way.
            field.lineBreakMode = column == .key ? .byTruncatingMiddle : .byTruncatingTail
            field.alignment = Self.isText(column) ? .natural : .right
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            parent.selection = table.selectedRow >= 0 ? rows[table.selectedRow].id : nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !syncing, let descriptor = tableView.sortDescriptors.first,
                let column = descriptor.key.flatMap(KeyColumn.init(rawValue:))
            else { return }
            parent.sortOrder = [column.comparator(ascending: descriptor.ascending)]
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tableColumn?.identifier.rawValue == KeyColumn.key.rawValue ? rows[row].displayKey : nil
        }

        // MARK: Column widths

        /// Double-clicking a column divider.
        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            fittingWidth(of: tableView.tableColumns[column])
        }

        private func fittingWidth(of tableColumn: NSTableColumn) -> CGFloat {
            guard let column = KeyColumn(rawValue: tableColumn.identifier.rawValue) else { return tableColumn.width }
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font(for: column)]
            var widest: CGFloat = 0
            for row in rows {
                widest = max(widest, (column.text(for: row) as NSString).size(withAttributes: attributes).width)
            }
            // Room for the title and its sort indicator.
            let header = tableColumn.headerCell.cellSize.width + 16
            let width = max(header, ceil(widest) + Self.cellPadding)
            return min(max(width, tableColumn.minWidth), tableColumn.maxWidth)
        }

        @objc private func sizeColumnToFit(_ sender: NSMenuItem) {
            guard let tableColumn = sender.representedObject as? NSTableColumn else { return }
            tableColumn.width = fittingWidth(of: tableColumn)
        }

        @objc private func sizeAllColumnsToFit(_ sender: NSMenuItem) {
            for tableColumn in table?.tableColumns ?? [] where !tableColumn.isHidden {
                tableColumn.width = fittingWidth(of: tableColumn)
            }
        }

        @objc private func resetColumnWidths(_ sender: NSMenuItem) {
            guard let table else { return }
            for tableColumn in table.tableColumns {
                guard let column = KeyColumn(rawValue: tableColumn.identifier.rawValue) else { continue }
                tableColumn.width = Self.defaultWidth(of: column)
            }
            // The key column takes whatever width is left.
            table.sizeToFit()
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if menu === table.headerView?.menu {
                buildHeaderMenu(menu, table: table)
            } else {
                let row = table.clickedRow
                guard row >= 0, row < rows.count else { return }
                let key = rows[row].id
                menu.addItem(copyItem(for: key))
                menu.addItem(.separator())
                // A key that is not UTF-8 cannot be typed as a new name.
                let isText = String(data: key, encoding: .utf8) != nil
                for (title, action) in [
                    (String(localized: "Rename Key..."), #selector(renameClickedKey(_:))),
                    (String(localized: "Duplicate Key..."), #selector(duplicateClickedKey(_:))),
                ] {
                    let item = NSMenuItem(title: title, action: isText ? action : nil, keyEquivalent: "")
                    item.target = self
                    item.representedObject = key
                    menu.addItem(item)
                }
                menu.addItem(exportItem(for: key))
                let delete = NSMenuItem(
                    title: String(localized: "Delete Key..."), action: #selector(deleteClickedKey(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = key
                menu.addItem(delete)
            }
        }

        /// Matches the tree's CopyKeyMenu.
        private func copyItem(for key: Data) -> NSMenuItem {
            let parts = KeyParts(key, separator: parent.separator)
            let submenu = NSMenu()
            for (title, text) in [
                (String(localized: "Prefix + Key"), parts.full),
                (String(localized: "Prefix", comment: "Copy menu item: the key's prefix"), parts.prefix),
                (String(localized: "Key", comment: "Copy menu item: the key's last segment"), parts.name),
            ] {
                // No action disables the item.
                let item = NSMenuItem(title: title, action: text.isEmpty ? nil : #selector(copyText(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = text
                submenu.addItem(item)
            }
            let value = NSMenuItem(
                title: String(localized: "Value", comment: "Copy menu item: the key's value"),
                action: #selector(copyValue(_:)), keyEquivalent: "")
            value.target = self
            value.representedObject = key
            submenu.addItem(value)
            let copy = NSMenuItem(
                title: String(localized: "Copy", comment: "Context menu submenu title"), action: nil, keyEquivalent: "")
            copy.submenu = submenu
            return copy
        }

        /// Matches the Key part of the tree's ExportKeyMenu.
        private func exportItem(for key: Data) -> NSMenuItem {
            let submenu = NSMenu()
            for format in ExportFormat.allCases {
                let item = NSMenuItem(
                    title: String(localized: "As \(format.title)..."), action: #selector(export(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ExportRequest(scope: .key(key), format: format)
                submenu.addItem(item)
            }
            let export = NSMenuItem(
                title: String(localized: "Export", comment: "Context menu submenu title"), action: nil, keyEquivalent: "")
            export.submenu = submenu
            return export
        }

        @objc private func export(_ sender: NSMenuItem) {
            guard let request = sender.representedObject as? ExportRequest else { return }
            parent.onExport(request)
        }

        @objc private func copyText(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            Clipboard.copy(text)
        }

        @objc private func copyValue(_ sender: NSMenuItem) {
            guard let key = sender.representedObject as? Data else { return }
            parent.onCopyValue(key)
        }

        /// Column visibility first, as in Finder, then sizing.
        private func buildHeaderMenu(_ menu: NSMenu, table: NSTableView) {
            for tableColumn in table.tableColumns
            where tableColumn.identifier.rawValue != KeyColumn.name.rawValue || parent.showsNames {
                // The key column stays; without an action its item is disabled.
                let isKey = tableColumn.identifier.rawValue == KeyColumn.key.rawValue
                let item = NSMenuItem(
                    title: tableColumn.title, action: isKey ? nil : #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tableColumn
                item.state = tableColumn.isHidden ? .off : .on
                menu.addItem(item)
            }
            menu.addItem(.separator())

            // The header menu has no clicked column of its own.
            var clicked: NSTableColumn?
            if let header = table.headerView, let window = header.window {
                let index = header.column(at: header.convert(window.mouseLocationOutsideOfEventStream, from: nil))
                if index >= 0 { clicked = table.tableColumns[index] }
            }
            let fitOne = NSMenuItem(
                title: clicked.map { String(localized: "Size \"\($0.title)\" to Fit") }
                    ?? String(localized: "Size Column to Fit"),
                action: clicked == nil ? nil : #selector(sizeColumnToFit(_:)), keyEquivalent: "")
            fitOne.target = self
            fitOne.representedObject = clicked
            menu.addItem(fitOne)
            for (title, action) in [
                (String(localized: "Size All Columns to Fit"), #selector(sizeAllColumnsToFit(_:))),
                (String(localized: "Reset Column Widths"), #selector(resetColumnWidths(_:))),
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let tableColumn = sender.representedObject as? NSTableColumn else { return }
            let id = tableColumn.identifier.rawValue
            var hidden = Set(UserDefaults.standard.stringArray(forKey: KeyTable.hiddenColumnsKey) ?? [])
            if tableColumn.isHidden { hidden.remove(id) } else { hidden.insert(id) }
            UserDefaults.standard.set(hidden.sorted(), forKey: KeyTable.hiddenColumnsKey)
            applyVisibility(resizing: true)
        }

        @objc private func renameClickedKey(_ sender: NSMenuItem) {
            guard let key = sender.representedObject as? Data else { return }
            parent.onNameAction(key, .rename)
        }

        @objc private func duplicateClickedKey(_ sender: NSMenuItem) {
            guard let key = sender.representedObject as? Data else { return }
            parent.onNameAction(key, .duplicate)
        }

        @objc private func deleteClickedKey(_ sender: NSMenuItem) {
            guard let key = sender.representedObject as? Data else { return }
            parent.onDelete(key)
        }
    }
}
