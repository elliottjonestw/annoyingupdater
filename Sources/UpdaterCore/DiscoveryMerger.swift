import Foundation

public enum DiscoveryMerger {
    public static func merge(apps: [InstalledApp], homebrewCatalog: [UpdateItem] = [], appCatalog: [UpdateItem] = [],
                             managed: [UpdateItem] = [], repositories: [UpdateItem] = [], publisher: [UpdateItem] = [], store: [UpdateItem] = []) -> [UpdateItem] {
        var items = Dictionary(apps.map { ($0.path, $0.item) }, uniquingKeysWith: { first, _ in first })
        let identities = Set(items.keys)
        func known(_ item: UpdateItem?) -> Bool { item?.status == .available || item?.status == .current }
        for item in appCatalog where identities.contains(item.id) { items[item.id] = item }
        for item in homebrewCatalog where identities.contains(item.id) {
            if let existing = items[item.id], existing.status == .available,
               item.verificationIssue != .ambiguousEdition && item.verificationIssue != .platform {
                if item.status == .current { continue }
                if item.status == .available, let earlier = existing.availableVersion, let candidate = item.availableVersion,
                   !Versions.newer(candidate, than: earlier) { continue }
            }
            if item.verificationIssue == .ambiguousEdition || item.verificationIssue == .platform
                || known(item) || !known(items[item.id]) { items[item.id] = item }
        }
        for item in managed where identities.contains(item.id) {
            if known(item) || !known(items[item.id]) { items[item.id] = item }
        }
        for item in repositories where identities.contains(item.id) {
            // A repository's "latest" marker can lag the publisher's packaged release.
            if item.status == .current && items[item.id]?.status == .available { continue }
            if known(item) || !known(items[item.id]) { items[item.id] = item }
        }
        // An embedded publisher feed knows the app's channel and rollout policy.
        // Its current or unverified result must not be replaced by a catalog's newer release.
        for var item in publisher where identities.contains(item.id) {
            if item.status == .available, let installed = managed.first(where: { $0.id == item.id }),
               installed.status == .available, installed.availableVersion == item.availableVersion {
                item.action = installed.action
            }
            items[item.id] = item
        }
        for item in store where identities.contains(item.id) { items[item.id] = item }
        return items.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
