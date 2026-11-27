import AppKit
import CapyBarCore
import SwiftUI

/// Just the icons, with the gear beside them; nothing else takes room. A search field
/// shows up above the icons only while searching, and a VPN row only while a VPN is set
/// up. Settings open below, so the gear never moves out from under the pointer. Keys are
/// handled by `StatusItemController` (an AppKit monitor) and `PanelNavigator`; this view
/// only draws their state.
struct PanelView: View {
    let controller: CubbyController
    /// Opens the entry's menu, or starts its app when it is not running.
    let open: (CubbyController.PanelEntry) -> Void
    /// Opens the VPN app's menu.
    let openVPN: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isReady {
                if let vpn = controller.vpn {
                    VPNRow(vpn: vpn, canOpen: controller.canOpenVPNApp, open: openVPN)
                        .disabled(controller.isBusy)
                }
                if isSearchFieldShown {
                    SearchField(controller: controller)
                }
                HStack(alignment: .top, spacing: CubbyController.gearSpacing) {
                    readyContent.frame(maxWidth: .infinity, alignment: .leading)
                    GearButton(controller: controller)
                }
                // What holds right now first, then the latest news (gone once the panel closes).
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if controller.canMoveToApplications {
                    Button("Move to Applications") { controller.moveToApplications() }
                        .controlSize(.small)
                        .help("Move CapyBar into the Applications folder and open it again from there")
                }
                if controller.showsSettings {
                    Divider()
                    SettingsSection(controller: controller)
                }
            } else {
                notReadyContent
                VersionLabel().frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var isReady: Bool { controller.isReady }

    private var lines: [String] {
        let problems = [controller.installMessage, controller.hidingProblem].compactMap { $0 }
        return problems + controller.notes.lines.filter { !problems.contains($0) }
    }

    private var isSearchFieldShown: Bool {
        !controller.isPaused && !controller.panelEntries.isEmpty && controller.navigator.isSearchFieldOpen
    }

    @ViewBuilder private var notReadyContent: some View {
        if !controller.isRestrictionAvailable {
            Notice(
                symbol: "exclamationmark.triangle",
                title: "This version of macOS isn’t supported",
                detail: "CapyBar works on macOS 27 only."
            )
        } else {
            Notice(symbol: "menubar.rectangle", title: "Allow CapyBar to hide icons") {
                Button("Allow…") { controller.askForAccessibility() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var readyContent: some View {
        if controller.isPaused {
            // The way back sits right here; the way in is a secondary switch in settings.
            VStack(alignment: .leading, spacing: 6) {
                Text("All icons are back in the menu bar until you hide them again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Hide Again") { controller.isPaused = false }
                    .controlSize(.small)
                    .help("Hide the icons in CapyBar again")
            }
        } else if controller.panelEntries.isEmpty {
            EmptyCubby(controller: controller)
        } else {
            IconGrid(controller: controller, open: open)
        }
    }
}

/// Settings, beside the icons. A small spinner sits under it while an icon opens.
private struct GearButton: View {
    let controller: CubbyController

    var body: some View {
        VStack(spacing: 4) {
            Button {
                controller.showsSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .symbolVariant(controller.showsSettings ? .fill : .none)
                    .foregroundStyle(controller.showsSettings ? Color.accentColor : .secondary)
                    .frame(width: CubbyController.gearWidth, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help(controller.showsSettings ? "Close settings" : "Settings")
            .accessibilityLabel("Settings")
            .accessibilityValue(controller.showsSettings ? "Open" : "Closed")
            // Not for scanning: every open rescans, and a spinner that comes and goes
            // with it would stretch a one-row panel for a moment. An empty cubby says
            // "Looking for icons…" instead.
            if controller.isBusy {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

/// The hidden icons. The keyboard selection is drawn while the keyboard is in use.
private struct IconGrid: View {
    let controller: CubbyController
    let open: (CubbyController.PanelEntry) -> Void

    var body: some View {
        let entries = controller.visibleEntries
        if entries.isEmpty {
            Text("No matching icons")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32)
        } else {
            FlowLayout(spacing: 4) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                    Button {
                        open(entry)
                    } label: {
                        ItemIcon(icon: entry.icon)
                            .grayscale(entry.isRunning ? 0 : 1)
                            .opacity(entry.isRunning ? 1 : 0.5)
                            .padding(4)
                            .background(
                                Color.accentColor.opacity(controller.navigator.selection == position ? 0.3 : 0),
                                in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .disabled(controller.isBusy)
                    .help(entry.isRunning ? entry.title : "\(entry.title). Click to open it.")
                    .accessibilityLabel(entry.title)
                }
            }
        }
    }
}

/// Whether a VPN is on, and a click away from the VPN app's menu, so its own icon can
/// stay in the cubby.
private struct VPNRow: View {
    let vpn: VPNStatus
    let canOpen: Bool
    let open: () -> Void

    var body: some View {
        // A VPN built into macOS has no app to open: then it is only a label.
        if canOpen {
            Button(action: open) { row }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Open the menu of \(vpn.name)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(vpn.name), \(state)")
                .accessibilityAddTraits(.isButton)
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(vpn.name), \(state)")
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Image(systemName: vpn.isConnected ? "checkmark.shield.fill" : "shield.slash")
                .foregroundStyle(vpn.isConnected ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(vpn.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(state)
                .foregroundStyle(.secondary)
            if canOpen {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var state: String { vpn.isConnected ? "Connected" : "Not connected" }
}

/// With nothing chosen yet, the next step is right here instead of behind the gear.
private struct EmptyCubby: View {
    let controller: CubbyController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !controller.isScanning, controller.hidden.isEmpty, !controller.showsSettings {
                Button("Choose Apps to Hide…") { controller.showsSettings = true }
                    .controlSize(.small)
            }
        }
    }

    private var text: String {
        if controller.isScanning { return "Looking for icons…" }
        if !controller.hidden.isEmpty { return "None of the hidden apps are running right now." }
        return controller.showsSettings
            ? "Nothing hidden yet. Turn on the apps you want to tuck away."
            : "Nothing hidden yet."
    }
}

struct VersionLabel: View {
    static let text = "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"

    var body: some View {
        HStack(spacing: 6) {
            Text(Self.text)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if let update = Updater.shared.available {
                Button("Update to \(update.version)") { Updater.shared.openDownloadPage() }
                    .buttonStyle(.link)
                    .help("Open the download page on GitHub")
            }
        }
        .font(.caption2)
    }
}

/// Shown only while searching. It only displays the query: typing reaches the panel
/// through the key monitor, so nothing depends on which view has the focus, and every
/// arrow key keeps moving through the icons.
private struct SearchField: View {
    let controller: CubbyController

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if controller.navigator.query.isEmpty {
                    Text("Search").foregroundStyle(.tertiary)
                } else {
                    Text(controller.navigator.query).foregroundStyle(.primary)
                }
            }
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                controller.closeSearch()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Close search (Esc)")
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
        .accessibilityValue(controller.navigator.query)
    }
}

private struct Notice<Action: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            // A long title would otherwise wrap left-aligned under the centred icon.
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

extension Notice where Action == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(subviews, width: bounds.width).origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(
        _ subviews: Subviews,
        width: CGFloat
    ) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, widest, y + rowHeight)
    }
}

/// The app's icon stands in for its menu bar icon: macOS 27 gives no way to get the
/// real one without recording the screen.
private struct ItemIcon: View {
    let icon: NSImage?

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }
}
