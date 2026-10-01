import AppKit
import SwiftUI

/// Looks for a newer Faulix release on GitHub (once a day, or from the app menu).
@MainActor
enum UpdateChecker {
    static let releasesAPI = URL(string: "https://api.github.com/repos/noemit/Helix-rade-ramon/releases/latest")!

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// True if `a` is a later version than `b` ("0.10" > "0.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        let y = b.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func checkAutomatically() {
        let key = "lastUpdateCheck"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        UserDefaults.standard.set(Date(), forKey: key)
        Task { await check(userInitiated: false) }
    }

    static func check(userInitiated: Bool) async {
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let body: String?
        }
        do {
            var req = URLRequest(url: releasesAPI)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let alert = NSAlert()
            if isNewer(release.tag_name, than: currentVersion) {
                let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                alert.messageText = L("Faulix \(version) is available")
                alert.informativeText = L("You have version \(currentVersion).") + "\n\n" + String((release.body ?? "").prefix(600))
                alert.addButton(withTitle: L("Download"))
                alert.addButton(withTitle: L("Later"))
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.html_url) }
            } else if userInitiated {
                alert.messageText = L("Faulix is up to date")
                alert.informativeText = L("Version \(currentVersion) is the newest version.")
                alert.runModal()
            }
        } catch {
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = L("Could not check for updates")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

struct UpdateCommands: View {
    var body: some View {
        Button("Check for Updates…") { Task { await UpdateChecker.check(userInitiated: true) } }
    }
}
