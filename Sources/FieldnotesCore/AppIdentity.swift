public enum AppIdentity {
    #if FIELDNOTES_INTEGRATION
    public static let bundleIdentifier = "com.thethoughtagen.fieldnotes.integration"
    public static let urlScheme = "fieldnotes-integration"
    #else
    public static let bundleIdentifier = "com.thethoughtagen.fieldnotes"
    public static let urlScheme = "fieldnotes"
    #endif
    public static let displayName = "FIELDNOTES"
}
