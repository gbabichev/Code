import AppKit
import Darwin
import Foundation

private let commandName = "code"
private let appBundleIdentifier = "com.georgebabichev.Code"

private enum CommandLineError: LocalizedError {
    case applicationNotFound
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return "Could not find Code.app."
        case .openFailed(let message):
            return message
        }
    }
}

private final class OpenResultBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.georgebabichev.CodeCLI.openResult")
    private var storedResult: Result<Void, Error>?

    var result: Result<Void, Error>? {
        queue.sync { storedResult }
    }

    func setResult(_ result: Result<Void, Error>) {
        queue.sync {
            storedResult = result
        }
    }
}

private func printUsage() {
    let message = """
    Usage: \(commandName) [path ...]

    Opens files or folders in Code.
    """
    print(message)
}

private func appURLContainingThisTool() -> URL? {
    for executableURL in candidateExecutableURLs() {
        if let appURL = appURLContainingExecutable(at: executableURL) {
            return appURL
        }
    }

    return nil
}

private func candidateExecutableURLs() -> [URL] {
    var urls: [URL] = []

    if let executableURL = currentProcessExecutableURL() {
        urls.append(executableURL)
    }

    if let argumentURL = executableURL(fromArgument: CommandLine.arguments[0]) {
        urls.append(argumentURL)
    }

    var seenPaths = Set<String>()
    return urls.filter { url in
        seenPaths.insert(url.path).inserted
    }
}

private func currentProcessExecutableURL() -> URL? {
    var length: UInt32 = 0
    _ = unsafe _NSGetExecutablePath(nil, &length)
    guard length > 0 else { return nil }

    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(length))
    defer { unsafe buffer.deallocate() }

    guard unsafe _NSGetExecutablePath(buffer, &length) == 0 else {
        return nil
    }

    if let resolvedPath = unsafe realpath(buffer, nil) {
        defer { unsafe free(resolvedPath) }
        return URL(fileURLWithPath: unsafe String(cString: resolvedPath))
    }

    return URL(fileURLWithPath: unsafe String(cString: buffer))
        .standardizedFileURL
        .resolvingSymlinksInPath()
}

private func executableURL(fromArgument argument: String) -> URL? {
    let expandedArgument = (argument as NSString).expandingTildeInPath
    let executableURL: URL?

    if expandedArgument.contains("/") {
        if expandedArgument.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: expandedArgument)
        } else {
            executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expandedArgument)
        }
    } else {
        executableURL = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .lazy
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(expandedArgument) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    return executableURL?
        .standardizedFileURL
        .resolvingSymlinksInPath()
}

private func appURLContainingExecutable(at executableURL: URL) -> URL? {
    var cursor = executableURL.deletingLastPathComponent()

    while cursor.path != "/" {
        if cursor.pathExtension == "app" {
            return cursor
        }
        cursor.deleteLastPathComponent()
    }

    return nil
}

private func writeError(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
}

private func codeApplicationURL() -> URL? {
    appURLContainingThisTool()
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleIdentifier)
}

private func fileURL(for argument: String) -> URL {
    let currentDirectoryURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    let expandedPath = (argument as NSString).expandingTildeInPath
    let absolutePath: String
    if expandedPath.hasPrefix("/") {
        absolutePath = expandedPath
    } else {
        absolutePath = currentDirectoryURL.appendingPathComponent(expandedPath).path
    }

    let absoluteURL = URL(fileURLWithPath: absolutePath).standardizedFileURL
    let isDirectory = (try? absoluteURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    return URL(fileURLWithPath: absolutePath, isDirectory: isDirectory)
        .standardizedFileURL
}

private func shouldSkipCocoaArgument(_ argument: String) -> Bool {
    argument.hasPrefix("-NS") || argument.hasPrefix("_NS")
}

private func looksLikeCocoaArgumentValue(_ argument: String) -> Bool {
    let normalizedArgument = argument.lowercased()
    return normalizedArgument == "yes"
        || normalizedArgument == "no"
        || normalizedArgument == "true"
        || normalizedArgument == "false"
        || normalizedArgument == "0"
        || normalizedArgument == "1"
}

private func parsedPathArguments(from arguments: [String]) -> [String] {
    var paths: [String] = []
    var index = arguments.startIndex
    var treatsRemainingArgumentsAsPaths = false

    while index < arguments.endIndex {
        let argument = arguments[index]

        if treatsRemainingArgumentsAsPaths {
            paths.append(argument)
            index = arguments.index(after: index)
            continue
        }

        switch argument {
        case "--":
            treatsRemainingArgumentsAsPaths = true
            index = arguments.index(after: index)
        case "--help", "-h":
            printUsage()
            exit(EXIT_SUCCESS)
        default:
            if shouldSkipCocoaArgument(argument) {
                index = arguments.index(after: index)
                if index < arguments.endIndex, looksLikeCocoaArgumentValue(arguments[index]) {
                    index = arguments.index(after: index)
                }
            } else {
                paths.append(argument)
                index = arguments.index(after: index)
            }
        }
    }

    return paths
}

private func waitForWorkspaceOpen(
    urls: [URL],
    appURL: URL
) -> Result<Void, Error> {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = true

    let resultBox = OpenResultBox()
    if urls.isEmpty {
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            resultBox.setResult(error.map(Result.failure) ?? .success(()))
        }
    } else {
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, error in
            resultBox.setResult(error.map(Result.failure) ?? .success(()))
        }
    }

    while resultBox.result == nil {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }

    return resultBox.result ?? .failure(CommandLineError.openFailed("Code did not respond."))
}

let pathArguments = parsedPathArguments(from: Array(CommandLine.arguments.dropFirst()))
let urls = pathArguments.map(fileURL(for:))

guard let appURL = codeApplicationURL() else {
    writeError("\(commandName): \(CommandLineError.applicationNotFound.localizedDescription)")
    exit(EXIT_FAILURE)
}

switch waitForWorkspaceOpen(urls: urls, appURL: appURL) {
case .success:
    exit(EXIT_SUCCESS)
case .failure(let error):
    writeError("\(commandName): \(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
