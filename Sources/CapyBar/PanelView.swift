import AppKit
import CapyBarCore
import SwiftUI

/// Settings open below the control bar, so the bar never moves out from under the pointer.
struct PanelView: View {
    let controller: CubbyController
    /// Opens the entry's menu, or starts its app when it is not running.
    let open: (CubbyController.PanelEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if isReady {
                if let message = controller.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                ControlBar(controller: controller)
                if controller.showsSettings {
                    Divider()
                    SettingsSection(controller: controller)
                }
            } else {
                VersionLabel().frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var isReady: Bool { controller.isRestrictionAvailable && controller.isTrusted }

    @ViewBuilder private var content: some View {
        if !controller.isRestrictionAvailable {
            Notice(
                symbol: "exclamationmark.triangle",
                title: "This version of macOS isn’t supported",
                detail: "CapyBar works on macOS 27 only."
            )
        } else if !controller.isTrusted {
            Notice(symbol: "menubar.rectangle", title: "Allow CapyBar to hide icons") {
                Button("Allow…") { controller.askForAccessibility() }
                    .buttonStyle(.borderedProminent)
            }
        } else if controller.isPaused {
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
            FlowLayout(spacing: 4) {
                ForEach(controller.panelEntries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        ItemIcon(icon: entry.icon)
                            .grayscale(entry.isRunning ? 0 : 1)
                            .opacity(entry.isRunning ? 1 : 0.5)
                            .padding(4)
                    }
                    .buttonStyle(.borderless)
                    .disabled(controller.isBusy)
                    .help(entry.isRunning ? entry.title : "\(entry.title). Click to open it.")
                    .accessibilityLabel(entry.title)
                }
            }
        }
    }
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
        Text(Self.text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
    }
}

private struct ControlBar: View {
    let controller: CubbyController

    var body: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if controller.isScanning || controller.isBusy {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 4)
            // Show All Icons is rare, so it lives in the icon's right-click menu.
            Button {
                controller.showsSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .symbolVariant(controller.showsSettings ? .fill : .none)
                    .foregroundStyle(controller.showsSettings ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(controller.showsSettings ? "Close settings" : "Settings")
            .accessibilityLabel("Settings")
            .accessibilityValue(controller.showsSettings ? "Open" : "Closed")
        }
    }

    /// Counts apps, not icons: an app with two icons in the cubby is one app.
    private var summary: String {
        guard !controller.isPaused else { return "All icons shown" }
        switch controller.hiddenAppCount {
        case 0: return "Nothing hidden"
        case 1: return "1 app hidden"
        case let count: return "\(count) apps hidden"
        }
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
