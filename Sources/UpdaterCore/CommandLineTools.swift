import Foundation

public struct ToolCheck: Sendable {
    public var items: [UpdateItem] = []
    public var snapshots: [SoftwareSnapshot] = []
    public var uncertainPaths: [String] = []
    public var reports: [ProviderReport] = []
}

public enum CommandLineTools {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static var brewExecutables: [String] {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static var npmExecutables: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
        let versions = home.appendingPathComponent(".nvm/versions/node")
        for entry in (try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? [] {
            if entry.lastPathComponent.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil {
                paths.append(entry.appendingPathComponent("bin/npm").path)
            }
        }
        return paths.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func check() async -> ToolCheck {
        var result = ToolCheck()
        for executable in brewExecutables {
            let prefix = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path
            do {
                _ = try await CommandRunner.run(executable, ["update", "--quiet"], timeout: 90).requireSuccess()
                let installed = try await CommandRunner.run(executable, ["info", "--formula", "--installed", "--json=v2"], timeout: 60).requireSuccess()
                // Keep installed observations even if the network/update listing subsequently fails.
                let baseline = try parseBrew(installed: installed, outdated: nil, executable: executable, prefix: prefix)
                result.snapshots += baseline.snapshots
                result.uncertainPaths += baseline.uncertainPaths
                let start = result.items.count
                result.items += baseline.items
                let outdated = try await CommandRunner.run(executable, ["outdated", "--formula", "--json=v2"], timeout: 60).requireSuccess()
                let parsed = try parseBrew(installed: installed, outdated: outdated, executable: executable, prefix: prefix)
                result.items.replaceSubrange(start..<result.items.count, with: parsed.items)
                result.reports.append(ProviderReport("Homebrew Tools (\(prefix))", "\(parsed.items.count) installed formulae checked"))
            } catch {
                result.uncertainPaths.append(prefix)
                result.reports.append(ProviderReport("Homebrew Tools (\(prefix))", error.localizedDescription, hasError: true))
            }
        }
        var seen = Set<String>()
        for executable in npmExecutables {
            let bin = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            let environment = ["PATH": bin + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
            var root = URL(fileURLWithPath: bin).deletingLastPathComponent().path
            do {
                let output = try await CommandRunner.run(executable, ["root", "--global"], timeout: 30, environment: environment).requireSuccess()
                let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/"), !path.contains("\n") else { throw CheckError.invalidResponse }
                root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard seen.insert(root).inserted else { continue }
                let inventory = try await CommandRunner.run(executable, ["ls", "--global", "--depth=0", "--json"], timeout: 45, environment: environment).requireSuccess()
                let baseline = try parseNpm(installed: inventory, outdated: nil, executable: executable, root: root)
                result.snapshots += baseline.snapshots
                let start = result.items.count
                result.items += baseline.items
                let outdated = try await CommandRunner.run(executable, ["outdated", "--global", "--json"], timeout: 60, environment: environment)
                guard outdated.status == 0 || outdated.status == 1 else { throw CheckError.failed("npm couldn't check its configured registry.") }
                let parsed = try parseNpm(installed: inventory, outdated: outdated.output, executable: executable, root: root)
                result.items.replaceSubrange(start..<result.items.count, with: parsed.items)
                result.reports.append(ProviderReport("npm Tools (\(root))", "\(parsed.items.count) global packages checked"))
            } catch {
                result.uncertainPaths.append(root)
                result.reports.append(ProviderReport("npm Tools (\(root))", "Global npm tools couldn't be checked. Check the installation and registry connection.", hasError: true))
            }
        }
        if brewExecutables.isEmpty { result.reports.append(ProviderReport("Homebrew Tools", "Homebrew is not installed")) }
        if npmExecutables.isEmpty { result.reports.append(ProviderReport("npm Tools", "No standard or nvm npm installation found")) }
        return result
    }

    public static func parseBrew(installed: Data, outdated: Data?, executable: String, prefix: String) throws -> ToolCheck {
        guard let object = try JSONSerialization.jsonObject(with: installed) as? [String: Any],
              let formulae = object["formulae"] as? [[String: Any]] else { throw CheckError.invalidResponse }
        var candidates: [String: [String: Any]] = [:]
        if let outdated {
            guard let object = try JSONSerialization.jsonObject(with: outdated) as? [String: Any],
                  let rows = object["formulae"] as? [[String: Any]] else { throw CheckError.invalidResponse }
            for row in rows { if let name = row["name"] as? String { candidates[name] = row } }
        }
        var result = ToolCheck()
        for formula in formulae {
            guard let name = formula["full_name"] as? String ?? formula["name"] as? String,
                  name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9@+._/-]*$"#, options: .regularExpression) != nil,
                  let kegs = formula["installed"] as? [[String: Any]], !kegs.isEmpty else { throw CheckError.invalidResponse }
            let versions = kegs.compactMap { $0["version"] as? String }
            guard versions.count == kegs.count, versions.allSatisfy({ !$0.isEmpty }) else { throw CheckError.invalidResponse }
            let linked = formula["linked_keg"] as? String
            let stable = (formula["versions"] as? [String: Any])?["stable"] as? String
            let revision = formula["revision"] as? Int ?? 0
            let target = stable.map { $0 + (revision > 0 ? "_\(revision)" : "") }
            let installedVersion = linked.flatMap { versions.contains($0) ? $0 : nil }
                ?? target.flatMap { versions.contains($0) ? $0 : nil } ?? (versions.count == 1 ? versions[0] : nil)
            let candidate = candidates[name] ?? (formula["name"] as? String).flatMap { candidates[$0] }
            let id = "tool:brew:\(prefix):\(name)"
            let path = prefix + "/opt/" + name.components(separatedBy: "/").last!
            let pinned = formula["pinned"] as? Bool == true || candidate?["pinned"] as? Bool == true
            let dependency = kegs.allSatisfy { $0["installed_on_request"] as? Bool == false }
            var item = UpdateItem(id: id, name: name, path: path, installedVersion: installedVersion ?? versions.joined(separator: ", "),
                source: .homebrewFormula, status: .unverified, detail: "Homebrew formula\(dependency ? " · Dependency" : "") · \(prefix)", softwareKind: .commandLineTool)
            if let homepage = (formula["homepage"] as? String).flatMap(URL.init(string:)), let source = ReleaseNotesSource.publisher(homepage) {
                item.releaseNotes = ReleaseNotesContext(sources: [source])
            }
            if let installedVersion {
                result.snapshots.append(SoftwareSnapshot(id: id, name: name, path: path, version: installedVersion, kind: .commandLineTool))
                if outdated != nil {
                    if let candidate {
                        guard let current = candidate["current_version"] as? String, !current.isEmpty else { throw CheckError.invalidResponse }
                        item.status = .available; item.availableVersion = current
                    } else if installedVersion.hasPrefix("HEAD") {
                        item.detail += ". Development builds require a Homebrew HEAD check."
                    } else { item.status = .current }
                    item.checkedAt = Date()
                }
                if pinned {
                    item.detail += ". Pinned in Homebrew. Review the pin in Homebrew before upgrading."
                } else {
                    item.action = .copyCommand("\(quote(executable)) upgrade --formula \(quote(name))")
                    item.detail += ". Copy the update command and run it in Terminal. Homebrew may also update dependencies or services."
                }
            } else {
                result.uncertainPaths.append(path)
                item.detail += ". Multiple installed kegs could not be resolved to an active version."
            }
            result.items.append(item)
        }
        return result
    }

    public static func parseNpm(installed: Data, outdated: Data?, executable: String, root: String) throws -> ToolCheck {
        guard let inventory = try JSONSerialization.jsonObject(with: installed) as? [String: Any], inventory["error"] == nil,
              inventory["problems"] == nil else { throw CheckError.invalidResponse }
        if inventory["dependencies"] != nil && !(inventory["dependencies"] is [String: [String: Any]]) { throw CheckError.invalidResponse }
        let packages = inventory["dependencies"] as? [String: [String: Any]] ?? [:]
        var candidates: [String: [String: Any]] = [:]
        if let outdated {
            guard let object = try JSONSerialization.jsonObject(with: outdated) as? [String: Any], object["error"] == nil else { throw CheckError.invalidResponse }
            for (name, value) in object {
                guard let row = value as? [String: Any], row["current"] is String, row["latest"] is String else { throw CheckError.invalidResponse }
                candidates[name] = row
            }
        }
        var result = ToolCheck()
        for (name, package) in packages.sorted(by: { $0.key < $1.key }) {
            guard name.range(of: #"^(?:@[a-zA-Z0-9._-]+/)?[a-zA-Z0-9][a-zA-Z0-9._-]*$"#, options: .regularExpression) != nil,
                  let version = package["version"] as? String, !version.isEmpty else { throw CheckError.invalidResponse }
            let id = "tool:npm:\(root):\(name)"
            let path = root + "/" + name
            var item = UpdateItem(id: id, name: name, path: path, installedVersion: version, source: .npm, status: .unverified,
                detail: "Global npm tool · \(root)", softwareKind: .commandLineTool)
            result.snapshots.append(SoftwareSnapshot(id: id, name: name, path: path, version: version, kind: .commandLineTool))
            if let candidate = candidates[name] {
                let current = candidate["current"] as! String, latest = candidate["latest"] as! String
                if current == version, ReleaseVersions.status(candidate: latest, installed: version, build: version) == .available {
                    item.status = .available; item.availableVersion = latest
                } else if current == version, latest == version { item.status = .current }
                else { item.detail += ". npm's inventory and registry result couldn't be reconciled." }
            } else if outdated != nil { item.status = .current }
            let node = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("node").path
            item.action = .copyCommand("\(quote(node)) \(quote(URL(fileURLWithPath: executable).resolvingSymlinksInPath().path)) install --global \(quote(name + "@latest"))")
            item.detail += ". Copy the command to update with this Node installation. Major versions may change behavior."
            if outdated != nil { item.checkedAt = Date() }
            result.items.append(item)
        }
        return result
    }
}
