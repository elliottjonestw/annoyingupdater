import Foundation

/// The app and diagnostic executable share this private, metadata-only worker.
/// Running it before AppKit starts avoids creating another UI or login item.
public enum InventoryWorker {
    private struct Request: Codable { var roots: [String]; var paths: [String] }
    public static func handleCommandLine() -> Bool {
        guard CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--inspect-app-metadata" else { return false }
        guard CommandLine.arguments.count == 3, CommandLine.arguments[2].utf8.count < 4_000_000,
              let data = Data(base64Encoded: CommandLine.arguments[2]),
              let request = try? JSONDecoder().decode(Request.self, from: data), request.roots.count <= 16, request.paths.count <= 10_000,
              (request.roots + request.paths).allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { return true }
        let result = Inventory.inspect(in: request.roots.map { URL(fileURLWithPath: $0) }, additionalApps: request.paths.map { URL(fileURLWithPath: $0) })
        if let output = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(output) }
        return true
    }
    public static func inspect(roots: [String], paths: [String], timeout: TimeInterval) async -> InventoryInspection {
        do {
            guard let executable = Bundle.main.executableURL?.path else { throw CheckError.invalidResponse }
            let data = try JSONEncoder().encode(Request(roots: roots, paths: paths))
            let output = try await CommandRunner.run(executable, ["--inspect-app-metadata", data.base64EncodedString()], timeout: timeout).requireSuccess()
            return try JSONDecoder().decode(InventoryInspection.self, from: output)
        } catch { return InventoryInspection(apps: [], uncertainPaths: roots + paths) }
    }
}
