import AppKit
import Observation
import SwiftUI

enum EditorAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// AppKit propagates application appearance to windows, sheets and WKWebView.
/// Returning to nil restores live system inheritance without touching editor state.
@MainActor @Observable
final class AppearancePreference {
    static let shared = AppearancePreference()
    static let defaultsKey = "editorAppearance"
    private let defaults: UserDefaults
    var selection: EditorAppearance {
        didSet {
            defaults.set(selection.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.defaultsKey).flatMap(EditorAppearance.init(rawValue:)) ?? .system
    }

    func apply() { NSApplication.shared.appearance = selection.nativeAppearance }
}

struct AppearanceSettings: View {
    @Bindable var preference: AppearancePreference
    var body: some View {
        Form {
            Picker("Appearance", selection: $preference.selection) {
                ForEach(EditorAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            Text("System follows your Mac’s Light or Dark appearance.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360)
    }
}
