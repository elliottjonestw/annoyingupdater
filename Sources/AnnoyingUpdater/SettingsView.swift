import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var selfUpdater: SelfUpdater
    @StateObject private var browserSetup = BrowserSetupState()
    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.loginNeedsApproval {
                    LabeledContent("Approval needed") {
                        Button("Open Login Items…") { model.openLoginItemSettings() }
                    }
                }
                Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.rawValue).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Check for updates", value: "Every hour")
                LabeledContent("Snooze duration", value: "15 minutes")
            } header: { Text("General") } footer: {
                Text("When updates are available, a reminder window comes to the front. Closing the reminder snoozes it for 15 minutes.")
            }
            Section {
                Picker("App Store region", selection: Binding(get: { model.country }, set: { model.setCountry($0) })) {
                    ForEach(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }.sorted { countryName($0) < countryName($1) }, id: \.self) {
                        Text(countryName($0)).tag($0)
                    }
                }
            } header: { Text("Update Availability") } footer: {
                Text("Choose the region used by your App Store account. Catalog availability can vary by region. Changes apply to the next check.")
            }
            Section {
                Toggle("Monitor browser extensions", isOn: Binding(get: { model.browserMonitoring }, set: { model.setBrowserMonitoring($0) }))
                Button("Set Up Browser Companion…") { browserSetup.isPresented = true }
            } header: { Text("Browser Extensions") } footer: {
                Text("Optional companion for Chromium browsers and Firefox. Extension identifiers and versions are checked with Google or Mozilla; browsing data stays private. Closed profiles show their last inventory as unverified.")
            }
            Section {
                LabeledContent("Version", value: AppVersion.display)
                Toggle("Install Annoying Updater updates automatically", isOn: Binding(
                    get: { selfUpdater.automaticallyInstalls }, set: { selfUpdater.setAutomaticallyInstalls($0) }))
                Button("Check for Annoying Updater Updates…") { selfUpdater.checkForUpdates() }
                    .disabled(!selfUpdater.canCheckForUpdates)
                LabeledContent("Data", value: "Stored on this Mac")
            } header: { Text("About Annoying Updater") } footer: {
                Text("Annoying Updater checks GitHub for its own updates. Updates are verified before installation and finish when you quit, or when you choose Install and Relaunch.")
            }
            if let message = model.message, model.messageIsError {
                Section { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped).frame(width: 490, height: 560)
        .onAppear { model.refreshLoginItemStatus() }
        .sheet(isPresented: $browserSetup.isPresented) { BrowserSetupView(model: model, setup: browserSetup) }
    }
    private func countryName(_ code: String) -> String { Locale.current.localizedString(forRegionCode: code) ?? code }
}
