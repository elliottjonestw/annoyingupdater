import AppKit
import SwiftUI
import UpdaterCore

enum SidebarPage: String, CaseIterable, Identifiable {
    case updates = "Updates", history = "History", sources = "Update Sources"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .updates: return "arrow.down.circle"; case .history: return "clock.arrow.circlepath"; case .sources: return "network" }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    Section("Library") {
                        Label("Updates", systemImage: SidebarPage.updates.symbol).badge(model.updates.count).tag(SidebarPage.updates)
                        Label("History", systemImage: SidebarPage.history.symbol).tag(SidebarPage.history)
                    }
                    Section("Monitoring") {
                        Label("Update Sources", systemImage: SidebarPage.sources.symbol).tag(SidebarPage.sources)
                    }
                }
                .listStyle(.sidebar)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Button(action: openSettings) { Label("Settings…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Text("Annoying Updater \(AppVersion.display)").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(16)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if model.isDemo {
                    HStack(spacing: 7) {
                        Image(systemName: "eye")
                        Text("Preview").fontWeight(.medium)
                        Text("Sample updates and history. Your apps won't be changed.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Show Reminder") { model.presentReminder?() }.buttonStyle(.link)
                    }
                    .font(.system(size: 11)).padding(.horizontal, 24).padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.06))
                    Divider()
                }
                if let message = model.message {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: model.messageIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(model.messageIsError ? Color.orange : .accentColor)
                        Text(message).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss message")
                    }.padding(14).background(Color(nsColor: .controlBackgroundColor))
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch model.selection ?? .updates {
                        case .updates: updatesPage
                        case .history: HistoryView(model: model)
                        case .sources: sourcesPage
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                Divider()
                HStack(spacing: 6) {
                    if model.isLoadingResults { ProgressView().controlSize(.mini); Text("Checking for updates…") }
                    else if let date = model.lastCheck { Image(systemName: "clock"); Text("Last checked \(date.formatted(.relative(presentation: .named)))") }
                    else { Text("Ready to check for updates") }
                    Spacer()
                    if model.installingID != nil { ProgressView().controlSize(.mini); Text("Installing update…") }
                    else if !model.isLoadingResults { Text("\(model.checkedCount) checked · \(model.unsupported.count + model.unverified.count) could not be checked or verified") }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 11)
                .background(.bar)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle((model.selection ?? .updates).rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if model.selection == .history {
                        Button { model.showClearHistoryConfirmation = true } label: { Label("Clear History…", systemImage: "trash") }
                            .help("Clear locally stored update history")
                            .disabled(model.historyStartedAt == nil || model.historyError != nil || model.isChecking || model.isClearingHistory)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.snooze() } label: { Label("Snooze", systemImage: "clock.badge") }
                        .help("Snooze reminders for 15 minutes").disabled(model.updates.isEmpty || model.isSnoozed)
                    Button { Task { await model.check() } } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
                        .help("Check for updates now").disabled(model.isChecking || model.installingID != nil)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .frame(minWidth: 790, minHeight: 540)
        .sheet(item: $model.releaseNotesRequest) { ReleaseNotesView(request: $0, demo: model.isDemo) }
    }

    private var updatesPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: model.isLoadingResults ? "arrow.triangle.2.circlepath" : model.updates.isEmpty ? (model.unverified.isEmpty && model.unsupported.isEmpty ? "checkmark.circle" : "arrow.triangle.2.circlepath") : "arrow.down.circle")
                    .font(.system(size: 39, weight: .light)).foregroundStyle(Color.accentColor)
                    .frame(width: 62, height: 62).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text(headline).font(.system(size: 25, weight: .bold))
                    Text(model.isLoadingResults ? "We're checking your Mac and your apps." : model.updates.isEmpty ? "We'll keep an eye on your Mac and your apps." : "Keep your Mac and your apps up to date.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 4)

            if model.isSnoozed {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reminders snoozed").font(.system(size: 12, weight: .semibold))
                        if let until = model.policy.snoozedUntil { Text("Your next reminder will be after \(until.formatted(date: .omitted, time: .shortened)).").font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text("15 min").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }

            if !model.finderSelectedPaths.isEmpty {
                HStack {
                    Label("Apps selected in Finder", systemImage: "folder")
                    Spacer()
                    Button("Show All") { model.finderSelectedPaths = [] }
                }.font(.callout).foregroundStyle(.secondary)
                if !model.isLoadingResults && !model.items.contains(where: { model.finderSelectedPaths.contains($0.path ?? "") }) {
                    Text("The selected apps are unavailable or couldn't be read. They will be checked again when accessible.").font(.callout).foregroundStyle(.secondary)
                }
            }
            TextField("Search software", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search software")

            let filtered = model.items.filter {
                (model.finderSelectedPaths.isEmpty || model.finderSelectedPaths.contains($0.path ?? "")) &&
                (model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search))
            }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let updates = filtered.filter { $0.status == .available }
            let uncertain = filtered.filter { $0.status == .unverified || $0.status == .unsupported }
            let current = filtered.filter { $0.status == .current }

            if !model.isLoadingResults && !model.search.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: model.search)
            }
            if !updates.isEmpty {
                let system = updates.filter { $0.source == .system }
                let apps = updates.filter { $0.source != .system && $0.kind != .commandLineTool && $0.kind != .browserExtension }
                let tools = updates.filter { $0.kind == .commandLineTool }
                let extensions = updates.filter { $0.kind == .browserExtension }
                if !system.isEmpty { itemGroup("System Software", items: system) }
                if !apps.isEmpty { itemGroup("Application Updates", items: apps) }
                if !tools.isEmpty { itemGroup("Command-Line Tools", items: tools) }
                if !extensions.isEmpty { itemGroup("Browser Extensions", items: extensions) }
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("You'll be reminded every 15 minutes until these updates are installed. Apps with their own updater will open so you can finish there.")
                        .fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
            } else if model.isLoadingResults || (model.search.isEmpty && model.updates.isEmpty) {
                VStack(spacing: 12) {
                    Image(systemName: model.isLoadingResults ? "arrow.triangle.2.circlepath" : "checkmark.shield")
                        .font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                    Text(model.isLoadingResults ? "Looking for updates" : "No confirmed updates").font(.headline)
                    Text(model.isLoadingResults ? "This can take a few minutes. You can close this window while we check."
                         : "Updates will appear here as soon as we find them.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 350)
                    if model.isLoadingResults { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity).padding(.vertical, 38)
            }
            if !model.isLoadingResults && !uncertain.isEmpty { itemGroup("Couldn't Check or Verify", items: uncertain) }
            if !current.isEmpty { itemGroup("Up to Date", items: current) }
        }
    }
    private var headline: String {
        if model.isLoadingResults { return "Checking for updates…" }
        if model.updates.isEmpty { return model.unverified.isEmpty && model.unsupported.isEmpty ? "You're up to date" : "No updates confirmed" }
        return "\(model.updates.count) update\(model.updates.count == 1 ? "" : "s") available"
    }
    private func itemGroup(_ title: String, items: [UpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    UpdateRow(item: item, model: model)
                    if index < items.count - 1 { Divider().padding(.leading, 70) }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
    private var sourcesPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Update Sources").font(.system(size: 25, weight: .bold))
                Text("Different apps deliver updates in different ways.").foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(model.reports.enumerated()), id: \.element.id) { index, report in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: report.hasError ? "exclamationmark.circle" : "network")
                                .foregroundStyle(report.hasError ? Color.orange : .secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(report.name).fontWeight(.medium)
                                Text(report.message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                        }.padding(12)
                        if index < model.reports.count - 1 { Divider().padding(.leading, 46) }
                    }
                    if model.reports.isEmpty { Text("Sources will appear after the first check.").foregroundStyle(.secondary).padding(20) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Apps are matched automatically using shared catalogs, developer feeds, and update information included in the app. Uncertain matches are marked clearly and don't trigger reminders.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AppIconView: View {
    let item: UpdateItem
    var size: CGFloat = 40
    var body: some View {
        Group {
            if item.kind == .browserExtension {
                Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.65)).foregroundStyle(.secondary).frame(width: size, height: size)
            } else if item.kind == .commandLineTool {
                Image(systemName: "terminal").font(.system(size: size * 0.65)).foregroundStyle(.secondary).frame(width: size, height: size)
            } else if item.source == .system && item.path == nil {
                Image(systemName: "laptopcomputer").font(.system(size: size * 0.65, weight: .regular))
                    .foregroundStyle(.secondary).frame(width: size, height: size)
            } else if let path = item.path, FileManager.default.fileExists(atPath: path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high).frame(width: size, height: size)
            } else {
                Image(systemName: item.name == "Pages" ? "doc.text" : "app.dashed").font(.system(size: size * 0.55))
                    .foregroundStyle(item.name == "Pages" ? Color.orange : .secondary)
                    .frame(width: size, height: size).background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.22))
            }
        }.accessibilityHidden(true)
    }
}

struct UpdateRow: View {
    let item: UpdateItem
    @ObservedObject var model: AppModel
    private var expanded: Bool { model.expandedIDs.contains(item.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AppIconView(item: item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if item.kind == .application, let path = item.installationPath ?? item.path,
                       !path.hasPrefix("/Applications/"), !path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/") {
                        Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    HStack(spacing: 5) {
                        Text(item.installedVersion)
                        if let version = item.availableVersion { Image(systemName: "arrow.right").font(.system(size: 9)); Text(version) }
                        Text("·"); Text(item.source.rawValue)
                        let request = ReleaseNotesRequest(item: item)
                        if item.availableVersion != nil && model.hasReleaseNotes(request) {
                            Button("What's New") { model.releaseNotesRequest = request }
                                .buttonStyle(.link).font(.system(size: 11)).accessibilityLabel("What's New in \(item.name)")
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if model.installingID == item.id {
                    ProgressView().controlSize(.small).padding(.horizontal, 12)
                } else if item.status == .available {
                    Button(item.action.title) { Task { await model.update(item) } }
                        .controlSize(.small).disabled(model.installingID != nil || model.isChecking)
                } else {
                    Label(item.status.title, systemImage: statusSymbol).font(.system(size: 11))
                        .foregroundStyle(item.status == .current ? Color.secondary : Color.orange)
                }
                Button { withAnimation(.easeInOut(duration: 0.16)) { if expanded { model.expandedIDs.remove(item.id) } else { model.expandedIDs.insert(item.id) } } } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Show details for \(item.name)")
                    .accessibilityLabel("Details for \(item.name)").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }.padding(.horizontal, 16).padding(.vertical, 15)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    if item.kind == .application, let path = item.installationPath ?? item.path {
                        Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            .font(.system(size: 12))
                    }
                    if let firstSeen = model.firstDetectedDate(for: item) {
                        Text("First detected \(firstSeen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if item.status != .available && item.status != .current && item.action != .none {
                        Button(item.action.title) { Task { await model.update(item) } }.font(.system(size: 12))
                    }
                    if let checked = item.checkedAt { Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.tertiary) }
                }.padding(.leading, 70).padding(.trailing, 16).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: ReleaseNotesRequest(item: item).id + String(model.lastCheck?.timeIntervalSinceReferenceDate ?? 0)) {
            if item.availableVersion != nil { await model.prepareReleaseNotes(ReleaseNotesRequest(item: item)) }
        }
    }
    private var statusSymbol: String {
        switch item.status { case .current: return "checkmark.circle"; case .available: return "arrow.down.circle"; case .unverified: return "exclamationmark.circle"; case .unsupported: return "questionmark.circle" }
    }
}
