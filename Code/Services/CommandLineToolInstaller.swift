import AppKit
import Foundation

@MainActor
enum CommandLineToolInstaller {
    private static let commandName = "code"
    private static let installURL = URL(fileURLWithPath: "/usr/local/bin/code")

    enum InstallResult {
        case installed
        case updated
        case alreadyInstalled

        var title: String {
            switch self {
            case .installed:
                return "Command Line Tool Installed"
            case .updated:
                return "Command Line Tool Updated"
            case .alreadyInstalled:
                return "Command Line Tool Already Installed"
            }
        }

        var message: String {
            "You can now run `code file.txt` or `code .` from Terminal."
        }
    }

    enum RemovalResult {
        case removed
        case notInstalled

        var title: String {
            switch self {
            case .removed:
                return "Command Line Tool Removed"
            case .notInstalled:
                return "Command Line Tool Not Installed"
            }
        }

        var message: String {
            switch self {
            case .removed:
                return "`code` was removed from /usr/local/bin."
            case .notInstalled:
                return "No Code command line tool is installed at /usr/local/bin/code."
            }
        }
    }

    enum InstallError: LocalizedError {
        case bundledToolMissing(URL)
        case conflictingCommand(URL)
        case appleScriptUnavailable
        case privilegedInstallFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledToolMissing(let url):
                return "The bundled command line tool was not found at \(url.path)."
            case .conflictingCommand(let url):
                return "A different command already exists at \(url.path). It was left unchanged."
            case .appleScriptUnavailable:
                return "Could not start the privileged installer."
            case .privilegedInstallFailed(let message):
                return message
            }
        }
    }

    static var canRemoveInstalledTool: Bool {
        guard let state = try? existingCommandState() else {
            return false
        }

        switch state {
        case .current, .replaceable:
            return true
        case .absent, .conflict:
            return false
        }
    }

    static func installFromMenu() {
        do {
            let result = try install()
            showAlert(title: result.title, message: result.message, style: .informational)
        } catch {
            showAlert(
                title: "Could Not Install Command Line Tool",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    static func removeFromMenu() {
        do {
            let result = try remove()
            showAlert(title: result.title, message: result.message, style: .informational)
        } catch {
            showAlert(
                title: "Could Not Remove Command Line Tool",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    @discardableResult
    static func install() throws -> InstallResult {
        let bundledToolURL = try bundledTool()
        let existingState = try existingCommandState(installedURL: installURL, bundledToolURL: bundledToolURL)

        switch existingState {
        case .current:
            return .alreadyInstalled
        case .conflict:
            throw InstallError.conflictingCommand(installURL)
        case .absent:
            try installSymlink(to: bundledToolURL, replacingExistingItem: false)
            return .installed
        case .replaceable:
            try installSymlink(to: bundledToolURL, replacingExistingItem: true)
            return .updated
        }
    }

    @discardableResult
    static func remove() throws -> RemovalResult {
        let existingState = try existingCommandState()

        switch existingState {
        case .absent:
            return .notInstalled
        case .conflict:
            throw InstallError.conflictingCommand(installURL)
        case .current, .replaceable:
            try removeInstalledSymlink()
            return .removed
        }
    }

    private enum ExistingCommandState {
        case absent
        case current
        case replaceable
        case conflict
    }

    private static func bundledTool() throws -> URL {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent(commandName)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw InstallError.bundledToolMissing(url)
        }
        return url
    }

    private static func existingCommandState() throws -> ExistingCommandState {
        try existingCommandState(installedURL: installURL, bundledToolURL: bundledTool())
    }

    private static func existingCommandState(
        installedURL: URL,
        bundledToolURL: URL
    ) throws -> ExistingCommandState {
        let fileManager = FileManager.default
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: installedURL.path) {
            let resolvedDestination = resolvedSymlinkDestination(destination, relativeTo: installedURL)
            if resolvedDestination == bundledToolURL.resolvingSymlinksInPath() {
                return .current
            }
            return isCodeHelperSymlinkTarget(resolvedDestination) ? .replaceable : .conflict
        }

        if fileManager.fileExists(atPath: installedURL.path) {
            return .conflict
        }

        return .absent
    }

    private static func installSymlink(to bundledToolURL: URL, replacingExistingItem: Bool) throws {
        do {
            try installSymlinkWithoutPrivileges(to: bundledToolURL, replacingExistingItem: replacingExistingItem)
        } catch {
            try installSymlinkWithPrivileges(to: bundledToolURL, replacingExistingItem: replacingExistingItem)
        }
    }

    private static func installSymlinkWithoutPrivileges(
        to bundledToolURL: URL,
        replacingExistingItem: Bool
    ) throws {
        let fileManager = FileManager.default
        let directoryURL = installURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if replacingExistingItem {
            try fileManager.removeItem(at: installURL)
        }
        try fileManager.createSymbolicLink(at: installURL, withDestinationURL: bundledToolURL)
    }

    private static func installSymlinkWithPrivileges(
        to bundledToolURL: URL,
        replacingExistingItem: Bool
    ) throws {
        let directoryPath = shellQuoted(installURL.deletingLastPathComponent().path)
        let toolPath = shellQuoted(bundledToolURL.path)
        let installedPath = shellQuoted(installURL.path)
        let removeCommand = replacingExistingItem ? "/bin/rm -f \(installedPath) && " : ""
        let command = "/bin/mkdir -p \(directoryPath) && \(removeCommand)/bin/ln -s \(toolPath) \(installedPath)"
        let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges"

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw InstallError.appleScriptUnavailable
        }

        if process.terminationStatus != 0 {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.privilegedInstallFailed(
                (message?.isEmpty == false) ? (message ?? "") : "The privileged installer failed."
            )
        }
    }

    private static func removeInstalledSymlink() throws {
        do {
            try FileManager.default.removeItem(at: installURL)
        } catch {
            try removeInstalledSymlinkWithPrivileges()
        }
    }

    private static func removeInstalledSymlinkWithPrivileges() throws {
        let installedPath = shellQuoted(installURL.path)
        let command = "/bin/rm -f \(installedPath)"
        let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges"

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw InstallError.appleScriptUnavailable
        }

        if process.terminationStatus != 0 {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.privilegedInstallFailed(
                (message?.isEmpty == false) ? (message ?? "") : "The privileged remover failed."
            )
        }
    }

    private static func resolvedSymlinkDestination(_ destination: String, relativeTo installedURL: URL) -> URL {
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

    private static func isCodeHelperSymlinkTarget(_ url: URL) -> Bool {
        guard url.lastPathComponent == commandName,
              url.pathComponents.contains("Helpers"),
              let appURL = containingAppBundle(for: url) else {
            return false
        }

        return bundleIdentifier(for: appURL) == Bundle.main.bundleIdentifier
    }

    private static func containingAppBundle(for url: URL) -> URL? {
        var cursor = url.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" {
                return cursor
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private static func bundleIdentifier(for appURL: URL) -> String? {
        let infoPlistURL = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: infoPlistURL)?["CFBundleIdentifier"] as? String
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapedValue)\""
    }

    private static func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
