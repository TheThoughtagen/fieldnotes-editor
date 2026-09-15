import Foundation
import Testing
@testable import FieldnotesCore

@Test func applicationIdentityIsSharedAcrossEntryPoints() {
    #expect(AppIdentity.bundleIdentifier == "com.thethoughtagen.fieldnotes")
    #expect(AppIdentity.displayName == "FIELDNOTES")
    #expect(AppIdentity.urlScheme == "fieldnotes")
}

@Test func applicationPlistRegistersNativeMarkdownDocuments() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let plistURL = repositoryRoot.appendingPathComponent("Sources/FieldnotesApp/Info.plist")
    let data = try Data(contentsOf: plistURL)
    let plist = try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
    let markdown = try #require(documentTypes.first)

    #expect(markdown["NSDocumentClass"] as? String == "FieldnotesDocument")
    #expect(Set(markdown["CFBundleTypeExtensions"] as? [String] ?? []) == ["md", "markdown", "mdown", "mkd"])
    #expect(markdown["LSItemContentTypes"] as? [String] == ["net.daringfireball.markdown"])
    #expect(plist["CFBundleIdentifier"] as? String == AppIdentity.bundleIdentifier)
    let urlTypes = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
    #expect(urlTypes.first?["CFBundleURLSchemes"] as? [String] == [AppIdentity.urlScheme])
}
