import AppKit
import FieldnotesCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class ThemePickerPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// One app-wide preview transaction; closing by any route rolls it back.
@MainActor final class ThemePickerController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = ThemePickerController()
    private let store: ThemeStore
    private var panel: ThemePickerPanel?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let removeButton = NSButton(title: "Remove Imported Theme", target: nil, action: nil)
    private let diagnostic = NSTextField(wrappingLabelWithString: "")
    private var ids: [String] = []
    private var refreshing = false
    init(store: ThemeStore = .shared) { self.store = store; super.init() }
    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        store.beginPreview()
        let panel = ThemePickerPanel(contentRect: NSRect(x: 0, y: 0, width: 590, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Color Theme"; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.minSize = NSSize(width: 460, height: 470)
        self.panel = panel
        search.placeholderString = "Search themes…"; search.delegate = self
        search.setAccessibilityLabel("Search color themes")
        if table.tableColumns.isEmpty { table.addTableColumn(NSTableColumn(identifier: .init("theme"))) }
        table.headerView = nil; table.rowHeight = 42; table.delegate = self; table.dataSource = self
        table.allowsEmptySelection = false; table.setAccessibilityLabel("Color themes")
        table.target = self; table.doubleAction = #selector(commit)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let hint = NSTextField(wrappingLabelWithString: "↑ ↓ to preview · Return to apply · Escape or Cancel to restore")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let help = NSTextField(wrappingLabelWithString: "Import a standalone VS Code JSON/JSONC color theme. Common colors are supported; some syntax styles may differ.")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        diagnostic.textColor = .systemRed; diagnostic.font = .systemFont(ofSize: 11)
        let importButton = NSButton(title: "Import JSON…", target: self, action: #selector(importTheme))
        removeButton.target = self; removeButton.action = #selector(removeTheme)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let apply = NSButton(title: "Apply Theme", target: self, action: #selector(commit))
        apply.bezelStyle = .rounded
        let importHelp = NSButton(title: "Import Help", target: self, action: #selector(showImportHelp))
        let actions = NSStackView(views: [importButton, removeButton, NSView(), cancel, apply]); actions.orientation = .horizontal
        let stack = NSStackView(views: [search, hint, scroll, diagnostic, help, importHelp, actions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            diagnostic.widthAnchor.constraint(equalTo: stack.widthAnchor), help.widthAnchor.constraint(equalTo: stack.widthAnchor), actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        panel.handleKey = { [weak self] event in
            guard let self, self.panel?.attachedSheet == nil, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) else { return false }
            // Let input methods finish composing before treating Return/Escape as actions.
            if let editor = self.search.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }
            switch event.keyCode {
            case 53: self.cancel(); return true
            case 36, 76: self.commit(); return true
            case 125, 126:
                guard !self.ids.isEmpty else { return true }
                let row = max(0, min(self.ids.count - 1, self.table.selectedRow + (event.keyCode == 125 ? 1 : -1)))
                self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); self.table.scrollRowToVisible(row); return true
            default: return false
            }
        }
        search.stringValue = ""; diagnostic.stringValue = ""; refresh(preferred: store.effectiveID)
        panel.center(); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search)
    }
    func controlTextDidChange(_ obj: Notification) { refresh(preferred: store.effectiveID) }
    private func refresh(preferred: String) {
        refreshing = true
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ids = (["system"] + store.catalog.map(\.id)).filter { id in
            let theme = store.catalog.first { $0.id == id }
            return query.isEmpty || "\(theme?.name ?? "System") \(theme?.kind.rawValue ?? "automatic") \(theme?.imported == true ? "imported" : "bundled")".lowercased().contains(query)
        }
        table.reloadData()
        if !ids.isEmpty { table.selectRowIndexes(IndexSet(integer: ids.firstIndex(of: preferred) ?? 0), byExtendingSelection: false) }
        refreshing = false
        selectionChanged()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard ids.indices.contains(row) else { return nil }
        let theme = store.catalog.first { $0.id == ids[row] }
        let name = theme?.name ?? "System"
        let detail = theme.map { "\($0.kind.rawValue.capitalized)\($0.imported ? " · Imported" : "")" } ?? "Follows macOS Light / Dark"
        let title = NSTextField(labelWithString: "\(name)   ·   \(detail)"); title.font = .systemFont(ofSize: 13)
        let swatches = NSStackView(); swatches.spacing = 4
        for key in ["paper", "text", "accent", "keyword", "string"] {
            let swatch = NSView(); swatch.wantsLayer = true; swatch.layer?.cornerRadius = 4
            swatch.layer?.backgroundColor = Self.color(theme?.tokens[key] ?? ThemeCatalog.bundled[0].tokens[key]!).cgColor
            swatch.layer?.borderWidth = 0.5; swatch.layer?.borderColor = NSColor.separatorColor.cgColor
            swatch.widthAnchor.constraint(equalToConstant: 17).isActive = true; swatch.heightAnchor.constraint(equalToConstant: 17).isActive = true
            swatches.addArrangedSubview(swatch)
        }
        let cell = NSTableCellView(); let line = NSStackView(views: [title, NSView(), swatches]); line.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(line); cell.setAccessibilityLabel("\(name), \(detail)")
        NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), line.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), line.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    private static func color(_ hex: String) -> NSColor {
        var value = String(hex.dropFirst())
        if value.count <= 4 { value = value.map { "\($0)\($0)" }.joined() }
        if value.count == 6 { value += "ff" }
        let n = UInt32(value, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((n >> 24) & 255)/255, green: CGFloat((n >> 16) & 255)/255, blue: CGFloat((n >> 8) & 255)/255, alpha: CGFloat(n & 255)/255)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !refreshing { selectionChanged() } }
    private func selectionChanged() {
        guard ids.indices.contains(table.selectedRow) else { removeButton.isEnabled = false; return }
        let id = ids[table.selectedRow]; store.preview(id: id)
        removeButton.isEnabled = store.catalog.first { $0.id == id }?.imported == true
    }
    @objc private func commit() { guard ids.indices.contains(table.selectedRow) else { return }; store.commitPreview(); finish() }
    @objc private func cancel() { store.cancelPreview(); finish() }
    private func finish() { panel?.handleKey = nil; panel?.orderOut(nil); panel?.delegate = nil; panel = nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    @objc private func removeTheme() {
        guard ids.indices.contains(table.selectedRow) else { return }
        store.remove(id: ids[table.selectedRow]); refresh(preferred: store.effectiveID)
    }
    @objc private func showImportHelp() {
        guard let panel else { return }
        let alert = NSAlert(); alert.messageText = "Importing Color Themes"
        alert.informativeText = ThemeImporter.help; alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: panel)
    }
    @objc private func importTheme() {
        guard let panel else { return }
        let chooser = NSOpenPanel(); chooser.title = "Import Color Theme"; chooser.allowsMultipleSelection = false; chooser.canChooseDirectories = false
        chooser.allowedContentTypes = [.json, UTType(filenameExtension: "jsonc") ?? .plainText]
        chooser.beginSheetModal(for: panel) { [weak self] result in
            guard let self, result == .OK, let url = chooser.url else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try BoundedFileReader.read(url, maximumBytes: ThemeImporter.maximumBytes)
                let theme = try self.store.importData(data)
                self.diagnostic.stringValue = ""; self.search.stringValue = ""; self.refresh(preferred: theme.id)
            } catch { self.diagnostic.stringValue = error.localizedDescription }
        }
    }
}

struct ThemeSettings: View {
    @Bindable var store: ThemeStore
    var body: some View {
        Form {
            Text("Color Theme").font(.headline)
            Text(store.catalog.first { $0.id == store.selectedID }?.name ?? "System")
            Button("Choose Color Theme…") { ThemePickerController.shared.show() }
            Text("Search and preview bundled palettes or import a VS Code JSON color theme. System follows your Mac’s appearance.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 420)
    }
}
