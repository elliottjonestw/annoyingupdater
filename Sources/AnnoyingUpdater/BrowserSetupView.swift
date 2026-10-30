import AppKit
import SwiftUI
import UpdaterCore
import Combine

final class BrowserSetupState: ObservableObject {
    @Published var isPresented = false
    @Published var browser: BrowserFamily = .chrome
    @Published var prepared = false
    @Published var error: String?
}

struct BrowserSetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var setup: BrowserSetupState
    private var browser: BrowserFamily { setup.browser }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Browser Companion", systemImage: "puzzlepiece.extension").font(.title2.bold())
            Text("Connect each browser profile once to check its installed extensions automatically.").foregroundStyle(.secondary)
            Picker("Browser", selection: $setup.browser) {
                ForEach(BrowserFamily.allCases, id: \.self) { Text($0.title).tag($0) }
            }.onChange(of: browser) { _, _ in setup.prepared = false; setup.error = nil }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. Prepare the local connection").font(.headline)
                    Text("The companion shares extension names, identifiers, versions, and a profile name with this app on your Mac. It cannot read your tabs, browsing history, cookies, passwords, or webpages.").font(.callout).foregroundStyle(.secondary)
                    Button(setup.prepared ? "Connection Prepared" : "Prepare Connection") {
                        do { try model.prepareBrowserCompanion(browser); setup.prepared = true; setup.error = nil }
                        catch { setup.error = error.localizedDescription }
                    }.disabled(setup.prepared)
                    Divider()
                    Text("2. Load the companion in this profile").font(.headline)
                    Text(browser == .firefox
                         ? "For testing, open about:debugging, choose This Firefox → Load Temporary Add-on, and select manifest.json in the Firefox companion folder. Firefox removes temporary add-ons when it closes."
                         : "Open the browser's Extensions page, enable Developer mode, choose Load unpacked, and select the Chromium companion folder.")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Show Companion Folder") {
                            let folder = Bundle.main.resourceURL!.appendingPathComponent("BrowserCompanion/" + (browser == .firefox ? "firefox" : "chromium"))
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                        Button("Open Browser") { model.openBrowserExtensions(browser) }
                    }
                    Text("3. Open the companion's toolbar popup. Choose the browser and give this profile a name, then check the connection.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if let error = setup.error { Text(error).foregroundStyle(.orange).font(.callout) }
            Text("Preview: the companion isn't published in browser stores yet. Permanent Firefox installation requires Mozilla signing. Safari extensions continue to be checked through their containing apps.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 550)
    }
}
