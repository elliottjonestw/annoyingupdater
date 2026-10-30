import AppKit
import UpdaterCore

@MainActor
final class FinderService: NSObject {
    var check: (([String]) -> Void)?
    @objc func checkApplications(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let paths = ApplicationSelection.paths(from: urls)
        guard !paths.isEmpty else {
            error.pointee = "Select a standalone application to check. Embedded helpers, system components, and development build folders are not monitored."
            return
        }
        // Return immediately; a network scan must not block Finder's service call.
        check?(paths)
    }
}
