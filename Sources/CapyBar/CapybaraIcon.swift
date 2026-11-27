import AppKit
import QuartzCore

/// A capybara standing three-quarters on, drawn in code so it stays sharp at any scale.
/// `turn` swings the head from profile, looking left (0), to facing the viewer (1);
/// `blink` closes the eyes (1 = shut); `shield` adds a checked shield badge on the
/// capybara's back, cut out of it the way SF Symbols badge a glyph.
enum CapybaraIcon {
    static func image(turn: CGFloat = 0, blink: CGFloat = 0, shield: Bool = false) -> NSImage {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
        }
        let t = turn
        // The far eye, ear and nostril come into view during the second half of the turn.
        let far = smoothstep((t - 0.35) / 0.65)

        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            NSColor.black.setFill()

            let body = NSBezierPath()
            body.move(to: point(8.5, 3.4))
            body.curve(to: point(10.2, 3.7), controlPoint1: point(9.3, 3.4), controlPoint2: point(9.6, 3.5))
            body.curve(to: point(18.9, 12.2), controlPoint1: point(14.8, 4.4), controlPoint2: point(18.8, 7.4))
            body.curve(to: point(17.2, 17), controlPoint1: point(19.0, 15.0), controlPoint2: point(18.2, 16.7))
            body.line(to: point(14.4, 17))
            body.curve(to: point(13.2, 15.0), controlPoint1: point(14.3, 16.0), controlPoint2: point(13.9, 15.2))
            body.line(to: point(11.0, 14.9))
            body.line(to: point(10.6, 17))
            body.line(to: point(8.4, 17))
            body.curve(to: point(7.3, 11.8), controlPoint1: point(8.5, 15.0), controlPoint2: point(8.2, 12.9))
            body.line(to: point(7.0, 8.0))
            body.close()
            body.fill()

            let p = zip(profileHead, frontHead).map { point(mix($0.x, $1.x, t), mix($0.y, $1.y, t)) }
            let head = NSBezierPath()
            head.move(to: p[0])
            for i in stride(from: 1, to: p.count, by: 3) {
                head.curve(to: p[i + 2], controlPoint1: p[i], controlPoint2: p[i + 1])
            }
            head.close()
            head.fill()

            let ear = mix(1.15, 1.05, t)
            oval(mix(9.15, 8.7, t), mix(2.75, 2.9, t), ear, ear).fill()
            oval(mix(4.6, 2.9, far), mix(4.0, 2.9, far), 1.05 * far, 1.05 * far).fill()

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let eyeHeight = 0.65 * (1 - blink * 0.85)
            oval(mix(6.65, 7.3, t), mix(5.25, 5.8, t), 0.65, eyeHeight).fill()
            oval(mix(3.2, 4.3, far), 5.8, 0.65 * far, eyeHeight * far).fill()
            let nostril = mix(0.45, 0.42, t)
            oval(mix(2.35, 4.9, t), mix(6.85, 9.6, t), nostril, nostril).fill()
            oval(mix(5.8, 6.7, far), 9.6, 0.42 * far, 0.42 * far).fill()

            if shield {
                // A 1 pt knockout around the badge, the smallest gap that survives 1x.
                let badge = shieldPath(in: badgeRect)
                badge.lineWidth = 2
                badge.lineJoinStyle = .round
                badge.fill()
                badge.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                badge.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                let r = badgeRect
                let check = NSBezierPath()
                check.move(to: point(r.minX + 0.27 * r.width, r.minY + 0.5 * r.height))
                check.line(to: point(r.minX + 0.44 * r.width, r.minY + 0.67 * r.height))
                check.line(to: point(r.minX + 0.75 * r.width, r.minY + 0.33 * r.height))
                check.lineWidth = 1.25
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CapyBar"
        return image
    }

    /// Top-trailing, on the capybara's back and inside its 20 pt canvas, clear of the head in
    /// every pose. Half-point edges sit on the Retina pixel grid.
    private static let badgeRect = NSRect(x: 12.5, y: 2.5, width: 6.8, height: 8.5)

    /// A heater shield: a gently arched top, straight sides, and a rounded point.
    private static func shieldPath(in r: NSRect) -> NSBezierPath {
        func at(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint {
            NSPoint(x: r.minX + fx * r.width, y: r.minY + fy * r.height)
        }
        let path = NSBezierPath()
        path.move(to: at(0.5, 0))
        path.curve(to: at(1, 0.16), controlPoint1: at(0.72, 0.1), controlPoint2: at(0.8, 0.14))
        path.line(to: at(1, 0.5))
        path.curve(to: at(0.5, 1), controlPoint1: at(1, 0.78), controlPoint2: at(0.78, 0.93))
        path.curve(to: at(0, 0.5), controlPoint1: at(0.22, 0.93), controlPoint2: at(0, 0.78))
        path.line(to: at(0, 0.16))
        path.curve(to: at(0.5, 0), controlPoint1: at(0.2, 0.14), controlPoint2: at(0.28, 0.1))
        path.close()
        return path
    }

    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Head outline: a start point, then cubic segments (control, control, end). The edge
    /// from the neck down to the chest runs inside the body, so at `turn` 0 the
    /// silhouette is the original profile.
    private static let profileHead: [NSPoint] = [
        NSPoint(x: 1.3, y: 7.6),
        NSPoint(x: 1.3, y: 5.0), NSPoint(x: 3.6, y: 3.1), NSPoint(x: 6.4, y: 3.0),
        NSPoint(x: 7.8, y: 2.95), NSPoint(x: 9.0, y: 3.2), NSPoint(x: 10.2, y: 3.7),
        NSPoint(x: 10.2, y: 7.0), NSPoint(x: 8.4, y: 10.5), NSPoint(x: 7.3, y: 11.8),
        NSPoint(x: 6.3, y: 10.9), NSPoint(x: 5.0, y: 10.7), NSPoint(x: 3.8, y: 10.4),
        NSPoint(x: 2.3, y: 10.0), NSPoint(x: 1.3, y: 9.2), NSPoint(x: 1.3, y: 7.6),
    ]

    private static let frontHead: [NSPoint] = [
        NSPoint(x: 2.4, y: 7.0),
        NSPoint(x: 2.4, y: 4.2), NSPoint(x: 3.8, y: 2.6), NSPoint(x: 5.8, y: 2.6),
        NSPoint(x: 7.8, y: 2.6), NSPoint(x: 9.2, y: 4.2), NSPoint(x: 9.2, y: 7.0),
        NSPoint(x: 9.2, y: 9.0), NSPoint(x: 8.9, y: 11.3), NSPoint(x: 7.4, y: 11.7),
        NSPoint(x: 6.6, y: 11.8), NSPoint(x: 4.8, y: 11.5), NSPoint(x: 3.6, y: 11.2),
        NSPoint(x: 2.6, y: 11.0), NSPoint(x: 2.4, y: 9.0), NSPoint(x: 2.4, y: 7.0),
    ]
}

/// Turns the capybara on a status bar button to face the viewer and blinks once, or
/// turns it back. Redraws the button only while an animation runs.
@MainActor
final class CapybaraIconAnimator {
    private static let turnDuration: CFTimeInterval = 0.28
    private static let turnBackDuration: CFTimeInterval = 0.2
    private static let blinkStart: CFTimeInterval = 0.32
    private static let blinkDuration: CFTimeInterval = 0.15

    /// The shield badge, shown while a VPN is connected.
    var shield = false {
        didSet {
            // A running animation draws it on its next frame.
            guard shield != oldValue, timer == nil else { return }
            button?.image = CapybaraIcon.image(turn: turn, shield: shield)
        }
    }

    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var facing = false
    private var turn: CGFloat = 0
    private var from: CGFloat = 0
    private var start: CFTimeInterval = 0

    init(button: NSStatusBarButton) {
        self.button = button
        button.image = CapybaraIcon.image(shield: shield)
    }

    func face(_ facing: Bool) {
        guard facing != self.facing else { return }
        self.facing = facing
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stop()
            return
        }
        from = turn
        start = CACurrentMediaTime()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common keeps it running while the popover or a menu tracks events.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - start
        var blink: CGFloat = 0
        let finished: Bool
        if facing {
            turn = from + (1 - from) * Self.easeOutBack(min(elapsed / Self.turnDuration, 1))
            let b = (elapsed - Self.blinkStart) / Self.blinkDuration
            if b > 0, b < 1 { blink = sin(b * .pi) }
            finished = elapsed >= Self.blinkStart + Self.blinkDuration
        } else {
            let x = min(elapsed / Self.turnBackDuration, 1)
            turn = from * (1 - Self.easeInOut(x))
            finished = x >= 1
        }
        if finished {
            stop()
        } else {
            button?.image = CapybaraIcon.image(turn: turn, blink: blink, shield: shield)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        turn = facing ? 1 : 0
        button?.image = CapybaraIcon.image(turn: turn, shield: shield)
    }

    /// Overshoots a little and settles back, so the turn has some life.
    private static func easeOutBack(_ x: CGFloat) -> CGFloat {
        let s: CGFloat = 1.6
        let x = x - 1
        return x * x * ((s + 1) * x + s) + 1
    }

    private static func easeInOut(_ x: CGFloat) -> CGFloat {
        x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
}
