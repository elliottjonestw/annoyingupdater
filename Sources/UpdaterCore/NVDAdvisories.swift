import Foundation

enum AdvisoryTruth { case yes, no, unknown, irrelevant }
public struct AdvisoryPage: Sendable {
    public var findings: [VulnerabilityFinding]
    public var complete: Bool
    public var total: Int
    public var count: Int
}
public enum NVDAdvisories {
    static func sameProduct(_ cpe: AdvisoryCPE, _ product: AdvisoryProduct) -> Bool {
        cpe.identity.part == product.part && cpe.identity.vendor == product.vendor && cpe.identity.product == product.product
    }
    static func versions(_ match: [String: Any], cpe: AdvisoryCPE, version: String) -> AdvisoryTruth {
        guard NotesVersions.numeric(version) != nil else { return .unknown }
        if cpe.fields[5] != "*" {
            guard let order = AdvisoryVersions.numeric(version, cpe.fields[5]) else { return .unknown }
            if order != .orderedSame { return .no }
        }
        for (key, inclusive, lower) in [("versionStartIncluding", true, true), ("versionStartExcluding", false, true),
                                        ("versionEndIncluding", true, false), ("versionEndExcluding", false, false)] {
            guard let raw = match[key] else { continue }
            guard let bound = raw as? String, let order = AdvisoryVersions.numeric(version, bound) else { return .unknown }
            if lower && (order == .orderedAscending || (!inclusive && order == .orderedSame)) { return .no }
            if !lower && (order == .orderedDescending || (!inclusive && order == .orderedSame)) { return .no }
        }
        return .yes
    }
    static func environment(_ cpe: AdvisoryCPE, match: [String: Any], request: VulnerabilityRequest) -> AdvisoryTruth {
        if cpe.identity.part == "o" {
            if cpe.identity.vendor == "apple", ["mac_os_x", "macos", "mac_os"].contains(cpe.identity.product) {
                if cpe.restrictions(request) == .notAffected { return .no }
                if cpe.restrictions(request) == .unknown { return .unknown }
                return versions(match, cpe: cpe, version: request.platform.os)
            }
            // These are explicit non-Mac operating-system requirements, not unknown components.
            let otherOS = ["microsoft", "linux", "linuxfoundation", "debian", "canonical", "fedoraproject", "redhat", "google"]
            if otherOS.contains(cpe.identity.vendor) || (cpe.identity.vendor == "apple" && ["iphone_os", "ipados", "watchos", "tvos", "visionos"].contains(cpe.identity.product)) { return .no }
        }
        return .unknown
    }
    static func combine(_ values: [AdvisoryTruth], operation: String) -> AdvisoryTruth {
        guard !values.isEmpty else { return .unknown }
        if operation == "AND" {
            if values.contains(where: { $0 == .no }) { return .no }
            if values.allSatisfy({ $0 == .yes }) { return .yes }
            return .unknown
        }
        if operation == "OR" {
            if values.contains(where: { $0 == .yes }) { return .yes }
            if values.contains(where: { $0 == .unknown }) { return .unknown }
            return values.allSatisfy { $0 == .irrelevant } ? .irrelevant : .no
        }
        return .unknown
    }
    static func containsProduct(_ node: [String: Any], product: AdvisoryProduct, depth: Int = 0) -> Bool {
        guard depth < 16 else { return false }
        if (node["cpeMatch"] as? [[String: Any]] ?? []).contains(where: {
            guard $0["vulnerable"] as? Bool == true, let value = $0["criteria"] as? String, let cpe = AdvisoryCPE(value) else { return false }
            return sameProduct(cpe, product)
        }) { return true }
        return ((node["nodes"] as? [[String: Any]] ?? []) + (node["children"] as? [[String: Any]] ?? [])).contains { containsProduct($0, product: product, depth: depth + 1) }
    }
    struct Evaluation { var truth: AdvisoryTruth; var proof = false }
    static func evaluate(_ node: [String: Any], product: AdvisoryProduct, request: VulnerabilityRequest, version: String, depth: Int = 0) -> Evaluation {
        guard depth < 16 else { return Evaluation(truth: .unknown) }
        if node["negate"] as? Bool == true { return Evaluation(truth: .unknown) } // Unsupported negation must never create a positive match.
        var values: [Evaluation] = []
        for match in node["cpeMatch"] as? [[String: Any]] ?? [] {
            guard let criteria = match["criteria"] as? String, let cpe = AdvisoryCPE(criteria), let vulnerable = match["vulnerable"] as? Bool else { values.append(Evaluation(truth: .unknown)); continue }
            if vulnerable {
                guard sameProduct(cpe, product) else { values.append(Evaluation(truth: .irrelevant)); continue }
                let restriction = cpe.restrictions(request)
                if restriction == .notAffected { values.append(Evaluation(truth: .no)) }
                else if restriction == .unknown || (product.needsEdition && [6, 7, 9, 12].contains(where: { cpe.fields[$0] == "-" })) { values.append(Evaluation(truth: .unknown)) }
                else { let truth = versions(match, cpe: cpe, version: version); values.append(Evaluation(truth: truth, proof: truth == .yes)) }
            } else { values.append(Evaluation(truth: environment(cpe, match: match, request: request))) }
        }
        for child in (node["nodes"] as? [[String: Any]] ?? []) + (node["children"] as? [[String: Any]] ?? []) {
            values.append(evaluate(child, product: product, request: request, version: version, depth: depth + 1))
        }
        let operation = node["operator"] as? String ?? (values.count == 1 ? "OR" : "")
        let truth = combine(values.map(\.truth), operation: operation)
        let proof = truth == .yes && values.contains { $0.truth == .yes && $0.proof }
        return Evaluation(truth: truth, proof: proof)
    }
    static func applicability(_ configurations: [[String: Any]], product: AdvisoryProduct, request: VulnerabilityRequest, version: String) -> AdvisoryMatch {
        let relevant = configurations.filter { containsProduct($0, product: product) }
        guard !relevant.isEmpty else { return .unknown }
        let evaluations = relevant.map { evaluate($0, product: product, request: request, version: version) }
        if evaluations.contains(where: { $0.truth == .yes && $0.proof }) { return .affected }
        if evaluations.allSatisfy({ $0.truth == .no }) { return .notAffected }
        return .unknown
    }
    static func ranges(_ configurations: [[String: Any]], product: AdvisoryProduct) -> [String] {
        func walk(_ node: [String: Any], depth: Int) -> [String] {
            guard depth < 16 else { return [] }
            var descriptions: [String] = []
            for match in node["cpeMatch"] as? [[String: Any]] ?? [] {
                guard match["vulnerable"] as? Bool == true, let raw = match["criteria"] as? String, let cpe = AdvisoryCPE(raw), sameProduct(cpe, product) else { continue }
                var bounds: [String] = []
                if cpe.fields[5] != "*" { bounds.append(cpe.fields[5]) }
                for (key, symbol) in [("versionStartIncluding", "≥"), ("versionStartExcluding", ">"), ("versionEndIncluding", "≤"), ("versionEndExcluding", "<")] {
                    if let bound = match[key] as? String { bounds.append("\(symbol) \(bound)") }
                }
                descriptions.append(bounds.isEmpty ? "All versions listed by this product rule" : bounds.joined(separator: ", "))
            }
            return descriptions + ((node["nodes"] as? [[String: Any]] ?? []) + (node["children"] as? [[String: Any]] ?? [])).flatMap { walk($0, depth: depth + 1) }
        }
        return Array(Set(configurations.flatMap { walk($0, depth: 0) })).sorted()
    }
    public static func parse(_ data: Data, product: AdvisoryProduct, request: VulnerabilityRequest) throws -> AdvisoryPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let records = root["vulnerabilities"] as? [[String: Any]], let total = root["totalResults"] as? Int, total >= records.count else { throw CheckError.invalidResponse }
        var findings: [VulnerabilityFinding] = [], complete = true
        for record in records {
            guard let cve = record["cve"] as? [String: Any], let id = cve["id"] as? String, VulnerabilityService.isCVE(id) else { complete = false; continue }
            if cve["vulnStatus"] as? String == "Rejected" { continue }
            let configurations = cve["configurations"] as? [[String: Any]] ?? []
            let status = applicability(configurations, product: product, request: request, version: request.item.installedVersion)
            if status == .unknown { complete = false }
            guard status == .affected else { continue }
            let target = request.item.availableVersion.map { applicability(configurations, product: product, request: request, version: $0) } ?? .unknown
            let descriptions = cve["descriptions"] as? [[String: Any]] ?? []
            let summary = descriptions.first { $0["lang"] as? String == "en" }?["value"] as? String ?? "Published vulnerability affecting this product."
            let metrics = cve["metrics"] as? [String: [[String: Any]]] ?? [:]
            let ratings = ["cvssMetricV40", "cvssMetricV31", "cvssMetricV30"].flatMap { metrics[$0] ?? [] }
            let rating = ratings.first { $0["type"] as? String == "Primary" } ?? ratings.first
            let cvss = rating?["cvssData"] as? [String: Any]
            let score = (cvss?["baseScore"] as? Double).flatMap { (0...10).contains($0) && $0.isFinite ? $0 : nil }
            let severity = (cvss?["baseSeverity"] as? String).flatMap(VulnerabilityService.severity)
            findings.append(VulnerabilityFinding(id: id, summary: NotesText.readable(summary), source: "NVD", url: URL(string: "https://nvd.nist.gov/vuln/detail/\(id)")!,
                severity: severity, score: score, affectedRange: ranges(configurations, product: product).joined(separator: "; "), targetMatch: target))
        }
        return AdvisoryPage(findings: VulnerabilityService.deduplicate(findings), complete: complete, total: total, count: records.count)
    }
}
