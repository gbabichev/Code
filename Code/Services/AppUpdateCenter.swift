//
//  AppUpdateCenter.swift
//  Code
//

import AppKit
import Combine
import Foundation

@MainActor
final class AppUpdateCenter: ObservableObject {
    static let shared = AppUpdateCenter()

    @Published private(set) var isChecking = false
    @Published private(set) var lastStatusMessage: String?
    @Published private(set) var availableUpdate: AppAvailableUpdate?

    private var activeCheckTask: Task<Void, Never>?
    private let checker = GitHubTagUpdateChecker()

    private init() {}

    func dismissAvailableUpdate() {
        availableUpdate = nil
    }

    func openAvailableUpdateDownloadPage() {
        guard let releaseURL = availableUpdate?.releaseURL else { return }
        NSWorkspace.shared.open(releaseURL)
        availableUpdate = nil
    }

    func checkForUpdates(trigger: UpdateCheckTrigger = .manual) {
        guard activeCheckTask == nil else { return }

        guard let configuration = AppUpdateConfiguration.current() else {
            let message = "Update checking is not configured for this app."
            lastStatusMessage = message
            if trigger == .manual {
                presentInfoAlert(title: "Check for Updates", message: message)
            }
            return
        }

        isChecking = true
        lastStatusMessage = "Checking for updates..."
        availableUpdate = nil

        activeCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.isChecking = false
                self.activeCheckTask = nil
            }

            do {
                let latest = try await checker.latestVersionDetails(
                    owner: configuration.owner,
                    repository: configuration.repository,
                    userAgent: configuration.appName
                )

                let currentVersion = configuration.currentVersion
                let latestVersion = latest.tagName
                let isNewer = VersionStringComparator.isVersion(latestVersion, greaterThan: currentVersion)

                if isNewer {
                    let message = "Version \(latestVersion) is available. You have \(currentVersion)."
                    self.lastStatusMessage = message
                    self.availableUpdate = AppAvailableUpdate(
                        appName: configuration.appName,
                        latestVersion: latestVersion,
                        currentVersion: currentVersion,
                        message: message,
                        releaseNotes: latest.releaseNotes,
                        releaseURL: latest.releaseURL ?? configuration.releaseURL(for: latestVersion)
                    )
                    return
                }

                let message = "You're up to date (\(currentVersion))."
                self.lastStatusMessage = message

                if trigger == .manual {
                    self.presentInfoAlert(title: "Check for Updates", message: message)
                }
            } catch {
                let message = "Could not check for updates. \(error.localizedDescription)"
                self.lastStatusMessage = message

                if trigger == .manual {
                    self.presentInfoAlert(title: "Check for Updates", message: message)
                }
            }
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum UpdateCheckTrigger: Sendable {
    case automaticLaunch
    case manual
}

struct AppAvailableUpdate: Identifiable, Sendable {
    let id = UUID()
    let appName: String
    let latestVersion: String
    let currentVersion: String
    let message: String
    let releaseNotes: String?
    let releaseURL: URL?
}

private struct AppUpdateConfiguration: Sendable {
    let appName: String
    let currentVersion: String
    let owner: String
    let repository: String
    let releasesPageURL: URL?

    func releaseURL(for tag: String) -> URL? {
        guard let releasesPageURL else {
            return URL(string: "https://github.com/\(owner)/\(repository)/releases/tag/\(tag)")
        }

        let pathParts = releasesPageURL.pathComponents.filter { $0 != "/" }
        if pathParts.contains("releases") {
            return releasesPageURL.appendingPathComponent("tag").appendingPathComponent(tag)
        }

        return releasesPageURL
            .appendingPathComponent("releases")
            .appendingPathComponent("tag")
            .appendingPathComponent(tag)
    }

    nonisolated static func current(bundle: Bundle = .main) -> AppUpdateConfiguration? {
        let info = bundle.infoDictionary ?? [:]

        guard
            let releasesURLString = (info["UpdateCheckReleasesURL"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !releasesURLString.isEmpty,
            let releasesPageURL = URL(string: releasesURLString),
            let (owner, repository) = githubOwnerRepository(from: releasesPageURL)
        else {
            return nil
        }

        let appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? "This app"
        let currentVersion = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "0"

        return AppUpdateConfiguration(
            appName: appName,
            currentVersion: currentVersion,
            owner: owner,
            repository: repository,
            releasesPageURL: releasesPageURL
        )
    }

    private nonisolated static func githubOwnerRepository(from url: URL) -> (String, String)? {
        guard
            let host = url.host?.lowercased(),
            host.contains("github")
        else {
            return nil
        }

        let pathParts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard pathParts.count >= 2 else { return nil }

        let owner = pathParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = pathParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !repository.isEmpty else { return nil }

        return (owner, repository)
    }
}

private struct GitHubLatestVersionDetails: Sendable {
    let tagName: String
    let releaseNotes: String?
    let releaseURL: URL?
}

private struct GitHubTagUpdateChecker {
    private struct GitHubTag: Decodable, Sendable {
        let name: String
    }

    private struct GitHubRelease: Decodable, Sendable {
        let tagName: String
        let body: String?
        let htmlURL: String?
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }

    private enum UpdateCheckError: LocalizedError {
        case invalidResponse
        case noVersionsFound

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Received an invalid response from GitHub."
            case .noVersionsFound:
                return "No releases or tags were found for this repository."
            }
        }
    }

    func latestVersionDetails(owner: String, repository: String, userAgent: String) async throws -> GitHubLatestVersionDetails {
        do {
            if let releaseVersion = try await latestFromReleases(owner: owner, repository: repository, userAgent: userAgent) {
                return releaseVersion
            }
        } catch {
            // Older repos may only use tags, and GitHub release lookup can fail independently.
            // Keep update checks useful by falling back to tags.
        }

        if let tagVersion = try await latestFromTags(owner: owner, repository: repository, userAgent: userAgent) {
            return tagVersion
        }

        throw UpdateCheckError.noVersionsFound
    }

    private func latestFromReleases(owner: String, repository: String, userAgent: String) async throws -> GitHubLatestVersionDetails? {
        let releasesURL = try makeURL(
            "https://api.github.com/repos/\(owner)/\(repository)/releases",
            queryItems: [URLQueryItem(name: "per_page", value: "100")]
        )

        let (data, _) = try await fetch(url: releasesURL, userAgent: userAgent)
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

        let candidates = releases.filter { !$0.draft }
        guard !candidates.isEmpty else { return nil }

        let stableCandidates = candidates.filter { !$0.prerelease }
        let pool = stableCandidates.isEmpty ? candidates : stableCandidates

        guard let latest = pool.max(by: {
            VersionStringComparator.isVersion($1.tagName, greaterThan: $0.tagName)
        }) else {
            return nil
        }

        let trimmedNotes = latest.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let releaseNotes = trimmedNotes?.isEmpty == false ? trimmedNotes : nil
        let releaseURL = latest.htmlURL.flatMap { URL(string: $0) }
        return GitHubLatestVersionDetails(tagName: latest.tagName, releaseNotes: releaseNotes, releaseURL: releaseURL)
    }

    private func latestFromTags(owner: String, repository: String, userAgent: String) async throws -> GitHubLatestVersionDetails? {
        let tagsURL = try makeURL(
            "https://api.github.com/repos/\(owner)/\(repository)/tags",
            queryItems: [URLQueryItem(name: "per_page", value: "100")]
        )

        let (data, _) = try await fetch(url: tagsURL, userAgent: userAgent)
        let tags = try JSONDecoder().decode([GitHubTag].self, from: data)
        guard !tags.isEmpty else { return nil }

        guard let latestTag = tags.max(by: { lhs, rhs in
            VersionStringComparator.isVersion(rhs.name, greaterThan: lhs.name)
        }) else {
            return nil
        }

        return GitHubLatestVersionDetails(tagName: latestTag.name, releaseNotes: nil, releaseURL: nil)
    }

    private func makeURL(_ raw: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: raw) else {
            throw URLError(.badURL)
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func fetch(url: URL, userAgent: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw UpdateCheckError.invalidResponse
        }

        return (data, httpResponse)
    }
}

private enum VersionStringComparator {
    nonisolated static func isVersion(_ lhs: String, greaterThan rhs: String) -> Bool {
        let lhsComponents = numericComponents(from: lhs)
        let rhsComponents = numericComponents(from: rhs)
        let maxCount = max(lhsComponents.count, rhsComponents.count)

        for index in 0..<maxCount {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }

        return false
    }

    private nonisolated static func numericComponents(from rawVersion: String) -> [Int] {
        let trimmed = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let noPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let base = noPrefix.split(whereSeparator: { character in
            !(character.isNumber || character == ".")
        }).first ?? Substring("")

        let parts = base.split(separator: ".")
        let numericParts = parts.compactMap { Int($0) }
        if !numericParts.isEmpty {
            return numericParts
        }

        let digitsOnly = noPrefix.filter(\.isNumber)
        if let number = Int(digitsOnly) {
            return [number]
        }

        return [0]
    }
}
