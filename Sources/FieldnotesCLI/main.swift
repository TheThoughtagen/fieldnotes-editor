import AppKit
import Foundation
import FieldnotesCore

func write(_ value: String, to handle: FileHandle) {
    handle.write(Data(value.utf8))
}

@MainActor
final class LaunchAcceptance { var accepted: Bool? }

@MainActor
func launch(_ url: URL) -> Bool {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    guard let app = CLIApplicationLocation.bundledApp(for: executable),
          Bundle(url: app)?.bundleIdentifier == AppIdentity.bundleIdentifier else {
        return NSWorkspace.shared.open(url)
    }
    let acceptance = LaunchAcceptance()
    let configuration = NSWorkspace.OpenConfiguration()
    #if FIELDNOTES_INTEGRATION
    configuration.createsNewApplicationInstance = !NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath() == app.resolvingSymlinksInPath() }
    #endif
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
        let accepted = error == nil
        Task { @MainActor in acceptance.accepted = accepted }
    }
    let deadline = Date().addingTimeInterval(30)
    while acceptance.accepted == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return acceptance.accepted == true
}

let parsed: CLIArguments
do {
    parsed = try CLIArguments.parse(
        Array(CommandLine.arguments.dropFirst()),
        currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    )
} catch let error as CLIError {
    write("fieldnotes: \(error)\n\(CLIArguments.helpText)\n", to: .standardError)
    exit(error.exitCode)
} catch {
    write("fieldnotes: \(error)\n", to: .standardError)
    exit(64)
}

if parsed == .help {
    write("\(CLIArguments.helpText)\n", to: .standardOutput)
    exit(0)
}

let request = parsed.request
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: request.target.path, isDirectory: &isDirectory) else {
    write("fieldnotes: no such file or folder: \(request.target.path)\n", to: .standardError)
    exit(66)
}
if request.line != nil, isDirectory.boolValue {
    write("fieldnotes: --line requires a file target\n", to: .standardError)
    exit(64)
}

do {
    let openURL = try request.url()
    guard launch(openURL) else {
        write("fieldnotes: Launch Services could not open FIELDNOTES\n", to: .standardError)
        exit(69)
    }
} catch {
    write("fieldnotes: \(error)\n", to: .standardError)
    exit(64)
}
