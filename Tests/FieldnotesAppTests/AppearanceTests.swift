import AppKit
import Testing
import WebKit
@testable import FieldnotesApp

@Suite("Application appearance", .serialized)
@MainActor
struct AppearanceTests {
    @Test("isolated preferences persist, reject invalid values and restore system inheritance")
    func persistence() throws {
        let name = "FieldnotesAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original; defaults.removePersistentDomain(forName: name) }
        defaults.set("untrusted", forKey: AppearancePreference.defaultsKey)
        let preference = AppearancePreference(defaults: defaults)
        #expect(preference.selection == .system)
        preference.selection = .dark
        #expect(AppearancePreference(defaults: defaults).selection == .dark)
        #expect(application.appearance?.name == .darkAqua)
        preference.selection = .light
        #expect(AppearancePreference(defaults: defaults).selection == .light)
        #expect(application.appearance?.name == .aqua)
        preference.selection = .system
        #expect(application.appearance == nil)
    }

    @Test("existing and future native windows and live WK media queries inherit the app override")
    func liveWebKit() async throws {
        let name = "FieldnotesAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let application = NSApplication.shared
        let original = application.appearance
        let preference = AppearancePreference(defaults: defaults)
        var windows: [NSWindow] = []
        defer {
            for window in windows { window.orderOut(nil); window.contentView = nil }
            application.appearance = original
            defaults.removePersistentDomain(forName: name)
        }
        for _ in 0..<2 {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let web = WKWebView(frame: window.contentView!.bounds)
            window.contentView = web
            windows.append(window)
            web.loadHTMLString("<meta name='color-scheme' content='light dark'><style>body{color-scheme:light dark}</style><textarea>Unchanged draft</textarea><script>window.identity = 'same-page'</script>", baseURL: nil)
            window.orderFront(nil)
        }
        for mode in [EditorAppearance.light, .dark, .light] {
            preference.selection = mode
            let dark = mode == .dark
            for window in windows {
                let web = try #require(window.contentView as? WKWebView)
                var matched = false
                for _ in 0..<100 {
                    let result = try? await web.evaluateJavaScript("window.identity === 'same-page' && document.querySelector('textarea').value === 'Unchanged draft' && matchMedia('(prefers-color-scheme: dark)').matches === \(dark)")
                    if result as? Bool == true { matched = true; break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                #expect(matched)
                #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (dark ? .darkAqua : .aqua))
            }
        }
        preference.selection = .dark
        let future = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        future.isReleasedWhenClosed = false
        windows.append(future)
        #expect(future.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        preference.selection = .system
        #expect(application.appearance == nil)
        #expect(windows.allSatisfy { $0.appearance == nil })
    }
}
