import Foundation
import UpdaterCore

@main
enum BrowserBridge {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let chromeOrigin = "chrome-extension://\(BrowserInventoryStore.chromiumID)/"
        let diagnostic = arguments.count == 3 && arguments[0] == "--diagnostic-directory"
        guard arguments.first == chromeOrigin || arguments.last == BrowserInventoryStore.firefoxID || diagnostic else { return }
        let store = diagnostic ? BrowserInventoryStore(directory: URL(fileURLWithPath: arguments[1])) : BrowserInventoryStore()
        do {
            // sendNativeMessage starts a new host for each bounded snapshot.
            guard let data = try NativeMessage.read(from: .standardInput) else { return }
            do {
                try store.save(data)
                try NativeMessage.write(Data("{\"ok\":true}".utf8), to: .standardOutput)
            } catch { try NativeMessage.write(Data("{\"ok\":false,\"error\":\"Invalid extension inventory\"}".utf8), to: .standardOutput) }
        } catch { /* stdout is reserved for complete protocol frames. */ }
    }
}
