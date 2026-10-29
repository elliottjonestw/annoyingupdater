import Foundation
import Testing
@testable import UpdaterCore

@Suite("GitHub repository discovery")
struct GitHubTests {
    let app = InstalledApp(path: "/Applications/Example.app", name: "Example", bundleID: "com.example.app", version: "1.0.0", build: "1")
    let package = Data(#"{"name":"example","version":"1.0.0","repository":{"url":"git+https://github.com/example/app.git"}}"#.utf8)
    func release(tag: String = "v1.1.0", asset: String = "Example-mac-arm64.zip", prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","draft":false,"prerelease":\(prerelease),"assets":[
         {"name":"\(asset)","state":"uploaded","browser_download_url":"https://github.com/example/app/releases/download/\(tag)/\(asset)"}]}
        """.utf8)
    }
    @Test func discoversOnlyExplicitGitHubURLs() {
        #expect(GitHubRepository.parse("git@github.com:example/app.git")?.name == "app")
        #expect(GitHubRepository.parse("git+https://github.com/example/app.git")?.owner == "example")
        for address in ["https://github.com/example/app/issues", "https://github.com.evil.test/example/app", "file:///example/app", "https://user:secret@github.com/example/app"] {
            #expect(GitHubRepository.parse(address) == nil)
        }
    }
    @Test func rootPackageVersionMustDescribeInstalledProduct() throws {
        #expect(try GitHubProvider.metadata(package, app: app) != nil)
        let library = Data(#"{"name":"dependency","version":"99.0.0","repository":"https://github.com/other/library"}"#.utf8)
        #expect(try GitHubProvider.metadata(library, app: app) == nil)
    }
    @Test func matchingStableMacAssetCanNotify() throws {
        let metadata = try #require(try GitHubProvider.metadata(package, app: app))
        let item = try GitHubProvider.evaluate(release(), app: app, metadata: metadata, platform: .init(os: "14.0", architecture: "arm64"))
        #expect(item.status == .available); #expect(item.availableVersion == "1.1.0"); #expect(!item.action.isDirect)
    }
    @Test func rejectsPrereleaseWrongProductWrongPlatformAndWrongArchitecture() throws {
        let metadata = try #require(try GitHubProvider.metadata(package, app: app))
        for data in [release(prerelease: true), release(tag: "v2.0.0-beta.1"), release(asset: "Other-mac-arm64.zip"),
                     release(asset: "Example-win-x64.zip"), release(asset: "Example-linux-arm64.zip"), release(asset: "Example-mac-x64.zip")] {
            #expect(try GitHubProvider.evaluate(data, app: app, metadata: metadata, platform: .init(os: "14.0", architecture: "arm64")).status == .unverified)
        }
    }
    @Test func sameVersionWithReleasePrefixDoesNotNag() throws {
        let metadata = try #require(try GitHubProvider.metadata(package, app: app))
        #expect(try GitHubProvider.evaluate(release(tag: "release-1.0.0"), app: app, metadata: metadata, platform: .init(os: "14.0", architecture: "arm64")).status == .current)
    }
    @Test func networkFailureRemainsUnverified() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let appPath = root.appendingPathComponent("Example.app")
        let resources = appPath.appendingPathComponent("Contents/Resources/app")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try package.write(to: resources.appendingPathComponent("package.json"))
        let local = InstalledApp(path: appPath.path, name: app.name, bundleID: app.bundleID, version: app.version, build: app.build)
        let cache = MetadataCache(directory: root.appendingPathComponent("cache"), loader: { _, _ in throw CheckError.failed("Rate limited") })
        let (items, report) = await GitHubProvider.check([local], cache: cache)
        #expect(items.first?.status == .unverified); #expect(report.hasError)
    }
    @Test func nestedDependencyPackageIsNotAnAppSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Contents/Resources/app/node_modules/library")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try package.write(to: nested.appendingPathComponent("package.json"))
        let local = InstalledApp(path: root.path, name: app.name, bundleID: app.bundleID, version: app.version, build: app.build)
        #expect(try RootPackage.data(in: local) == nil)
    }
    @Test func readsASARRootWithoutExtractingOrExecutingArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("app.asar")
        let json = try JSONSerialization.data(withJSONObject: ["files": ["package.json": ["size": package.count, "offset": "0"]]])
        var payload = Data(); append32(UInt32(json.count), to: &payload); payload.append(json)
        while payload.count % 4 != 0 { payload.append(0) }
        var header = Data(); append32(UInt32(payload.count), to: &header); header.append(payload)
        var archive = Data(); append32(4, to: &archive); append32(UInt32(header.count), to: &archive); archive.append(header); archive.append(package)
        try archive.write(to: url)
        #expect(try RootPackage.readASAR(url) == package)
        try Data([4, 0, 0, 0, 255, 255, 255, 127]).write(to: url)
        #expect(throws: (any Error).self) { try RootPackage.readASAR(url) }
    }
    @Test func respectsUnauthenticatedRequestBudgetAndReset() async throws {
        let budget = GitHubRequestBudget(limit: 1)
        let date = Date(timeIntervalSince1970: 10000)
        try await budget.reserve(at: date)
        do { try await budget.reserve(at: date); Issue.record("Expected request limit") } catch { }
        try await budget.reserve(at: date.addingTimeInterval(3600))
        await budget.block(until: date.addingTimeInterval(7200))
        do { try await budget.reserve(at: date.addingTimeInterval(4000)); Issue.record("Expected server cooldown") } catch { }
    }
    private func append32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
