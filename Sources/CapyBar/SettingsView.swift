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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FullWidthTabs(titles: ["Apps", "Options"], selection: tabIndex)
            // Both tabs are laid out and the other one is only invisible, so the area is
            // as tall as the taller tab and switching never makes the panel jump.
            ZStack(alignment: .topLeading) {
                page(.apps) { Card { appList } }
                page(.options) { options }
            }
            HStack {
                VersionLabel()
                Spacer()
                TipsButton(hotkey: controller.hotkey)
            }
        }
        .controlSize(.small)
        .onChange(of: tab) { controller.isRecordingHotkey = false }
    }

    private func page(_ page: Tab, @ViewBuilder content: () -> some View) -> some View {
        let isShown = tab == page
        return content()
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }

    private var tabIndex: Binding<Int> {
        Binding(
            get: { tab == .apps ? 0 : 1 },
            set: { tab = $0 == 0 ? .apps : .options }
        )
    }

    /// Grouped like System Settings: what gets hidden, what the panel does, and the
    /// set-once switches last.
    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionGroup("Hiding") {
                SwitchRow(isOn: $controller.hideNewApps) {
                    Text("Hide new apps")
                }
                .help("Hide a newly installed app’s icon the first time it appears")
                CardDivider()
                SwitchRow(isOn: $controller.showsNotRunningApps) {
                    Text("Keep apps that aren’t running")
                }
                .help("Keep hidden apps that aren’t running in this panel, greyed out; click one to open it")
                CardDivider()
                SwitchRow(isOn: $controller.clockOpensNotificationCenter) {
                    Text("Clock opens Notification Center")
                }
                .help(
                    """
                    macOS ignores clicks on the clock while icons are hidden. CapyBar holds your \
                    click for a moment, then lets it through and shows hidden icons until \
                    Notification Center closes, as macOS does without CapyBar.
                    """)
            }
            OptionGroup("Panel") {
                ShortcutRow(controller: controller)
                CardDivider()
                SwitchRow(isOn: $controller.showsVPNStatus) {
                    Text("VPN status")
                }
                .help(
                    """
                    Add a shield to the capybara while a VPN is connected, and a row above the \
                    icons that opens the VPN app’s menu. CapyBar reads this from macOS; nothing is sent.
                    """)
            }
            OptionGroup("General") {
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
                    Text("Check for updates")
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

/// A "?" that lists what the keyboard and the right-click menu can do. Help lives here,
/// out of the way, instead of hints in the panel itself.
private struct TipsButton: View {
    let hotkey: KeyCombo?
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .help("Help")
        .accessibilityLabel("Help")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    if let hotkey { tip(hotkey.displayString, "Open CapyBar") }
                    tip("Type or ⌘F", "Search")
                    tip("← → ↑ ↓", "Choose an icon")
                    tip("Return", "Open its menu")
                    tip("Esc", "Close search, then CapyBar")
                    tip("Right-click", "More, like Show All Icons")
                }
                if hotkey == nil {
                    Text("Set a keyboard shortcut in Options to open CapyBar from any app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .padding(12)
            .frame(width: 260, alignment: .leading)
        }
    }

    private func tip(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(text)
        }
    }
}

/// The global shortcut, recorded in place like in System Settings: click the key box,
/// press the keys. Escape cancels, Delete removes it.
private struct ShortcutRow: View {
    let controller: CubbyController
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Keyboard shortcut")
                Spacer(minLength: 8)
                keyBox
            }
            if let problem = controller.hotkeyProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("Opens CapyBar from any app. Click the box, then press the keys.")
        .onChange(of: controller.isRecordingHotkey) { _, isRecording in
            isRecording ? startRecording() : stopRecording()
        }
        .onDisappear {
            // Settings close together with the panel, possibly before onChange runs:
            // never leave the monitor swallowing keys.
            stopRecording()
            controller.isRecordingHotkey = false
        }
    }

    private var keyBox: some View {
        HStack(spacing: 2) {
            Text(title)
                .foregroundStyle(controller.hotkey == nil || controller.isRecordingHotkey ? .secondary : .primary)
                .lineLimit(1)
            if controller.hotkey != nil, !controller.isRecordingHotkey {
                Button {
                    controller.setHotkey(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
                .accessibilityLabel("Remove shortcut")
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 64, minHeight: 18)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(controller.isRecordingHotkey ? Color.accentColor : Color.primary.opacity(0.15))
        )
        .contentShape(Rectangle())
        .onTapGesture { controller.isRecordingHotkey.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keyboard shortcut")
        .accessibilityValue(title)
        .accessibilityAddTraits(.isButton)
    }

    private var title: String {
        if controller.isRecordingHotkey { return "Press keys…" }
        return controller.hotkey?.displayString ?? "Record"
    }

    private func startRecording() {
        controller.takeKeyboard?()
        stopRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            switch event.keyCode {
            case KeyCombo.KeyCode.escape where flags.isEmpty:
                controller.isRecordingHotkey = false
            case KeyCombo.KeyCode.delete where flags.isEmpty, KeyCombo.KeyCode.forwardDelete where flags.isEmpty:
                controller.setHotkey(nil)
            default:
                // A plain letter would fire while typing anywhere: wait for a real shortcut.
                guard let combo = KeyCombo(event: event) else {
                    NSSound.beep()
                    return nil
                }
                controller.setHotkey(combo)
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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

/// A titled card of options, like a section in System Settings.
private struct OptionGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            Card { content }
        }
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
