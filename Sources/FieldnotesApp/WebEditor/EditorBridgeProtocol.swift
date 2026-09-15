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
}

struct EditorBridgeSelection: Codable, Equatable, Sendable {
    let anchor: Int
    let head: Int
}

struct EditorBridgePayload: Codable, Equatable, Sendable {
    let text: String?
    let selection: EditorBridgeSelection?
    let editKind: String?
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
            payload = .init(text: nil, selection: nil, editKind: nil)
        case .selection:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: ["selection"])
            guard revision == baseRevision else { throw BridgeProtocolError.invalidValue("revision") }
            payload = .init(text: nil, selection: try Self.decodeSelection(payloadContainer), editKind: nil)
        case .transaction:
            try Self.requireExactKeys(payloadContainer.allKeys.map(\.stringValue), allowed: ["text", "selection", "editKind"])
            let text = try payloadContainer.decode(String.self, forKey: .init("text"))
            let editKind = try payloadContainer.decode(String.self, forKey: .init("editKind"))
            guard ["done", "undone", "redone"].contains(editKind) else { throw BridgeProtocolError.invalidValue("editKind") }
            payload = .init(text: text, selection: try Self.decodeSelection(payloadContainer), editKind: editKind)
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

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
