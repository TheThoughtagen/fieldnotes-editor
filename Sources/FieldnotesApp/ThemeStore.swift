import AppKit
import Foundation
import Observation
import FieldnotesCore

struct EditorTheme: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case light, dark }
    let id: String
    let name: String
    let kind: Kind
    var tokens: [String: String]
    var imported: Bool = false
}

enum ThemeCatalog {
    static let keys: Set<String> = ["paper", "surface", "text", "muted", "border", "accent", "purple", "green", "red", "teal", "amber", "selection", "active", "warning", "warning-text", "caret", "gutter", "gutter-text", "heading", "link", "code", "comment", "keyword", "string", "number", "type", "function", "variable", "operator", "invalid"]
    static func palette(_ id: String, _ name: String, _ kind: EditorTheme.Kind, _ colors: String) -> EditorTheme {
        let keys = ["paper", "surface", "text", "muted", "border", "accent", "purple", "green", "red", "teal", "amber", "selection", "active", "warning", "warning-text"]
        var tokens = Dictionary(uniqueKeysWithValues: zip(keys, colors.split(separator: " ").map(String.init)))
        for (key, base) in ["caret":"accent", "gutter":"paper", "gutter-text":"muted", "heading":"text", "link":"accent", "code":"surface", "comment":"muted", "keyword":"purple", "string":"red", "number":"green", "type":"amber", "function":"accent", "variable":"text", "operator":"purple", "invalid":"red"] { tokens[key] = tokens[base] }
        return EditorTheme(id: id, name: name, kind: kind, tokens: tokens)
    }
    static let bundled: [EditorTheme] = [
        palette("linen", "Linen", .light, "#fcfbf8 #f1f0ec #282c30 #657079 #d9dcda #2466a0 #7950a0 #35734b #aa4249 #246f78 #826019 #cfe3f6 #eaf0f3 #fff1d5 #745116"),
        palette("midnight", "Midnight", .dark, "#202326 #292e32 #e3e5e6 #a5aeb5 #454d53 #8ac4f5 #c6a2e7 #9bd2a9 #f1a0a3 #8bcbd1 #e4c484 #3e5870 #2a333b #3c3221 #ecd098"),
        palette("sandstone", "Sandstone", .light, "#f8f0df #eee2cb #3d352b #716454 #cbbda5 #88512a #80588a #4f6c37 #a04336 #346f6d #826016 #e1caa2 #eee4d0 #f7dfab #71501c"),
        palette("glacier", "Glacier", .light, "#f2f7fc #e6eef7 #23364b #5c7189 #c2d1e2 #205fad #7148a5 #2c704e #aa384f #176b80 #805d19 #c9dff8 #e4edf7 #fff0cd #715014"),
        palette("forest", "Forest After Dark", .dark, "#182822 #23372e #e2eee4 #a1b8a9 #3e594a #98d8b2 #cdb3ee #b4d98d #efa9a0 #8ed7cf #e2c48b #365e48 #263d31 #3d3523 #ead49d"),
        palette("ink", "Ink & Iris", .dark, "#242136 #302b45 #eee9f7 #b7aecb #504763 #c1b4ff #dab1ed #a9d9b5 #f3a9bf #9ed9df #eed099 #50436d #332c49 #433728 #f0d5a2")
    ]
}

enum ThemeImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum ThemeImporter {
    static let maximumBytes = 1_048_576
    static let help = "Import a standalone VS Code JSON/JSONC color theme (up to 1 MiB). UI colors and common comment, keyword/storage, string, number, type, function, variable, operator, invalid and Markdown heading/link scopes are mapped. Unmapped scopes, font styles and semantic-token rules are ignored. Includes, external .tmTheme files and extensions are unsupported; export a standalone JSON file first. Only hexadecimal colors are accepted. No code, CSS, network or related files are loaded."
    static let colorMap = ["editor.background":"paper", "editor.foreground":"text", "editorGroupHeader.tabsBackground":"surface", "editorWidget.background":"surface", "descriptionForeground":"muted", "editorWidget.border":"border", "focusBorder":"accent", "editor.selectionBackground":"selection", "editor.lineHighlightBackground":"active", "editorCursor.foreground":"caret", "editorGutter.background":"gutter", "editorLineNumber.foreground":"gutter-text", "textLink.foreground":"link", "textCodeBlock.background":"code", "editorError.foreground":"warning-text", "inputValidation.errorBackground":"warning"]
    static func validColor(_ value: String) -> Bool {
        guard [4, 5, 7, 9].contains(value.utf8.count), value.first == "#" else { return false }
        return value.dropFirst().utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    static func parse(_ data: Data) throws -> EditorTheme {
        func fail(_ message: String) -> ThemeImportError { .invalid(message) }
        guard data.count <= maximumBytes, let source = String(data: data, encoding: .utf8) else { throw fail("Theme must be UTF-8 and at most 1 MiB.") }
        let json = try stripJSONC(source)
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw fail("Expected a theme object.") }
        guard object["include"] == nil else { throw fail("Theme includes are unsupported. Export a standalone JSON theme.") }
        guard let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw fail("Theme needs a name of 1–120 characters without control characters.") }
        let rawType = object["type"] as? String ?? "dark"
        guard object["type"] == nil || object["type"] is String, ["light", "dark", "hc", "hcLight"].contains(rawType) else { throw fail("Theme type must be light, dark, hc or hcLight.") }
        let kind: EditorTheme.Kind = ["light", "hcLight"].contains(rawType) ? .light : .dark
        var theme = EditorTheme(id: "imported-\(UUID().uuidString.lowercased())", name: name, kind: kind, tokens: ThemeCatalog.bundled[kind == .light ? 0 : 1].tokens, imported: true)
        if let raw = object["colors"] {
            guard let colors = raw as? [String: String], colors.count <= 2048 else { throw fail("colors must be an object with at most 2,048 hexadecimal color strings.") }
            for (key, value) in colors {
                guard key.count <= 256, validColor(value) else { throw fail("Invalid color for \(key.prefix(80)); use #RGB, #RGBA, #RRGGBB or #RRGGBBAA.") }
                if let token = colorMap[key] { theme.tokens[token] = value }
            }
            // Defaults follow an imported editor background/foreground when no explicit token exists.
            if colors["editorGutter.background"] == nil { theme.tokens["gutter"] = theme.tokens["paper"] }
            theme.tokens["heading"] = theme.tokens["text"]
            theme.tokens["variable"] = theme.tokens["text"]
        }
        if let raw = object["tokenColors"] {
            guard let rules = raw as? [[String: Any]], rules.count <= 4096 else { throw fail("tokenColors must be an inline array of at most 4,096 rules; external .tmTheme files are unsupported.") }
            for rule in rules {
                guard let settings = rule["settings"] as? [String: Any] else { throw fail("Each token rule needs a settings object.") }
                for key in ["foreground", "background"] where settings[key] != nil {
                    guard let color = settings[key] as? String, validColor(color) else { throw fail("Token colors must be hexadecimal colors.") }
                }
                let scopes: [String]
                if let scope = rule["scope"] as? String { scopes = scope.components(separatedBy: ",") }
                else if let list = rule["scope"] as? [String] { scopes = list }
                else if rule["scope"] == nil { scopes = [] }
                else { throw fail("Token scope must be a string or string array.") }
                guard scopes.count <= 256, scopes.allSatisfy({ $0.count <= 512 }) else { throw fail("Token scope is too large.") }
                guard let foreground = settings["foreground"] as? String else { continue }
                for scope in scopes {
                    guard let token = mappedScope(scope.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                    theme.tokens[token] = foreground
                    if token == "keyword" { theme.tokens["purple"] = foreground }
                }
            }
        }
        return theme
    }
    static func mappedScope(_ scope: String) -> String? {
        // Deliberately a small category mapping, not a TextMate selector interpreter.
        let mappings = [("comment", "comment"), ("keyword.operator", "operator"), ("keyword", "keyword"), ("storage", "keyword"), ("string", "string"), ("constant.numeric", "number"), ("entity.name.type", "type"), ("support.type", "type"), ("entity.name.function", "function"), ("support.function", "function"), ("variable", "variable"), ("invalid", "invalid"), ("markup.heading", "heading"), ("markup.underline.link", "link")]
        return mappings.first { scope == $0.0 || scope.hasPrefix($0.0 + ".") }?.1
    }
    /// Two finite-state passes preserve quoted strings. No eval, regex comment stripping or file resolution.
    static func stripJSONC(_ source: String) throws -> String {
        let chars = Array(source); var output: [Character] = [], i = 0, quoted = false, escaped = false
        while i < chars.count {
            let c = chars[i]
            if quoted {
                output.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
                i += 1; continue
            }
            if c == "\"" { quoted = true; output.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                output.append(" "); i += 2
                while i < chars.count && chars[i] != "\n" && chars[i] != "\r" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                output.append(" "); i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                guard i + 1 < chars.count else { throw ThemeImportError.invalid("Unterminated JSONC comment.") }
                i += 2; continue
            }
            output.append(c); i += 1
        }
        var cleaned: [Character] = []; quoted = false; escaped = false
        for index in output.indices {
            let c = output[index]
            if quoted {
                cleaned.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
            } else {
                if c == "\"" { quoted = true }
                if c == "," {
                    var next = index + 1
                    while next < output.count && output[next].isWhitespace { next += 1 }
                    if next < output.count && (output[next] == "}" || output[next] == "]") { continue }
                }
                cleaned.append(c)
            }
        }
        return String(cleaned)
    }
}

@MainActor @Observable final class ThemeStore {
    static let shared = ThemeStore()
    static let changed = Notification.Name("FieldnotesThemeChanged")
    static let selectedKey = "editorThemeID"
    static let importedKey = "editorImportedThemes"
    private let defaults: UserDefaults
    private(set) var selectedID: String = "system"
    private(set) var previewID: String?
    private(set) var importedThemes: [EditorTheme]
    var catalog: [EditorTheme] { ThemeCatalog.bundled + importedThemes }
    var effectiveID: String { previewID ?? selectedID }
    var effectiveTheme: EditorTheme? { catalog.first { $0.id == effectiveID } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.importedKey), data.count <= 4 * ThemeImporter.maximumBytes,
           let themes = try? JSONDecoder().decode([EditorTheme].self, from: data), themes.count <= 64 {
            var seen = Set<String>()
            importedThemes = themes.filter { theme in
                theme.imported && theme.id.hasPrefix("imported-") && theme.id.count <= 80 && seen.insert(theme.id).inserted && !theme.name.isEmpty && theme.name.count <= 120 && theme.tokens.count == ThemeCatalog.keys.count && Set(theme.tokens.keys) == ThemeCatalog.keys && theme.tokens.values.allSatisfy(ThemeImporter.validColor)
            }
        } else { importedThemes = [] }
        let legacy = defaults.string(forKey: AppearancePreference.defaultsKey)
        let candidate = defaults.string(forKey: Self.selectedKey) ?? (legacy == "dark" ? "midnight" : legacy == "light" ? "linen" : "system")
        selectedID = (["system"] + ThemeCatalog.bundled.map(\.id) + importedThemes.map(\.id)).contains(candidate) ? candidate : "system"
    }
    func apply() {
        NSApplication.shared.appearance = effectiveTheme.map { NSAppearance(named: $0.kind == .dark ? .darkAqua : .aqua)! }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    func select(id: String) {
        guard id == "system" || catalog.contains(where: { $0.id == id }) else { return }
        selectedID = id; previewID = nil
        defaults.set(id, forKey: Self.selectedKey); apply()
    }
    func beginPreview() { previewID = selectedID }
    func preview(id: String) {
        guard id == "system" || catalog.contains(where: { $0.id == id }) else { return }
        previewID = id; apply()
    }
    func cancelPreview() { previewID = nil; apply() }
    func commitPreview() { select(id: effectiveID) }
    @discardableResult func importData(_ data: Data) throws -> EditorTheme {
        guard importedThemes.count < 64 else { throw ThemeImportError.invalid("Remove an imported theme before adding another (64 maximum).") }
        let theme = try ThemeImporter.parse(data)
        importedThemes.append(theme); persistImports()
        return theme
    }
    func remove(id: String) {
        guard importedThemes.contains(where: { $0.id == id }) else { return }
        importedThemes.removeAll { $0.id == id }; persistImports()
        if selectedID == id { selectedID = "system"; defaults.set(selectedID, forKey: Self.selectedKey) }
        if previewID == id { previewID = selectedID }
        apply()
    }
    private func persistImports() { if let data = try? JSONEncoder().encode(importedThemes) { defaults.set(data, forKey: Self.importedKey) } }
}
