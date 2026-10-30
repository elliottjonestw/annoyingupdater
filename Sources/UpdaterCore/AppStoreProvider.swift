import Foundation

public enum AppStoreProvider {
    public static func check(_ apps: [InstalledApp], country: String) async -> [UpdateItem] {
        guard !apps.isEmpty else { return [] }
        var items = apps.map { app -> UpdateItem in
            var item = app.item; item.source = .appStore; item.status = .unverified; item.action = .appStore(nil)
            item.detail = "The App Store couldn't identify this installation. Open the App Store to check for updates."
            return item
        }
        var ids: [String: Int] = [:]
        for (index, app) in apps.enumerated() {
            guard let output = try? await CommandRunner.run("/usr/bin/mdls", ["-raw", "-name", "kMDItemAppStoreAdamID", app.path], timeout: 5), output.status == 0 else { continue }
            let id = output.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            if !id.isEmpty && id.allSatisfy(\.isNumber) {
                ids[id] = index; items[index].action = .appStore(id)
                items[index].releaseNotes?.prepend(ReleaseNotesSource(.appStore, url: URL(string: "https://apps.apple.com/app/id\(id)")!, identifier: id, region: country, bundleID: app.bundleID))
            }
        }
        // Batch identifiers to avoid a separate network request for every app.
        let sorted = ids.keys.sorted()
        for start in stride(from: 0, to: sorted.count, by: 20) {
            let batch = Array(sorted[start..<min(start + 20, sorted.count)])
            do {
                var components = URLComponents(string: "https://itunes.apple.com/lookup")!
                components.queryItems = [URLQueryItem(name: "id", value: batch.joined(separator: ",")), URLQueryItem(name: "entity", value: "macSoftware"), URLQueryItem(name: "country", value: country)]
                let data = try await Network.data(from: components.url!)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = json["results"] as? [[String: Any]] else { throw CheckError.invalidResponse }
                for result in results {
                    guard let track = result["trackId"] as? NSNumber, let index = ids[track.stringValue],
                          let version = result["version"] as? String, result["bundleId"] as? String == apps[index].bundleID else { continue }
                    if let minimum = result["minimumOsVersion"] as? String {
                        let os = ProcessInfo.processInfo.operatingSystemVersion
                        if Versions.newer(minimum, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") {
                            items[index].detail = "The latest catalog release requires macOS \(minimum). The App Store may offer an older compatible update."
                            continue
                        }
                    }
                    let available = Versions.newer(version, than: apps[index].version)
                    items[index].status = available ? .available : .current
                    items[index].availableVersion = available ? version : nil
                    items[index].detail = "Compared with Apple's catalog for \(country.uppercased()). Catalog data can lag behind the App Store."
                    items[index].checkedAt = Date()
                }
            } catch {
                for id in batch { if let index = ids[id] { items[index].detail = error.localizedDescription } }
            }
            if start + 20 < sorted.count { try? await Task.sleep(for: .seconds(3)) }
        }
        return items
    }
}
