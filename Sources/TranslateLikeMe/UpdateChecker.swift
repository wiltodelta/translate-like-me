import AppKit
import Observation

// Checks GitHub Releases for a newer version and offers to open the download
// page. This is a lightweight "check and notify" updater, not a silent in-place
// installer: the app is self-signed for personal use, so the user downloads the
// new build and replaces the bundle themselves.
//
// Runs automatically a few seconds after launch (silent when already current)
// and on demand from the Settings "Updates" section.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let githubRepo = "wiltodelta/translate-like-me"
    private let skippedVersionKey = "skippedUpdateVersion"
    private let currentVersion: String

    // Bound to the Settings button so it can show "Checking…" and disable itself.
    var isChecking = false

    private init() {
        // Read from Info.plist; falls back when running the raw binary from the CLI.
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var version: String { currentVersion }

    // `manual` = triggered from Settings: always report the outcome (including
    // "up to date" and errors) and ignore a previously skipped version. An
    // automatic check stays silent unless a newer, non-skipped version exists.
    func checkForUpdates(manual: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let release = try await fetchLatestRelease()
                handle(release, manual: manual)
            } catch {
                NSLog("Update check failed: \(error.localizedDescription)")
                if manual { showErrorAlert() }
            }
        }
    }

    // MARK: - Networking

    private func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func handle(_ release: GitHubRelease, manual: Bool) {
        let latest = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName

        guard Self.isNewer(latest, than: currentVersion) else {
            if manual { showUpToDateAlert() }
            return
        }
        // Honour a skipped version only for automatic checks; a manual check
        // always surfaces the available update.
        if !manual, UserDefaults.standard.string(forKey: skippedVersionKey) == latest {
            return
        }
        showUpdateAlert(version: latest, url: release.htmlURL, notes: release.body)
    }

    // Numeric dot-separated compare: 1.10 > 1.9, missing components count as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").compactMap { Int($0) }
        let rhs = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Alerts

    private func showUpdateAlert(version: String, url: String, notes: String?) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        var body = "Translate Like Me \(version) is available. You have \(currentVersion)."
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body += "\n\n\(notes)"
        }
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Skip this version")
        alert.addButton(withTitle: "Remind me later")

        switch runModal(alert) {
        case .alertFirstButtonReturn:
            if let downloadURL = URL(string: url) { NSWorkspace.shared.open(downloadURL) }
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(version, forKey: skippedVersionKey)
        default:
            break
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Translate Like Me \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }

    private func showErrorAlert() {
        let alert = NSAlert()
        alert.messageText = "Update check failed"
        alert.informativeText = "Could not check for updates. Please try again later, "
            + "or check the releases page on GitHub."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }

    // An accessory app must briefly become regular to bring a modal to the front.
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(.accessory) }
        return alert.runModal()
    }
}

// MARK: - GitHub API model

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
    }
}
