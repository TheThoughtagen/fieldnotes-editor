import Foundation

enum BridgeProtocolError: Error, Equatable {
    case invalidBody
    case unexpectedField(String)
    case missingField(String)
    case invalidValue(String)
    case subframe
}

enum EditorBridgeKind: String, Codable, Sendable {
    case ready
    case transaction
    case selection
    case requestSnapshot
    case status
    case action
    case workspaceSearch
    case workspaceOpen
    case contextApplied
    case schemaStatus
}

struct EditorBridgeSelection: Codable, Equatable, Sendable {
    let anchor: Int
    let head: Int
}

struct EditorBridgePayload: Codable, Equatable, Sendable {
    let text: String?
    let selection: EditorBridgeSelection?
    let editKind: String?
    let action: String?
    let presentationMode: String?
    let vimMode: String?
    let line: Int?
    let column: Int?
    let wordCount: Int?
    let query: String?
    let generation: Int?
    let resultID: String?
    let includeContent: Bool?
    let schemaState: String?

    init(
        text: String? = nil,
        selection: EditorBridgeSelection? = nil,
        editKind: String? = nil,
        action: String? = nil,
        presentationMode: String? = nil,
        vimMode: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        wordCount: Int? = nil,
        query: String? = nil,
        generation: Int? = nil,
        resultID: String? = nil,
        includeContent: Bool? = nil,
        schemaState: String? = nil
    ) {
        self.text = text
        self.selection = selection
        self.editKind = editKind
        self.action = action
        self.presentationMode = presentationMode
        self.vimMode = vimMode
        self.line = line
        self.column = column
        self.wordCount = wordCount
        self.query = query
        self.generation = generation
        self.resultID = resultID
        self.includeContent = includeContent
        self.schemaState = schemaState
    }
}

struct EditorBridgeRequest: Codable, Equatable, Sendable {
    let kind: EditorBridgeKind
    let documentID: String
    let baseRevision: Int
    let revision: Int
    let payload: EditorBridgePayload

    private init(
        kind: EditorBridgeKind,
        documentID: String,
        baseRevision: Int,
        revision: Int,
        payload: EditorBridgePayload
    ) {
        self.kind = kind
        self.documentID = documentID
        self.baseRevision = baseRevision
        self.revision = revision
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        try Self.requireExactKeys(container.allKeys.map(\.stringValue), allowed: ["kind", "documentID", "baseRevision", "revision", "payload"])
        let kind = try container.decode(EditorBridgeKind.self, forKey: .init("kind"))
        let documentID = try container.decode(String.self, forKey: .init("documentID"))
        let baseRevision = try container.decode(Int.self, forKey: .init("baseRevision"))
        let revision = try container.decode(Int.self, forKey: .init("revision"))
        guard baseRevision >= 0, revision >= 0 else { throw BridgeProtocolError.invalidValue("revision") }
        let payloadContainer = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .init("payload"))
        let payload: EditorBridgePayload
        switch kind {
        case .ready, .requestSnapshot:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: [])
            guard revision == baseRevision else { throw BridgeProtocolError.invalidValue("revision") }
            payload = .empty
        case .selection:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: ["selection"])
            guard revision == baseRevision else { throw BridgeProtocolError.invalidValue("revision") }
            payload = .init(text: nil, selection: try Self.decodeSelection(payloadContainer), editKind: nil, action: nil, presentationMode: nil, vimMode: nil, line: nil, column: nil, wordCount: nil)
        case .transaction:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: ["text", "selection", "editKind"])
            let text = try payloadContainer.decode(String.self, forKey: .init("text"))
            let editKind = try payloadContainer.decode(String.self, forKey: .init("editKind"))
            guard ["done", "undone", "redone"].contains(editKind) else { throw BridgeProtocolError.invalidValue("editKind") }
            payload = .init(text: text, selection: try Self.decodeSelection(payloadContainer), editKind: editKind, action: nil, presentationMode: nil, vimMode: nil, line: nil, column: nil, wordCount: nil)
        case .action:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: ["action"])
            guard revision == baseRevision else { throw BridgeProtocolError.invalidValue("revision") }
            let action = try payloadContainer.decode(String.self, forKey: .init("action"))
            guard ["save", "quit"].contains(action) else { throw BridgeProtocolError.invalidValue("action") }
            payload = .init(text: nil, selection: nil, editKind: nil, action: action, presentationMode: nil, vimMode: nil, line: nil, column: nil, wordCount: nil)
        case .status:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: ["presentationMode", "vimMode", "line", "column", "wordCount"])
            guard revision == baseRevision else { throw BridgeProtocolError.invalidValue("revision") }
            let mode = try payloadContainer.decode(String.self, forKey: .init("presentationMode"))
            let vimMode = try payloadContainer.decode(String.self, forKey: .init("vimMode"))
            let line = try payloadContainer.decode(Int.self, forKey: .init("line"))
            let column = try payloadContainer.decode(Int.self, forKey: .init("column"))
            let words = try payloadContainer.decode(Int.self, forKey: .init("wordCount"))
            guard ["focus", "source", "preview"].contains(mode),
                  ["normal", "insert", "replace", "visual", "off"].contains(vimMode),
                  line > 0, column > 0, words >= 0
            else { throw BridgeProtocolError.invalidValue("status") }
            payload = .init(text: nil, selection: nil, editKind: nil, action: nil, presentationMode: mode, vimMode: vimMode, line: line, column: column, wordCount: words)
        case .schemaStatus:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: ["generation", "schemaState"])
            let generation = try payloadContainer.decode(Int.self, forKey: .init("generation"))
            let schemaState = try payloadContainer.decode(String.self, forKey: .init("schemaState"))
            guard revision == baseRevision, generation > 0, ["none", "valid", "invalid"].contains(schemaState) else { throw BridgeProtocolError.invalidValue("schemaStatus") }
            payload = .init(generation: generation, schemaState: schemaState)
        case .contextApplied:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: ["generation"])
            let generation = try payloadContainer.decode(Int.self, forKey: .init("generation"))
            guard revision == baseRevision, generation > 0 else { throw BridgeProtocolError.invalidValue("contextApplied") }
            payload = .init(generation: generation)
        case .workspaceSearch:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: payloadContainer.contains(.init("includeContent")) ? ["query", "generation", "includeContent"] : ["query", "generation"])
            guard revision == baseRevision else { throw BridgeProtocolError.invalidValue("revision") }
            let query = try payloadContainer.decode(String.self, forKey: .init("query"))
            let generation = try payloadContainer.decode(Int.self, forKey: .init("generation"))
            guard query.utf8.count <= 256, generation > 0 else { throw BridgeProtocolError.invalidValue("workspaceSearch") }
            payload = .init(query: query, generation: generation, includeContent: try payloadContainer.decodeIfPresent(Bool.self, forKey: .init("includeContent")))
        case .workspaceOpen:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: ["resultID", "generation"])
            guard revision == baseRevision else { throw BridgeProtocolError.invalidValue("revision") }
            let resultID = try payloadContainer.decode(String.self, forKey: .init("resultID"))
            let generation = try payloadContainer.decode(Int.self, forKey: .init("generation"))
            guard resultID.utf8.count <= 128, UUID(uuidString: resultID) != nil, generation > 0 else {
                throw BridgeProtocolError.invalidValue("workspaceOpen")
            }
            payload = .init(generation: generation, resultID: resultID)
        }
        self.init(kind: kind, documentID: documentID, baseRevision: baseRevision, revision: revision, payload: payload)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(kind, forKey: .init("kind"))
        try container.encode(documentID, forKey: .init("documentID"))
        try container.encode(baseRevision, forKey: .init("baseRevision"))
        try container.encode(revision, forKey: .init("revision"))
        var payloadContainer = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .init("payload"))
        switch kind {
        case .ready, .requestSnapshot:
            break
        case .selection:
            try payloadContainer.encode(payload.selection, forKey: .init("selection"))
        case .transaction:
            try payloadContainer.encode(payload.text, forKey: .init("text"))
            try payloadContainer.encode(payload.selection, forKey: .init("selection"))
            try payloadContainer.encode(payload.editKind, forKey: .init("editKind"))
        case .action:
            try payloadContainer.encode(payload.action, forKey: .init("action"))
        case .status:
            try payloadContainer.encode(payload.presentationMode, forKey: .init("presentationMode"))
            try payloadContainer.encode(payload.vimMode, forKey: .init("vimMode"))
            try payloadContainer.encode(payload.line, forKey: .init("line"))
            try payloadContainer.encode(payload.column, forKey: .init("column"))
            try payloadContainer.encode(payload.wordCount, forKey: .init("wordCount"))
        case .schemaStatus:
            try payloadContainer.encode(payload.generation, forKey: .init("generation"))
            try payloadContainer.encode(payload.schemaState, forKey: .init("schemaState"))
        case .contextApplied:
            try payloadContainer.encode(payload.generation, forKey: .init("generation"))
        case .workspaceSearch:
            try payloadContainer.encodeIfPresent(payload.includeContent, forKey: .init("includeContent"))
            try payloadContainer.encode(payload.query, forKey: .init("query"))
            try payloadContainer.encode(payload.generation, forKey: .init("generation"))
        case .workspaceOpen:
            try payloadContainer.encode(payload.resultID, forKey: .init("resultID"))
            try payloadContainer.encode(payload.generation, forKey: .init("generation"))
        }
    }

    static func validate(body: Any, isMainFrame: Bool) throws -> Self {
        guard isMainFrame else { throw BridgeProtocolError.subframe }
        return try decode(body: body)
    }

    static func decode(body: Any) throws -> Self {
        guard JSONSerialization.isValidJSONObject(body) else { throw BridgeProtocolError.invalidBody }
        do {
            return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: body))
        } catch let error as BridgeProtocolError {
            throw error
        } catch {
            throw BridgeProtocolError.invalidBody
        }
    }

    private static func decodeSelection(_ payload: KeyedDecodingContainer<DynamicCodingKey>) throws -> EditorBridgeSelection {
        let selection = try payload.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .init("selection"))
        try requireExactKeys(selection.allKeys.map(\.stringValue), allowed: ["anchor", "head"])
        let anchor = try selection.decode(Int.self, forKey: .init("anchor"))
        let head = try selection.decode(Int.self, forKey: .init("head"))
        guard anchor >= 0, head >= 0 else {
            throw BridgeProtocolError.invalidValue("selection")
        }
        return .init(anchor: anchor, head: head)
    }

    private static func requireExactKeys(_ keys: [String], allowed: Set<String>) throws {
        if let unexpected = Set(keys).subtracting(allowed).sorted().first {
            throw BridgeProtocolError.unexpectedField(unexpected)
        }
        if let missing = allowed.subtracting(keys).sorted().first {
            throw BridgeProtocolError.missingField(missing)
        }
    }
}

private extension EditorBridgePayload {
    static let empty = Self()
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
