import AppKit
import SwiftUI
import Combine
import UpdaterCore

@MainActor
final class ReleaseNotesState: ObservableObject {
    @Published var entries: [ReleaseNote] = []
    @Published var result: ReleaseNotesResult?
    @Published var loading = false
    @Published var error: String?
    @Published var latestOnly = false
    @Published var oldestFirst = false
    func load(_ request: ReleaseNotesRequest, more: Bool = false, demo: Bool = false) async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        if demo {
            entries = [ReleaseNote(version: request.targetVersion, date: Date(), text: "Sample release notes\n\n• Improvements and bug fixes in the selected update.\n• A clearer experience on your Mac."),
                       ReleaseNote(version: "7.67.1", date: Date().addingTimeInterval(-86400), text: "Sample intermediate release\n\n• Reliability improvements between the installed and target versions.")]
                .filter { NotesVersions.includes($0.version, after: request.installedVersion, through: request.targetVersion) }
            result = ReleaseNotesResult(entries: entries, message: "Preview only. These are sample notes, not the publisher's actual changelog.", sourceName: "Preview")
            return
        }
        do {
            let next = try await ReleaseNotesService.load(request, source: more ? result?.source : nil, page: more ? (result?.nextPage ?? 1) : 1)
            guard !Task.isCancelled else { return }
            entries = NotesVersions.sorted((more ? entries : []) + next.entries)
            result = next
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
struct ReleaseNotesView: View {
    let request: ReleaseNotesRequest
    var demo = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = ReleaseNotesState()
    private var displayed: [ReleaseNote] {
        let entries = state.latestOnly ? state.entries.filter { NotesVersions.isTarget($0, for: request) } : state.entries
        return state.oldestFirst ? Array(entries.reversed()) : entries
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: "doc.text").font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("What's New").font(.title2.bold())
                        Text(request.name).font(.headline)
                        Text("\(version(request.installedVersion, build: request.context.installedBuild)) → \(version(request.targetVersion, build: request.context.targetBuild))")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                }
                HStack {
                    Picker("Release range", selection: $state.latestOnly) {
                        Text("Since Your Version").tag(false)
                        Text("Latest Release Only").tag(true)
                    }.pickerStyle(.segmented)
                    Picker("Order", selection: $state.oldestFirst) {
                        Text("Newest First").tag(false); Text("Oldest First").tag(true)
                    }.labelsHidden().frame(width: 128).disabled(state.latestOnly)
                }
            }.padding(22)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let result = state.result {
                        Label(result.message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text("\(displayed.count) release\(displayed.count == 1 ? "" : "s") · \(result.sourceName)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let url = result.sourceURL, PublicURL.isAllowed(url) {
                                Link(sourceTitle(result), destination: url).font(.caption)
                            }
                        }
                    }
                    if let error = state.error {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Couldn't load release notes", systemImage: "exclamationmark.circle").font(.headline)
                            Text(error).foregroundStyle(.secondary)
                            Button("Try Again") { Task { await state.load(request, more: state.result != nil, demo: demo) } }.disabled(state.loading)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !state.loading && displayed.isEmpty && state.error == nil {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No notes available for this version range").font(.headline)
                            Text("The publisher may provide notes on its website or inside the app.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 35)
                    }
                    ForEach(displayed) { entry in
                        ReleaseNoteCard(entry: entry, sharedURL: state.result?.source?.kind == .sparkle && (entry.url.map { url in !entry.allowsLinkedContent || state.entries.filter { $0.url == url }.count > 1 } ?? false))
                    }
                    if state.loading { HStack { Spacer(); ProgressView("Loading release notes…"); Spacer() }.padding(24) }
                    if state.result?.nextPage != nil {
                        Button("Load Older Releases") { Task { await state.load(request, more: true, demo: demo) } }.disabled(state.loading)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Publisher's notes. Some releases may have no published notes.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 680, height: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.openURL, OpenURLAction { url in PublicURL.isAllowed(url) ? .systemAction : .discarded })
            .task(id: request.id) { await state.load(request, demo: demo) }
    }
    private func sourceTitle(_ result: ReleaseNotesResult) -> String {
        switch result.source?.kind {
        case .website: return "Visit Publisher Website"
        case .appStore: return "Open App Store Page"
        case .electron: return "View Update Feed"
        case .github: return "Open Release History"
        case .sparkle where result.sourceURL == result.source?.url: return "View Update Feed"
        default: return "Open Publisher's History"
        }
    }
    private func version(_ version: String, build: String?) -> String {
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }
}
@MainActor
private final class LinkedNoteState: ObservableObject {
    @Published var text = ""
    @Published var loading = false
    @Published var error: String?
    func load(_ url: URL, version: String) async {
        guard !loading, text.isEmpty else { return }; loading = true; error = nil
        defer { loading = false }
        do { let body = try await ReleaseNotesService.linkedContent(url, expectedVersion: version); if !Task.isCancelled { text = body } }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
private struct ReleaseNoteCard: View {
    let entry: ReleaseNote
    let sharedURL: Bool
    @StateObject private var state = LinkedNoteState()
    private var bodyText: String { entry.text.isEmpty ? state.text : entry.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Version \(entry.version)").font(.headline)
                if let build = entry.build, build != entry.version { Text("Build \(build)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let date = entry.date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
            }
            if !bodyText.isEmpty {
                NotesMarkdownView(text: bodyText)
            } else if state.loading { ProgressView().controlSize(.small) }
            else if state.error != nil {
                Text("The linked notes couldn't be loaded.").foregroundStyle(.secondary)
                if let url = entry.url { Button("Try Again") { Task { await state.load(url, version: entry.version) } } }
            } else { Text(sharedURL ? "The publisher uses a shared changelog page for several versions. Open it to read the original history." : "The publisher didn't include any release-note text for this version.").foregroundStyle(.secondary).font(.callout) }
            if let url = entry.url, PublicURL.isAllowed(url) { Link("Open Original Notes", destination: url).font(.caption) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .task(id: entry.id) {
                if entry.text.isEmpty, entry.allowsLinkedContent, !sharedURL, let url = entry.url, PublicURL.isAllowed(url), url.pathExtension.lowercased() != "xml" { await state.load(url, version: entry.version) }
            }
    }
}

private struct NotesMarkdownView: View {
    let text: String
    private var blocks: [String] { String(text.prefix(40_000)).components(separatedBy: "\n\n") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.prefix(300).enumerated()), id: \.offset) { _, paragraph in
                let heading = paragraph.range(of: #"^#{1,6} +"#, options: .regularExpression)
                let code = paragraph.hasPrefix("```")
                let stripped = heading.map { String(paragraph[$0.upperBound...]) } ?? paragraph
                let body = stripped.replacingOccurrences(of: #"(?m)^[-*] +"#, with: "• ", options: .regularExpression)
                if code {
                    Text(body.components(separatedBy: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                } else {
                    Text((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body))
                        .font(.system(size: 13, weight: heading == nil ? .regular : .semibold)).textSelection(.enabled)
                }
            }
            if text.count > 40_000 || blocks.count > 300 {
                Text("Notes shortened for display. Open the original for the full text.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
