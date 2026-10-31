import SwiftUI
import UpdaterCore

struct ReminderView: View {
    @ObservedObject var model: AppModel
    let openDashboard: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 54, weight: .regular)).symbolRenderingMode(.hierarchical).foregroundStyle(Color.accentColor)
                VStack(spacing: 7) {
                    Text("Time for an update").font(.system(size: 22, weight: .bold))
                    Text("\(model.updates.count) update\(model.updates.count == 1 ? " is" : "s are") available for your Mac.\nChoose an update to get started.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isDemo { Text("PREVIEW · SAMPLE UPDATES").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary) }
            }.padding(.top, 30).padding(.bottom, 25)
            VStack(spacing: 0) {
                ForEach(Array(model.updates.prefix(3).enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 12) {
                        AppIconView(item: item, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.system(size: 12, weight: .semibold))
                            Text(item.availableVersion.map { "Version \($0)" } ?? "New version available").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.down.circle").foregroundStyle(.tertiary)
                    }.padding(.horizontal, 14).padding(.vertical, 12)
                    if index < min(model.updates.count, 3) - 1 { Divider().padding(.leading, 56) }
                }
                if model.updates.count > 3 {
                    Divider()
                    Text("And \(model.updates.count - 3) more…").font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.07)))
            .padding(.horizontal, 28)
            VStack(spacing: 10) {
                Button(action: openDashboard) { Text("Update…").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                Button { model.snooze() } label: { Text("Snooze for \(model.snoozeDuration.label)").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).keyboardShortcut(.cancelAction)
                Text("We'll remind you again if updates are still available.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5)
            }.padding(28)
        }.frame(width: 400)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
