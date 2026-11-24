import AppKit
import CapyBarCore
import SwiftUI

struct SettingsSection: View {
    @Bindable var controller: CubbyController
    /// Resets to Apps each time settings open: that is what people come here for.
    @State private var tab = Tab.apps

    private enum Tab: Hashable { case apps, options }

    private static let rowHeight: CGFloat = 28
    private static let maxListHeight: CGFloat = 240
    /// Rough height of the Options card; the taller tab sets the area's height, so
    /// switching tabs does not make the panel jump.
    private static let optionsHeight: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FullWidthTabs(titles: ["Apps", "Options"], selection: tabIndex)
            Group {
                switch tab {
                case .apps: Card { appList }
                case .options: options
                }
            }
            .frame(minHeight: tabHeight, alignment: .top)
            HStack {
                VersionLabel()
                Spacer()
                // Quit and Uninstall live in the icon's right-click menu.
                Text("Right-click the icon for more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .controlSize(.small)
    }

    private var tabIndex: Binding<Int> {
        Binding(
            get: { tab == .apps ? 0 : 1 },
            set: { tab = $0 == 0 ? .apps : .options }
        )
    }

    private var tabHeight: CGFloat {
        let list =
            controller.appEntries.isEmpty
            ? Self.rowHeight
            : min(CGFloat(controller.appEntries.count) * Self.rowHeight, Self.maxListHeight)
        return max(list + 8, Self.optionsHeight)
    }

    private var options: some View {
        Card {
            SwitchRow(isOn: $controller.showsNotRunningApps) {
                Text("Show apps that aren’t running")
            }
            .help("Keep hidden apps that aren’t running in this panel, greyed out; click one to open it")
            CardDivider()
            SwitchRow(isOn: $controller.hideNewApps) {
                Text("Hide new apps automatically")
            }
            .help("Hide a newly installed app’s icon the first time it appears")
            CardDivider()
            SwitchRow(isOn: openAtLogin) {
                Text("Open at login")
            }
            .disabled(!controller.canHide)
            .help(
                controller.canHide
                    ? "Start CapyBar when you log in, so hidden icons stay hidden after a restart"
                    : "Available once CapyBar is in the Applications folder")
            CardDivider()
            SwitchRow(isOn: checksForUpdates) {
                Text("Check for updates automatically")
            }
            .help(
                """
                Once a day, download a small file from GitHub with the newest version number. \
                Nothing about you or your apps is sent.
                """)
            if controller.loginItemNeedsApproval {
                HStack(spacing: 4) {
                    Text("Allow CapyBar in Login Items to finish.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings…") { LoginItem.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .padding(.vertical, 4)
            }
        }
    }

    private var openAtLogin: Binding<Bool> {
        Binding(
            get: { controller.opensAtLogin },
            set: { controller.setOpensAtLogin($0) }
        )
    }

    private var checksForUpdates: Binding<Bool> {
        Binding(
            get: { Updater.shared.checksAutomatically },
            set: { Updater.shared.checksAutomatically = $0 }
        )
    }

    @ViewBuilder private var appList: some View {
        if controller.appEntries.isEmpty {
            Text(controller.isScanning ? "Looking for icons…" : "No other icons in the menu bar.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            // A List, not a ScrollView: only List gives native drag-to-reorder on macOS.
            // It does not size to its content, so its height is set from the row count.
            List {
                ForEach(controller.appEntries) { entry in
                    AppRow(entry: entry, isHidden: hiddenBinding(for: entry.bundleID))
                }
                .onMove(perform: controller.moveApps)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: min(CGFloat(controller.appEntries.count) * Self.rowHeight, Self.maxListHeight))
        }
    }

    private func hiddenBinding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { controller.hidden.contains(bundleID) },
            set: { controller.setHidden($0, for: bundleID) }
        )
    }
}

private struct AppRow: View {
    let entry: CubbyController.AppEntry
    @Binding var isHidden: Bool

    var body: some View {
        SwitchRow(isOn: $isHidden) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
            Group {
                if let icon = entry.icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .grayscale(entry.isRunning ? 0 : 1)
            .opacity(entry.isRunning ? 1 : 0.5)
            Text(entry.name)
                .lineLimit(1)
                .foregroundStyle(entry.isRunning ? .primary : .secondary)
            if !entry.isRunning {
                Text("Not running")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .help(help)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    private var help: String {
        guard entry.isRunning else {
            return "Not running. Its icon stays hidden next time it starts; turn off to forget it."
        }
        return isHidden ? "Hidden in CapyBar" : "Shown in the menu bar"
    }
}

/// A segmented control whose segments share the full width. SwiftUI's segmented
/// Picker on macOS keeps its intrinsic width however much room it gets.
private struct FullWidthTabs: NSViewRepresentable {
    let titles: [String]
    @Binding var selection: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: titles, trackingMode: .selectOne, target: context.coordinator,
            action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.controlSize = .small
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        if control.selectedSegment != selection { control.selectedSegment = selection }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func changed(_ sender: NSSegmentedControl) { selection.wrappedValue = sender.selectedSegment }
    }
}

/// A rounded box like the grouped forms in System Settings.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Hairline between rows of one card.
private struct CardDivider: View {
    var body: some View {
        Divider().padding(.vertical, 5)
    }
}

/// Label on the left, switch pinned to the right edge, so every switch lines up.
private struct SwitchRow<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Label

    var body: some View {
        HStack(spacing: 8) {
            label
            Spacer(minLength: 8)
            // The section's controlSize does not reach a switch, and a full-size one is
            // taller than the 20 pt app icon beside it.
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
    }
}
