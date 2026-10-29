import Foundation

public enum HomebrewProvider {
    public static var executable: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func check(_ apps: [InstalledApp]) async -> ([UpdateItem], ProviderReport) {
        guard let brew = executable else { return ([], ProviderReport("Homebrew", "Not installed")) }
        do {
            // Explicit refresh: outdated alone may use stale metadata. Never install while checking.
            _ = try await CommandRunner.run(brew, ["update", "--quiet"], timeout: 90).requireSuccess()
            let data = try await CommandRunner.run(brew, ["outdated", "--cask", "--greedy-auto-updates", "--json=v2"], timeout: 60).requireSuccess()
            let info = try await CommandRunner.run(brew, ["info", "--cask", "--json=v2", "--installed"], timeout: 60).requireSuccess()
            return (try parse(outdated: data, installed: info, apps: apps, executable: brew), ProviderReport("Homebrew", "Checked installed casks"))
        } catch { return ([], ProviderReport("Homebrew", error.localizedDescription, hasError: true)) }
    }
    public static func parse(outdated: Data, installed: Data, apps: [InstalledApp], executable: String) throws -> [UpdateItem] {
        guard let out = try JSONSerialization.jsonObject(with: outdated) as? [String: Any], let outdatedCasks = out["casks"] as? [[String: Any]],
              let all = try JSONSerialization.jsonObject(with: installed) as? [String: Any], let casks = all["casks"] as? [[String: Any]] else { throw CheckError.invalidResponse }
        let outdatedNames = Set(outdatedCasks.compactMap { $0["name"] as? String })
        var items: [UpdateItem] = []
        for cask in casks {
            guard let token = cask["token"] as? String, let version = cask["version"] as? String,
                  token.range(of: #"^[a-z0-9][a-z0-9@+._/-]*$"#, options: .regularExpression) != nil,
                  let artifacts = cask["artifacts"] as? [[String: Any]] else { continue }
            let names = artifacts.flatMap { ($0["app"] as? [Any] ?? []).compactMap { $0 as? String } }.filter { $0.hasSuffix(".app") }
            for name in names {
                let candidates = apps.filter { URL(fileURLWithPath: $0.path).lastPathComponent == URL(fileURLWithPath: name).lastPathComponent && !$0.isAppStore }
                // Ambiguous installations must not be assigned an installer by name alone.
                guard candidates.count == 1, let app = candidates.first else { continue }
                var item = app.item; item.source = .homebrew
                item.action = .homebrew(executable: executable, cask: token)
                let comparable = version.components(separatedBy: ",").first ?? version
                if version == "latest" {
                    item.status = .unverified; item.detail = "Homebrew doesn't publish a comparable version for this app. Check in the app."
                    item.action = .openApp(app.path)
                } else {
                    let available = outdatedNames.contains(token) && Versions.newer(comparable, than: app.version)
                    // Do not mark an unresolved version-scheme mismatch current.
                    if outdatedNames.contains(token) && Versions.compare(comparable, app.version) == .orderedAscending {
                        item.status = .unverified; item.detail = "Homebrew's record differs from the installed app. Check in the app to avoid replacing a newer version."
                        item.action = .openApp(app.path)
                    } else {
                        item.status = available ? .available : .current; item.availableVersion = available ? comparable : nil
                        item.detail = "Managed by Homebrew. Installation uses the existing cask and doesn't force running apps to quit."
                        item.checkedAt = Date()
                    }
                }
                items.append(item)
            }
        }
        return items
    }
}
