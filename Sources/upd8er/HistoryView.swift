import AppKit
import SwiftUI
import UpdaterCore

struct HistoryView: View {
    @ObservedObject var model: AppModel
    private var filtered: [UpdateHistoryEntry] {
        model.historyEntries.filter {
            model.historySearch.isEmpty || $0.software.displayName.localizedCaseInsensitiveContains(model.historySearch)
                || $0.software.version.localizedCaseInsensitiveContains(model.historySearch)
                || $0.previousVersion.localizedCaseInsensitiveContains(model.historySearch)
        }
    }
    private var days: [UpdateHistoryDay] { UpdateHistoryDay.grouped(filtered) }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 36, weight: .light)).foregroundStyle(Color.accentColor)
                    .frame(width: 62, height: 62).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text("History").font(.system(size: 25, weight: .bold))
                    Text("Changes to installed software, detected on this Mac.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)

            if let error = model.historyError {
                GroupBox {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("Try Again") { Task { await model.loadHistory() } }.disabled(model.isChecking || model.isClearingHistory)
                    }.padding(8)
                }
            }
            TextField("Search history", text: $model.historySearch).textFieldStyle(.roundedBorder).accessibilityLabel("Search history")
            if model.historyEntries.isEmpty {
                ContentUnavailableView {
                    Label(model.historyError == nil ? "No history yet" : "History unavailable", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(model.historyError != nil ? "Recorded changes will appear when history can be loaded." : model.historyStartedAt == nil
                         ? "The first fresh scan establishes your installed versions. Future changes will appear here automatically."
                         : "Installed version changes will appear here as they're detected, including updates made outside upd8er.")
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .padding(.vertical, 24)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: model.historySearch)
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(days) { day in
                        let entries = day.entries
                        VStack(alignment: .leading, spacing: 10) {
                            Text(dayTitle(day.id)).font(.system(size: 13, weight: .semibold)).padding(.leading, 2)
                            VStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    HistoryRow(entry: entry, model: model)
                                    if index < entries.count - 1 { Divider().padding(.leading, 70) }
                                }
                            }
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                if let since = model.historyStartedAt {
                    Text("Tracking since \(since.formatted(date: .abbreviated, time: .shortened)).")
                }
                Text("Dates show when a change was detected, rather than its exact installation time. History is stored only on this Mac.")
            }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Clear history?", isPresented: $model.showClearHistoryConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear History", role: .destructive) { Task { await model.clearHistory() } }
        } message: {
            Text("This permanently removes the recorded history and first-detected dates on this Mac. Tracking starts again from the current versions. Update checks and reminders continue.")
        }
        .task { await model.loadHistory() }
    }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

private struct HistoryRow: View {
    let entry: UpdateHistoryEntry
    @ObservedObject var model: AppModel
    private var expanded: Bool { model.expandedHistoryIDs.contains(entry.id) }
    private var iconItem: UpdateItem {
        UpdateItem(id: entry.software.id, name: entry.software.displayName,
            path: entry.software.kind == .updater ? Bundle.main.bundlePath : entry.software.path,
            installedVersion: entry.software.version, source: entry.software.kind == .macOS ? .system : .unknown, status: .current, softwareKind: entry.software.kind)
    }
    private var versionText: String {
        if entry.change == .buildChanged { return "\(entry.software.version) · Build \(entry.previousBuild) → \(entry.software.build)" }
        return "\(entry.previousVersion) → \(entry.software.version)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AppIconView(item: iconItem)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.software.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(versionText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(entry.change.title).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.change == .downgraded ? Color.orange : .secondary)
                    Text("Detected \(entry.detectedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if expanded { model.expandedHistoryIDs.remove(entry.id) } else { model.expandedHistoryIDs.insert(entry.id) }
                    }
                } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Show history details for \(entry.software.displayName)")
                .accessibilityLabel("History details for \(entry.software.displayName)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }.padding(.horizontal, 16).padding(.vertical, 15)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let request = ReleaseNotesRequest(history: entry), model.hasReleaseNotes(request) {
                        Button("What's New in This Update") { model.releaseNotesRequest = request }
                    }
                    LabeledContent("Previous version", value: version(entry.previousVersion, build: entry.previousBuild))
                    LabeledContent("Observed version", value: version(entry.software.version, build: entry.software.build))
                    if let first = entry.firstDetectedAvailableAt {
                        LabeledContent("Update first detected", value: first.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Previously observed", value: entry.previouslyObservedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Change detected", value: entry.detectedAt.formatted(date: .abbreviated, time: .shortened))
                    if let path = entry.software.path { Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                    Text("The installed version changed between these observations. The exact installation time isn't known.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12)).textSelection(.enabled)
                .padding(.leading, 70).padding(.trailing, 16).padding(.bottom, 16)
            }
        }
        .task(id: entry.id + String(expanded)) {
            if expanded, let request = ReleaseNotesRequest(history: entry) { await model.prepareReleaseNotes(request) }
        }
    }
    private func version(_ version: String, build: String) -> String {
        build.isEmpty || build == version ? version : "\(version) (\(build))"
    }
}
