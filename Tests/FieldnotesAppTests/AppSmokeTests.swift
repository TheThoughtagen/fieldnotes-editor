import Testing
@testable import FieldnotesCore

@Test func applicationIdentityIsSharedAcrossEntryPoints() {
    #expect(AppIdentity.bundleIdentifier == "com.thethoughtagen.fieldnotes")
    #expect(AppIdentity.displayName == "FIELDNOTES")
    #expect(AppIdentity.urlScheme == "fieldnotes")
}
