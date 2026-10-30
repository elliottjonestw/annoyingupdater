import Foundation

public enum CheckError: LocalizedError {
    case failed(String), timedOut, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .timedOut: return "The update service took too long to respond. Try checking again."
        case .invalidResponse: return "The update service returned an unexpected response."
        }
    }
}

public struct CommandResult: Sendable {
    public var output: Data
    public var errorOutput: Data
    public var status: Int32
    public var text: String { String(decoding: output, as: UTF8.self) }
    public func requireSuccess() throws -> Data {
        guard status == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CheckError.failed(message.isEmpty ? "The update service couldn't complete the request (\(status))." : String(message.prefix(500)))
        }
        return output
    }
}

public enum CommandRunner {
    /// File-backed output avoids pipe-buffer deadlocks. No shell or password input is used.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60, environment: [String: String] = [:]) async throws -> CommandResult {
        try await Task.detached(priority: .utility) { try runBlocking(executable, arguments, timeout: timeout, additions: environment) }.value
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval, additions: [String: String]) throws -> CommandResult {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let outURL = directory.appendingPathComponent("stdout")
            let errURL = directory.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: outURL)
            let err = try FileHandle(forWritingTo: errURL)
            defer { try? out.close(); try? err.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"; environment["LANG"] = "en_US.UTF-8"
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"; environment["HOMEBREW_NO_ANALYTICS"] = "1"
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment.merge(additions) { _, new in new }
            process.environment = environment
            process.standardOutput = out; process.standardError = err
            process.standardInput = FileHandle.nullDevice
            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in semaphore.signal() }
            try process.run()
            if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                // Do not let an unresponsive tool block the app indefinitely.
                if semaphore.wait(timeout: .now() + 3) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
                throw CheckError.timedOut
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: outURL.path)
            guard (attributes[.size] as? Int ?? 0) < 16 * 1024 * 1024 else { throw CheckError.invalidResponse }
            return CommandResult(output: try Data(contentsOf: outURL), errorOutput: try Data(contentsOf: errURL), status: process.terminationStatus)
    }
}
