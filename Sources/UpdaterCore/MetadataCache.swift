import Foundation
import CryptoKit

public enum PublicURL {
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty,
              !host.contains(":"), !host.hasPrefix("["),
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local") else { return false }
        // Discovery must not probe local services. Only DNS hostnames are accepted.
        return host.contains(".") && host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil
    }
}

private final class MetadataRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(PublicURL.isAllowed) == true ? request : nil)
    }
}

public struct MetadataSnapshot: Codable, Sendable {
    public var data: Data
    public var fetchedAt: Date
}

/// Public metadata only: no account tokens, scripts, installers, or stale-on-error results.
public actor MetadataCache {
    public static let shared = MetadataCache()
    public typealias Loader = @Sendable (URL, Int) async throws -> Data
    private let directory: URL
    private let loader: Loader
    private var memory: [URL: MetadataSnapshot] = [:]
    private struct Pending { let id = UUID(); let task: Task<Data, Error> }
    private var pending: [URL: Pending] = [:]
    private var failures: [URL: (Date, String)] = [:]

    public init(directory: URL = AppIdentity.cacheDirectory.appendingPathComponent("Metadata"), loader: @escaping Loader = { try await MetadataCache.download($0, maxBytes: $1) }) {
        self.directory = directory; self.loader = loader
    }

    public func load(_ url: URL, ttl: TimeInterval, maxBytes: Int = 4 * 1024 * 1024, at now: Date = Date()) async throws -> MetadataSnapshot {
        guard PublicURL.isAllowed(url) else { throw CheckError.failed("This update source isn't a public HTTPS address.") }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name + ".plist")
        var cached = memory[url]
        if cached == nil, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes + 4096,
           let data = try? Data(contentsOf: file), let entry = try? PropertyListDecoder().decode(MetadataSnapshot.self, from: data) {
            cached = entry
        }
        if let cached, Self.isFresh(cached, ttl: ttl, at: now), cached.data.count <= maxBytes {
            memory[url] = cached; return cached
        }
        if let (retry, message) = failures[url], retry > now { throw CheckError.failed(message) }
        let request: Pending
        if let existing = pending[url] { request = existing }
        else { request = Pending(task: Task { try await loader(url, maxBytes) }); pending[url] = request }
        defer { if pending[url]?.id == request.id { pending[url] = nil } }
        let data: Data
        do { data = try await request.task.value; try Task.checkCancellation() }
        catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled, !Task.isCancelled {
                failures[url] = (now.addingTimeInterval(300), error.localizedDescription)
            }
            throw error
        }
        guard data.count <= maxBytes else { throw CheckError.invalidResponse }
        let entry = MetadataSnapshot(data: data, fetchedAt: now)
        memory[url] = entry
        if let encoded = try? PropertyListEncoder.binary.encode(entry) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? encoded.write(to: file, options: .atomic)
        }
        return entry
    }

    /// Used by the dedicated advisory cache when its privacy toggle is turned off.
    /// Update and release-note caches are separate and remain untouched.
    public func cancelPending() {
        let requests = pending.values.map(\.task)
        pending.removeAll()
        for request in requests { request.cancel() }
    }

    public static func isFresh(_ entry: MetadataSnapshot, ttl: TimeInterval, at date: Date) -> Bool {
        let age = date.timeIntervalSince(entry.fetchedAt)
        return age >= 0 && age < ttl
    }

    public static func download(_ url: URL, maxBytes: Int) async throws -> Data {
        guard PublicURL.isAllowed(url) else { throw CheckError.invalidResponse }
        if url.host == "api.github.com" { try await GitHubRequestBudget.shared.reserve() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35)
        request.setValue("upd8er/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, application/yaml, text/yaml, */*", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: MetadataRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if url.host == "api.github.com", let http = response as? HTTPURLResponse,
           http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(3600)
            await GitHubRequestBudget.shared.block(until: reset)
            if http.statusCode == 403 || http.statusCode == 429 {
                throw CheckError.failed("GitHub's public API limit has been reached. The check will retry after the limit resets.")
            }
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, PublicURL.isAllowed(final) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CheckError.failed(code == 429 ? "The update service is rate limiting requests. Try again later." : "The update service couldn't be reached (HTTP \(code)).")
        }
        guard response.expectedContentLength <= maxBytes else { throw CheckError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw CheckError.invalidResponse }
        }
        return data
    }
}

public actor GitHubRequestBudget {
    public static let shared = GitHubRequestBudget()
    private let limit: Int
    private var started = Date.distantPast
    private var count = 0
    private var blockedUntil = Date.distantPast
    public init(limit: Int = 45) { self.limit = limit }
    public func reserve(at date: Date = Date()) throws {
        guard date >= blockedUntil else { throw CheckError.failed("GitHub's public API limit has been reached. The check will retry after the limit resets.") }
        if date.timeIntervalSince(started) >= 3600 { started = date; count = 0 }
        guard count < limit else { throw CheckError.failed("GitHub checks are paused to stay within the public API limit.") }
        count += 1
    }
    public func block(until date: Date) { blockedUntil = max(blockedUntil, date) }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder { let encoder = PropertyListEncoder(); encoder.outputFormat = .binary; return encoder }
}
