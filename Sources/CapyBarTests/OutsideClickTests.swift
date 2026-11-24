import CapyBarCore
import CoreGraphics
import Foundation

@MainActor
final class FakeClickSource: ClickSource {
    private final class Token {}
    private var handler: (@MainActor (CGPoint) -> Void)?
    private var token: Token?
    private(set) var starts = 0
    private(set) var stops = 0

    var isActive: Bool { token != nil }

    func startWatching(_ handler: @escaping @MainActor (CGPoint) -> Void) -> AnyObject {
        starts += 1
        self.handler = handler
        let token = Token()
        self.token = token
        return token
    }

    func stopWatching(_ token: AnyObject) {
        guard token === self.token else { return }
        stops += 1
        self.token = nil
        handler = nil
    }

    func click(at point: CGPoint) { handler?(point) }
}

@MainActor
func outsideClickTests() {
    let panel = CGRect(x: 1000, y: 600, width: 300, height: 200)
    let icon = CGRect(x: 1100, y: 870, width: 30, height: 24)
    let insidePanel = CGPoint(x: 1150, y: 700)
    let onIcon = CGPoint(x: 1110, y: 880)
    let elsewhere = CGPoint(x: 200, y: 300)

    func make() -> (FakeClickSource, OutsideClickWatcher, () -> Int) {
        let source = FakeClickSource()
        var closes = 0
        let watcher = OutsideClickWatcher(
            source: source, insideFrames: { [panel, icon] }, onOutsideClick: { closes += 1 })
        return (source, watcher, { closes })
    }

    section("Panel closes on a click outside it")
    do {
        check(OutsideClickWatcher.isOutside(elsewhere, of: [panel, icon]), "point away from panel and icon is outside")
        check(!OutsideClickWatcher.isOutside(insidePanel, of: [panel, icon]), "point in the panel is inside")
        check(!OutsideClickWatcher.isOutside(onIcon, of: [panel, icon]), "point on our menu bar icon is inside")
    }
    do {
        let (source, watcher, closes) = make()
        source.click(at: elsewhere)
        check(closes() == 0 && source.starts == 0, "nothing is watched before the panel opens")
        watcher.start()
        check(watcher.isWatching && source.isActive, "opening the panel starts watching clicks")
        source.click(at: elsewhere)
        check(closes() == 1, "click outside closes the panel")
        check(!watcher.isWatching && !source.isActive, "watching stops after the close")
        source.click(at: elsewhere)
        check(closes() == 1, "later clicks do not close again")
    }
    do {
        let (source, watcher, closes) = make()
        watcher.start()
        source.click(at: insidePanel)
        check(closes() == 0 && watcher.isWatching, "click inside the panel keeps it open")
        source.click(at: onIcon)
        check(closes() == 0 && watcher.isWatching, "click on our icon is left to the icon's own toggle")
        source.click(at: elsewhere)
        check(closes() == 1, "then a click outside still closes it")
    }
    do {
        let (source, watcher, closes) = make()
        watcher.start()
        watcher.start()
        check(source.starts == 1, "starting twice installs one monitor")
        watcher.stop()
        watcher.stop()
        check(source.stops == 1 && !source.isActive, "panel closed another way: monitor removed once")
        source.click(at: elsewhere)
        check(closes() == 0, "no close after the panel already closed")
        watcher.start()
        source.click(at: elsewhere)
        check(source.starts == 2 && closes() == 1, "reopened panel closes on an outside click again")
    }
}
