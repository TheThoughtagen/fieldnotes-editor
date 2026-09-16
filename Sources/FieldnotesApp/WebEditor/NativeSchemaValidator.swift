import Foundation
import JavaScriptCore

/// Runs the same bundled Ajv validator off the UI actor, outside the web content world.
/// This context has no native callbacks, network, filesystem, or user-provided code entry point.
enum NativeSchemaValidator {
    static func validate(source: String, schema: Data, scriptURL: URL) -> Data {
        func failure(_ message: String) -> Data {
            (try? JSONSerialization.data(withJSONObject: [["code": "schema.validation", "message": String(message.prefix(4096)), "severity": "error"]])) ?? Data("[]".utf8)
        }
        guard source.utf8.count <= 8_388_608, schema.count <= 1_048_576,
              let schemaJSON = String(data: schema, encoding: .utf8),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let context = JSContext() else { return failure("Schema validation unavailable or input too large") }
        context.evaluateScript(script)
        guard context.exception == nil,
              let function = context.objectForKeyedSubscript("FieldnotesValidation")?.objectForKeyedSubscript("validate"),
              let result = function.call(withArguments: [source, schemaJSON]), context.exception == nil,
              let json = result.toString(), json.utf8.count <= 1_048_576,
              let data = json.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [[String: Any]]
        else { return failure("Schema validation failed: \(context.exception?.toString() ?? "invalid result")") }
        return data
    }
}
