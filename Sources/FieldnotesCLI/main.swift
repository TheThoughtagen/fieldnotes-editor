import AppKit
import Foundation
import FieldnotesCore

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else {
    FileHandle.standardError.write(Data("usage: fieldnotes <markdown-file>\n".utf8))
    exit(64)
}

let fileURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
var components = URLComponents()
components.scheme = AppIdentity.urlScheme
components.host = "open"
components.queryItems = [URLQueryItem(name: "path", value: fileURL.path)]

guard let openURL = components.url, NSWorkspace.shared.open(openURL) else {
    FileHandle.standardError.write(Data("fieldnotes: could not open \(fileURL.path)\n".utf8))
    exit(1)
}
