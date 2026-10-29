import Foundation

public enum SystemProvider {
    public static func parse(_ result: CommandResult, installedVersion: String, at date: Date = Date()) throws -> [UpdateItem] {
        _ = try result.requireSuccess()
        // Some macOS versions write the explicit no-update result to stderr.
        return try parse(result.text + "\n" + String(decoding: result.errorOutput, as: UTF8.self), installedVersion: installedVersion, at: date)
    }
    public static func parse(_ text: String, installedVersion: String, at date: Date = Date()) throws -> [UpdateItem] {
        if text.contains("No new software available") { return [] }
        let expression = try NSRegularExpression(pattern: #"Title:\s*(.+?),\s*Version:\s*([^,\n]+)"#)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { throw CheckError.invalidResponse }
        return matches.compactMap { match in
            guard let titleRange = Range(match.range(at: 1), in: text), let versionRange = Range(match.range(at: 2), in: text) else { return nil }
            let title = String(text[titleRange]).trimmingCharacters(in: .whitespaces)
            let version = String(text[versionRange]).trimmingCharacters(in: .whitespaces)
            return UpdateItem(id: "system:\(title):\(version)", name: title, installedVersion: title.lowercased().hasPrefix("macos") ? installedVersion : "System component",
                              availableVersion: version, source: .system, status: .available, action: .systemSettings,
                              detail: "Available for this Mac. Software Update handles installation and any required restart.", checkedAt: date)
        }
    }

    public static func check() async -> ([UpdateItem], ProviderReport) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        do {
            let result = try await CommandRunner.run("/usr/sbin/softwareupdate", ["--list"], timeout: 120)
            let updates = try parse(result, installedVersion: current)
            if !updates.isEmpty { return (updates, ProviderReport("macOS", "Checked with Software Update")) }
            return ([UpdateItem(id: "system:current", name: "macOS", installedVersion: current, source: .system, status: .current,
                action: .systemSettings, detail: "No updates are currently offered for this Mac.", checkedAt: Date())], ProviderReport("macOS", "Checked with Software Update"))
        } catch {
            return ([UpdateItem(id: "system:unknown", name: "macOS", installedVersion: current, source: .system, status: .unverified,
                action: .systemSettings, detail: error.localizedDescription)], ProviderReport("macOS", error.localizedDescription, hasError: true))
        }
    }
}
