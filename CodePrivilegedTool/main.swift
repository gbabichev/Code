import Darwin
import Foundation

private let commandName = "code"
private let allowedShellCommandPath = "/usr/local/bin/code"

private enum PrivilegedToolError: LocalizedError {
    case invalidArguments
    case invalidShellCommandPath(String)
    case bundledToolInvalid(String)
    case conflictingCommand(String)
    case invalidStagedFile(String)
    case invalidDestination(String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The privileged tool received invalid arguments."
        case .invalidShellCommandPath(let path):
            return "The privileged tool can only manage \(allowedShellCommandPath), not \(path)."
        case .bundledToolInvalid(let path):
            return "The bundled command line tool is missing or invalid: \(path)."
        case .conflictingCommand(let path):
            return "A different command already exists at \(path). It was left unchanged."
        case .invalidStagedFile(let path):
            return "The staged file is missing or invalid: \(path)."
        case .invalidDestination(let path):
            return "The destination file is invalid: \(path)."
        case .fileSystem(let message):
            return message
        }
    }
}

private struct FileMetadata {
    let owner: uid_t
    let group: gid_t
    let mode: mode_t
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw PrivilegedToolError.invalidArguments
    }

    switch command {
    case "--install-shell-command":
        guard arguments.count == 3 else { throw PrivilegedToolError.invalidArguments }
        try installShellCommand(
            bundledToolPath: arguments[1],
            installedPath: arguments[2]
        )
    case "--remove-shell-command":
        guard arguments.count == 2 else { throw PrivilegedToolError.invalidArguments }
        try removeShellCommand(installedPath: arguments[1])
    case "--write-file":
        guard arguments.count == 3 else { throw PrivilegedToolError.invalidArguments }
        try writeFile(stagedPath: arguments[1], destinationPath: arguments[2])
    default:
        throw PrivilegedToolError.invalidArguments
    }
}

private func installShellCommand(bundledToolPath: String, installedPath: String) throws {
    guard installedPath == allowedShellCommandPath else {
        throw PrivilegedToolError.invalidShellCommandPath(installedPath)
    }

    let bundledToolURL = URL(fileURLWithPath: bundledToolPath).standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: bundledToolURL.path),
          isBundledCommandLineTool(bundledToolURL) else {
        throw PrivilegedToolError.bundledToolInvalid(bundledToolPath)
    }

    let installedURL = URL(fileURLWithPath: installedPath)
    let directoryURL = installedURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )

    if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: installedURL.path) {
        let resolvedDestination = resolvedSymlinkDestination(destination, relativeTo: installedURL)
        guard isBundledCommandLineTool(resolvedDestination) else {
            throw PrivilegedToolError.conflictingCommand(installedURL.path)
        }
        try FileManager.default.removeItem(at: installedURL)
    } else if FileManager.default.fileExists(atPath: installedURL.path) {
        throw PrivilegedToolError.conflictingCommand(installedURL.path)
    }

    try FileManager.default.createSymbolicLink(at: installedURL, withDestinationURL: bundledToolURL)
}

private func removeShellCommand(installedPath: String) throws {
    guard installedPath == allowedShellCommandPath else {
        throw PrivilegedToolError.invalidShellCommandPath(installedPath)
    }

    let installedURL = URL(fileURLWithPath: installedPath)
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: installedURL.path) else {
        if FileManager.default.fileExists(atPath: installedURL.path) {
            throw PrivilegedToolError.conflictingCommand(installedURL.path)
        }
        return
    }

    let resolvedDestination = resolvedSymlinkDestination(destination, relativeTo: installedURL)
    guard isBundledCommandLineTool(resolvedDestination) else {
        throw PrivilegedToolError.conflictingCommand(installedURL.path)
    }

    try FileManager.default.removeItem(at: installedURL)
}

private func writeFile(stagedPath: String, destinationPath: String) throws {
    let stagedURL = URL(fileURLWithPath: stagedPath).standardizedFileURL
    let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL

    guard stagedURL.path.hasPrefix("/") else {
        throw PrivilegedToolError.invalidStagedFile(stagedPath)
    }

    guard destinationURL.path.hasPrefix("/") else {
        throw PrivilegedToolError.invalidDestination(destinationPath)
    }

    guard isRegularFile(stagedURL), !isSymlink(stagedURL) else {
        throw PrivilegedToolError.invalidStagedFile(stagedPath)
    }

    if FileManager.default.fileExists(atPath: destinationURL.path) {
        guard isRegularFile(destinationURL), !isSymlink(destinationURL) else {
            throw PrivilegedToolError.invalidDestination(destinationPath)
        }
    }

    let parentURL = destinationURL.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard unsafe FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw PrivilegedToolError.invalidDestination(destinationPath)
    }

    let metadata = fileMetadata(for: destinationURL)
        ?? FileMetadata(owner: 0, group: 0, mode: 0o644)
    let temporaryURL = parentURL.appendingPathComponent(".\(destinationURL.lastPathComponent).code-\(UUID().uuidString).tmp")

    do {
        let data = try Data(contentsOf: stagedURL)
        try data.write(to: temporaryURL, options: [])
        try apply(metadata: metadata, to: temporaryURL)
        try replaceItem(at: destinationURL, with: temporaryURL)
    } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw PrivilegedToolError.fileSystem(error.localizedDescription)
    }
}

private func isBundledCommandLineTool(_ url: URL) -> Bool {
    guard url.lastPathComponent == commandName,
          url.pathComponents.contains("Helpers"),
          containingAppBundle(for: url) != nil else {
        return false
    }

    return true
}

private func containingAppBundle(for url: URL) -> URL? {
    var cursor = url.deletingLastPathComponent()
    while cursor.path != "/" {
        if cursor.pathExtension == "app" {
            return cursor
        }
        cursor.deleteLastPathComponent()
    }
    return nil
}

private func resolvedSymlinkDestination(_ destination: String, relativeTo installedURL: URL) -> URL {
    let destinationURL: URL
    if destination.hasPrefix("/") {
        destinationURL = URL(fileURLWithPath: destination)
    } else {
        destinationURL = installedURL
            .deletingLastPathComponent()
            .appendingPathComponent(destination)
    }
    return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
}

private func isRegularFile(_ url: URL) -> Bool {
    var statBuffer = stat()
    guard unsafe stat(url.path, &statBuffer) == 0 else { return false }
    return (statBuffer.st_mode & S_IFMT) == S_IFREG
}

private func isSymlink(_ url: URL) -> Bool {
    var statBuffer = stat()
    guard unsafe lstat(url.path, &statBuffer) == 0 else { return false }
    return (statBuffer.st_mode & S_IFMT) == S_IFLNK
}

private func fileMetadata(for url: URL) -> FileMetadata? {
    var statBuffer = stat()
    guard unsafe stat(url.path, &statBuffer) == 0 else { return nil }
    return FileMetadata(
        owner: statBuffer.st_uid,
        group: statBuffer.st_gid,
        mode: statBuffer.st_mode & 0o7777
    )
}

private func apply(metadata: FileMetadata, to url: URL) throws {
    guard unsafe chown(url.path, metadata.owner, metadata.group) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
    }

    guard unsafe chmod(url.path, metadata.mode) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
    }
}

private func replaceItem(at destinationURL: URL, with temporaryURL: URL) throws {
    guard unsafe rename(temporaryURL.path, destinationURL.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
    }
}

do {
    try run()
    print("OK")
    exit(EXIT_SUCCESS)
} catch {
    print("ERROR\t\(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
