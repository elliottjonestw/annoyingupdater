import Foundation

/// Only stored public-registry provenance qualifies. The current registry setting alone
/// cannot establish where an already installed package came from.
enum NpmPackageOrigin {
    static func verify(name: String, version: String, manifest: Data, lock: Data?) -> VulnerabilityPackage? {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              object["name"] as? String == name, object["version"] as? String == version else { return nil }
        var address = object["_resolved"] as? String
        if let lock, let root = try? JSONSerialization.jsonObject(with: lock) as? [String: Any],
           let packages = root["packages"] as? [String: [String: Any]],
           let entry = packages["node_modules/" + name] ?? packages[name], entry["version"] as? String == version {
            address = entry["resolved"] as? String ?? address
        }
        guard let address, let url = URL(string: address), url.scheme == "https", url.host == "registry.npmjs.org",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.port == nil || url.port == 443,
              url.path.hasPrefix("/" + name + "/-/"),
              !url.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              url.lastPathComponent == name.split(separator: "/").last! + "-" + version + ".tgz" else { return nil }
        return VulnerabilityPackage(ecosystem: "npm", name: name)
    }
    static func inspect(inventory: Data, root: String) -> [String: VulnerabilityPackage] {
        guard let json = try? JSONSerialization.jsonObject(with: inventory) as? [String: Any], let packages = json["dependencies"] as? [String: [String: Any]] else { return [:] }
        let directory = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let lockURL = directory.appendingPathComponent(".package-lock.json").resolvingSymlinksInPath()
        let lock = lockURL.path.hasPrefix(directory.path + "/") ? try? ElectronProvider.boundedFile(lockURL, maxBytes: 4 * 1024 * 1024) : nil
        var verified: [String: VulnerabilityPackage] = [:]
        for (name, package) in packages {
            guard name.range(of: #"^(?:@[a-zA-Z0-9._-]+/)?[a-zA-Z0-9][a-zA-Z0-9._-]*$"#, options: .regularExpression) != nil, let version = package["version"] as? String else { continue }
            let url = directory.appendingPathComponent(name).appendingPathComponent("package.json").resolvingSymlinksInPath()
            guard url.path.hasPrefix(directory.path + "/"), let data = try? ElectronProvider.boundedFile(url, maxBytes: 512 * 1024) else { continue }
            verified[name] = verify(name: name, version: version, manifest: data, lock: lock)
        }
        return verified
    }
}
