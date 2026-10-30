import Foundation

public enum OSVAdvisories {
    static func matchingPackages(_ record: [String: Any], package: VulnerabilityPackage) -> [[String: Any]] {
        (record["affected"] as? [[String: Any]] ?? []).filter {
            guard let identity = $0["package"] as? [String: Any] else { return false }
            return identity["ecosystem"] as? String == package.ecosystem && identity["name"] as? String == package.name
        }
    }
    static func range(_ events: [[String: String]], version: AdvisoryVersions.SemVer) -> AdvisoryMatch {
        guard !events.isEmpty else { return .unknown }
        var start: AdvisoryVersions.SemVer?, lastEnd: AdvisoryVersions.SemVer?, open = false, inclusiveEnd = false
        var affected = false, uncertain = false
        for event in events {
            guard event.count == 1 else { return .unknown }
            if let value = event["introduced"] {
                guard !open else { return .unknown }
                if value == "0" { guard lastEnd == nil else { return .unknown }; start = nil }
                else {
                    guard let parsed = AdvisoryVersions.SemVer(value), lastEnd.map({ inclusiveEnd ? parsed > $0 : parsed >= $0 }) ?? true else { return .unknown }
                    start = parsed
                }
                open = true
            } else {
                guard open else { return .unknown }
                let fixed = event["fixed"], last = event["last_affected"], limit = event["limit"]
                guard let value = fixed ?? last ?? limit, let end = AdvisoryVersions.SemVer(value), start.map({ $0 <= end }) ?? true else { return .unknown }
                if (start.map { version >= $0 } ?? true) && (last != nil ? version <= end : version < end) { affected = true }
                if limit != nil && version >= end { uncertain = true }
                lastEnd = end; inclusiveEnd = last != nil; open = false
            }
        }
        if open && (start.map { version >= $0 } ?? true) { affected = true }
        return affected ? .affected : uncertain ? .unknown : .notAffected
    }
    static func applicability(_ packages: [[String: Any]], version: String) -> AdvisoryMatch {
        guard let parsed = AdvisoryVersions.SemVer(version), !packages.isEmpty else { return .unknown }
        var statuses: [AdvisoryMatch] = []
        for package in packages {
            if (package["versions"] as? [String] ?? []).contains(version) { return .affected }
            let ranges = package["ranges"] as? [[String: Any]] ?? []
            if ranges.isEmpty { statuses.append(.unknown) }
            for record in ranges {
                guard record["type"] as? String == "SEMVER", let events = record["events"] as? [[String: String]] else { statuses.append(.unknown); continue }
                statuses.append(range(events, version: parsed))
            }
        }
        if statuses.contains(.affected) { return .affected }
        return statuses.isEmpty || statuses.contains(.unknown) ? .unknown : .notAffected
    }
    public static func parse(_ data: Data, request: VulnerabilityRequest) throws -> (page: AdvisoryPage, next: String?) {
        guard let package = request.item.vulnerabilityPackage, package.ecosystem == "npm",
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else { throw CheckError.invalidResponse }
        let records: [[String: Any]]
        if root["vulns"] == nil { guard root.keys.allSatisfy({ $0 == "next_page_token" }) else { throw CheckError.invalidResponse }; records = [] }
        else { guard let value = root["vulns"] as? [[String: Any]] else { throw CheckError.invalidResponse }; records = value }
        var findings: [VulnerabilityFinding] = [], complete = true
        for record in records {
            guard let recordID = record["id"] as? String, recordID.range(of: #"^[A-Za-z0-9:_.-]{1,160}$"#, options: .regularExpression) != nil else { complete = false; continue }
            if record["withdrawn"] is String { continue }
            if let withdrawn = record["withdrawn"], !(withdrawn is NSNull) { complete = false; continue }
            let packages = matchingPackages(record, package: package)
            let match = applicability(packages, version: request.item.installedVersion)
            if match == .unknown { complete = false }
            guard match == .affected else { continue }
            let aliases = (record["aliases"] as? [String] ?? []).filter(VulnerabilityService.isCVE).sorted()
            let canonical = aliases.first ?? recordID
            let target = request.item.availableVersion.map { applicability(packages, version: $0) } ?? .unknown
            let specifics = record["database_specific"] as? [String: Any]
            let severity = (specifics?["severity"] as? String).flatMap(VulnerabilityService.severity)
            let ranges = packages.flatMap { $0["ranges"] as? [[String: Any]] ?? [] }
            let events = ranges.flatMap { $0["events"] as? [[String: String]] ?? [] }
            let fixed = Array(Set(events.compactMap { $0["fixed"] })).sorted { Versions.compare($0, $1) == .orderedAscending }
            let bounds = events.map { event -> String in
                if let value = event["introduced"] { return value == "0" ? "Earlier versions" : "From \(value)" }
                if let value = event["fixed"] { return "before \(value) (fixed)" }
                if let value = event["last_affected"] { return "through \(value)" }
                return "Limited publisher range"
            }.joined(separator: "; ")
            let summary = record["summary"] as? String ?? record["details"] as? String ?? "Published vulnerability affecting this package."
            findings.append(VulnerabilityFinding(id: canonical, aliases: Array(Set(aliases + [recordID])).sorted(), summary: NotesText.readable(summary), source: "OSV",
                url: URL(string: "https://osv.dev/vulnerability/\(recordID)")!, severity: severity, affectedRange: bounds.isEmpty ? "Explicit affected versions listed by the publisher" : bounds,
                fixedVersions: fixed, targetMatch: target))
        }
        if root["next_page_token"] != nil && !(root["next_page_token"] is String) { throw CheckError.invalidResponse }
        let token = root["next_page_token"] as? String
        guard token == nil || (token!.count <= 4096 && !token!.isEmpty) else { throw CheckError.invalidResponse }
        return (AdvisoryPage(findings: VulnerabilityService.deduplicate(findings), complete: complete, total: records.count, count: records.count), token)
    }
}
