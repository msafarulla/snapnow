import AppKit

/// A short notice near the bottom of the screen that fades on its own. It can carry a preview of
/// copied text (`detail`); it stays while the mouse is over it and never takes focus.
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", detail: String? = nil, footnote: String? = nil) {
        panel?.orderOut(nil)
        hideWork?.cancel()

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.accent
        let title = NSTextField(labelWithString: message)
        title.font = Theme.font(13, bold: detail != nil)
        title.textColor = Theme.text
        let header = NSStackView(views: [icon, title])
        header.spacing = 8

        let stack = NSStackView(views: [header])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 11, right: 16)
        if let detail {
            // The copied text itself: up to three lines, monospaced so codes and commands read clearly
            let lines = detail.split(separator: "\n", omittingEmptySubsequences: false)
            var preview = lines.prefix(3).joined(separator: "\n")
            if lines.count > 3 { preview += "\n…" }
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let body = NSTextField(wrappingLabelWithString: preview)
            body.font = font
            body.textColor = Theme.dimText
            body.maximumNumberOfLines = 4
            body.lineBreakMode = .byTruncatingTail
            // Size to the text (up to 560 pt) so the right edge keeps its padding
            let widest = preview.split(separator: "\n").map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let width = min(ceil(widest) + 14, 560)
            body.preferredMaxLayoutWidth = width
            body.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(body)
        }
        if let footnote {
            let note = NSTextField(labelWithString: footnote)
            note.font = Theme.font(11)
            note.textColor = Theme.muted
            stack.addArrangedSubview(note)
        }

        let background = HoverView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderColor = Theme.border.cgColor
        background.layer?.borderWidth = 1
        if Theme.isGlass {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(blur)
            NSLayoutConstraint.activate([
                blur.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                blur.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                blur.topAnchor.constraint(equalTo: background.topAnchor),
                blur.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            ])
        } else {
            background.layer?.backgroundColor = Theme.raised.withAlphaComponent(0.97).cgColor
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let size = stack.fittingSize
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let p = NSPanel(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = detail == nil   // text previews can be hovered to keep them up
        p.appearance = Theme.appearance
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = background
        p.orderFrontRegardless()
        panel = p

        let duration: TimeInterval = detail == nil ? 1.8 : 4.5
        background.onHover = { inside in
            hideWork?.cancel()
            if !inside { scheduleHide(p, after: 1.5) }
        }
        scheduleHide(p, after: duration)
    }

    private static func scheduleHide(_ p: NSPanel, after seconds: TimeInterval) {
        let work = DispatchWorkItem {
            guard panel === p else { return }
            p.orderOut(nil)
            panel = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Reports the mouse entering and leaving, so a toast can stay up while you read it.
private final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The delay timer's countdown, big in the middle of the picked area (or of the screen with the mouse): you can
/// see how long is left while you open a menu or hover something. Click-through, and kept out of captures.
enum CountdownHUD {
    private static var panel: NSPanel?
    private static var number: NSTextField?

    static func show(_ seconds: Int, centeredOn area: CGRect? = nil) {
        if panel == nil { build(area) }
        guard let panel, let number else { return }
        number.stringValue = "\(seconds)"
        panel.orderFrontRegardless()
        // A small pop on each tick
        guard let layer = panel.contentView?.layer else { return }
        let pop = CABasicAnimation(keyPath: "opacity")
        pop.fromValue = 0.55
        pop.toValue = 1
        pop.duration = 0.25
        layer.add(pop, forKey: "tick")
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
        number = nil
    }

    private static func build(_ area: CGRect?) {
        let side: CGFloat = 150
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 84, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        let caption = NSTextField(labelWithString: "Capturing in")
        caption.font = Theme.font(12)
        caption.textColor = NSColor.white.withAlphaComponent(0.75)
        caption.alignment = .center
        let stack = NSStackView(views: [caption, label])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 28
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        let mouse = NSEvent.mouseLocation
        let centre = area ?? (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]).frame
        let p = NSPanel(contentRect: NSRect(x: centre.midX - side / 2, y: centre.midY - side / 2, width: side, height: side),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu // above a menu opened during the countdown
        p.ignoresMouseEvents = true
        p.sharingType = .none // never in a screenshot or recording
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = background
        panel = p
        number = label
    }
}


/// Option+click anywhere on screen pops the pointing hand at the click: it scales in, swings 45 degrees about
/// its fingertip, holds about three seconds, then fades. Same picture and timing as the Option+click hand in
/// the WMOS automation (daily.py). The global mouse monitor needs no extra permission; clicks inside
/// SnapNow's own windows are not shown. Menu toggle "Option+Click Hand" (default on).
final class AltClickHand {
    static let shared = AltClickHand()
    private var monitor: Any?
    private let size = CGSize(width: 90, height: 71.79)      // points, as in the WMOS script
    private let tip = CGPoint(x: 2.68, y: 24.64)             // fingertip, measured from the picture's top-left
    private let reach: CGFloat = 150                          // overlay window is (2 x reach) square: room for the swing

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard UserDefaults.standard.bool(forKey: Prefs.altClickHand), event.modifierFlags.contains(.option) else { return }
            self?.show(at: NSEvent.mouseLocation)
        }
    }

    private lazy var image: CGImage? = {
        let encoded = AltClickHand.handPNG
        guard let data = Data(base64Encoded: encoded), let img = NSImage(data: data) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()

    private func show(at point: NSPoint) {
        guard let cg = image else { return }
        let window = NSWindow(contentRect: NSRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: reach * 2, height: reach * 2))
        content.wantsLayer = true
        window.contentView = content

        let hand = CALayer()
        hand.bounds = CGRect(origin: .zero, size: size)
        // anchor on the fingertip (layer y runs upward, the tip was measured from the top)
        hand.anchorPoint = CGPoint(x: tip.x / size.width, y: 1 - tip.y / size.height)
        hand.position = CGPoint(x: reach, y: reach)
        hand.contents = cg
        hand.contentsGravity = .resizeAspect
        hand.contentsScale = window.backingScaleFactor
        hand.shadowOpacity = 0.35
        hand.shadowRadius = 2
        hand.shadowOffset = CGSize(width: 0, height: -2)
        hand.opacity = 0
        content.layer?.addSublayer(hand)
        window.orderFrontRegardless()

        // CSS rotate(45deg) turns clockwise on screen; Core Animation's positive angle is counter-clockwise
        let spring = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
        let intro = CAAnimationGroup()
        let scaleIn = CABasicAnimation(keyPath: "transform.scale"); scaleIn.fromValue = 0.3; scaleIn.toValue = 1
        let turn = CABasicAnimation(keyPath: "transform.rotation.z"); turn.fromValue = 0; turn.toValue = -Double.pi / 4
        let fadeIn = CABasicAnimation(keyPath: "opacity"); fadeIn.fromValue = 0; fadeIn.toValue = 1
        intro.animations = [scaleIn, turn, fadeIn]
        intro.duration = 0.9
        intro.timingFunction = spring
        intro.fillMode = .forwards
        intro.isRemovedOnCompletion = false
        hand.add(intro, forKey: "intro")

        let outro = CAAnimationGroup()
        let fadeOut = CABasicAnimation(keyPath: "opacity"); fadeOut.fromValue = 1; fadeOut.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale"); shrink.fromValue = 1; shrink.toValue = 0.85
        let hold = CABasicAnimation(keyPath: "transform.rotation.z"); hold.fromValue = -Double.pi / 4; hold.toValue = -Double.pi / 4
        outro.animations = [fadeOut, shrink, hold]
        outro.duration = 0.9
        outro.beginTime = CACurrentMediaTime() + 3.2
        outro.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        outro.fillMode = .both
        outro.isRemovedOnCompletion = false
        hand.add(outro, forKey: "outro")

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) { window.orderOut(nil); window.close() }
    }

    private static let handPNG: String =
        "iVBORw0KGgoAAAANSUhEUgAAAKgAAACGCAYAAABJ7cHyAAA92klEQVR4nO2dSWyc15bfv5rnkcUii8VZFEVKsjyKeumG30ObDt6mF6YXAXrxpAay6AVlZBdY" +
        "yjKI9BbZBLSBXmQRqRdZBLAe8DZptPQW3eiXljwPGmxL1kRSA+fiPFbwO/eeUommZFLiIFK8wOeixWLVN5x7xv/5H9f09LSzu3bXi7q8W30CO3UVi8WfverP" +
        "y5fL5ZJj+c+7a1dAN2QtLS05s7Oz+bm5ua6xsbGesbExZ3Jy0pmcnHBmZmachYVFZ3Fx0fH5fI7f73disagTi8WceDzhJJPJD6LR6EcIqdvtfull1LVr4td/" +
        "zc/POxMTE6cKhcKJvr5ep7e313nw4IHz8OFDB2FFSOfm5pxoNOqEw2Enl8s5NTU1Tj5f69TX1zvV1dUuj8fjcLzsa1dA10ljohGnpqaOj4+P9wwNDTl37951" +
        "+vr6nPHxcWd8vIDAyjE1NYV2FQFFQ3IgqMlkyqmoqHCy2awILILa0NBwOhgMfuz3+/teVmHd9UHXYSGcc3NzHUNDQz03b950fvzxR+frr792vv32WycajTiR" +
        "SERMudfrFf8SYeNnI7zjzvz8gnwGwhoIBERIOzs7+ZsTlZWVHYlE4t1dAd1da1oEPGhOXkdHR88PDw93/vTTT861a9ec77//3rl165YzPDwsAhcKhfAtRVMi" +
        "qEag553BwQEHbTs4OOgUCgU5cLlu3LghPmkymXSam5s7GxoaighpIBC4gN/6Mq1dE/+MC+Gcm5uLz83Nvff999+fuXbtqhXOH0Qwq6qq8CWdfD4v/mU8Hnci" +
        "kbAERouLS+KnIpxDQ4PO3bu9zp07t507d+6KazA6Ouo0NTU5jY2Nzptvvul0dHQgqE5lZeUHiUTiI+clWrsm/jkEdGZmpntiYvzUzZs/OZ9++pmDkN65c8fx" +
        "+fzOq6++6rzzzjsinDU1NYVoNPq3wWDwHKadv11YWEAQrw4PD7f99NMN58cfsxIw4ZsSSF2/fl0EnoBKXYRgMNgTi8U+eplSUbsC+oxrfn4+f//+/VO3b99y" +
        "rl696vzww/ditg8cOCgBzltvveXs2bPHSSQSCNgHfr//nPqR6oeGw+GTbre7u1gsdmL+STNFIrzGRZP29vY6AwMPnW+//UY0bzAY5LNOETiFQqE+5yVYuwL6" +
        "jGt+fr7z/v37zpUrV0RAMe01NTln//79zpEjR5yWlhbMsksj9ZWS8ZFI5Fw4HD4Xi8XitbW172WzVWfQlvisaNn+/n5JTRFsIaDWbTjhcrnGQ6HQaeclWLsC" +
        "+mwRe35kZOQMwcynn34qwU0uV+20tu5z9u7dK75jRUXFBczyk9YygS14vd6zlZWV77W2tnYh0FNTk87IyIgETWNjBYfswNdff+V4PG6ntbX1VDgcPo0WVuHf" +
        "qWtXQNe48B2np6dPEOCQTrp06VMJhFpa9jqHDr0iAlpTU/PxWjScmvx4PP5+c3Pz8Vgs2kOgNDg46Ny8eUvM/e3bdyQ1NTs7J5mBxsamTr/ff2Gn+6O7ArrG" +
        "NTMzc/zevXvdpJQQnHv37onP2djY4DQ1NUsOMxaLHV9LmVIFDI3r9/s/8nq9l/bta704MTHuuN0e0dCUSXt7+xyPx+s0NTU6AwMD5xOJxMdr/a7ttnYFdI2r" +
        "UCj0YNq/+eYbKV+yCGrQoviI0WjkOtrwebSa3++/hLCHwxHEVwSUvCr1fKpTaFM2SF1dXTea2ufz7diAaVdA17BIylP5uXXrpqSARkdHROsRqVdX56RUGQyG" +
        "/sfzajRMeS6Xc6GNh4aGitTzKZPy3QMDA5LKohiAqa+qquoKhUI7Nje6c23DxtXbHaL3e/f6JECpra0lgS65SgTG4/Fcfd7vUiSTx+MRl6G9fb/T1rZPvsdx" +
        "ig4Ce/Hiv0ngND09/aFWtHbi2tWgayxtYmYx7fieFRUZp7Y272QyGSlNBgKBPrfb3b8eD0bTU9lsVlJXfC+ak42BgD58+EBSWVNTU3nObacGSrsadG3R+3GD" +
        "65xyZmZmxT+k+kPeEu3p8/kuuN3udfUHI5HISXxbgrDW1lanuXmP+KaknsiRIrQPHjwoTk1NdTg7cO0K6BoS85hT8pIzM9NSNXK7XSXhtGilT91ud2E9H1A4" +
        "HD6dzWbfbWhokBQWWpOqE5vkwYOHEjzhclB2dXbg2jXxq1zFYjG+uLiYR5OCiMfcsxRYbBPm6yqcLCpIHo/nAu4EpVN8YHKkt27dlp/xQwnSEonE0Xg8fkx9" +
        "152ydjXoNlhutxsf9wPM+8GDBwXZBKh5fn7OuXHjugPYhMLB9PT0UTbQTlq7GnQdAqelJaNR0bLOOi+XDX4ikchHZAiKxaXzaFI0qEne9zrpdNrZt+8BGYUz" +
        "1OkDgcA5Z4esXQ36HMIJrhN4HNhOjoWFhcNLS0vrLqSqRSltJhLJC/iif/mXf+lks1WSxO/r65eD7MLU1NQpZwetXQ36XAK6IAJqjlkEtGNpaSlPwWmDBNSJ" +
        "x+PvtrTsLcZicUl1TUxMyisVJl6j0Wgbaa+VavTbMRW1K6DPuIpFaS1+rBFufn6+rVgsxpwNXB4DKjnpOM4pNOkbb7whG4SU0+effyYIqMHBgWIikXRSqVSB" +
        "1BdmnwxDIBA46/f7C9sJYLIroM+4lpaKkgul/Kh5UQIUq0E3VECj0ehp0k+trXuLw8NDUpc3xYN+2+M04DQ0NAL7iweDwS7+JhgMEuWTCvtoO0H0dgV0lYsU" +
        "ksfjof037/UaMAhmXZFG5EfRohstoC6XS2r1rKqqaimD8m/T0zPOgwf3JXE/MDAo5p4AChQ+AhkMBpxYLN4TjUZ7tEoVDoecUCgsZdpwOHwB4Al+7tNwrJu9" +
        "dgV0lYsSJjA4n8/XhYB4PC7bPzQqQoqpR0AXFxfbnE1alZWVp91u9wncDfqY0Ob3798THClaNZOpkDwqAsyrEkUA4UNA8VVp7OPI5XKd2WyW1pMPfD6f9D29" +
        "CGtXQFe5SPH4fL4/hULBLuruPGzAw2hOhBPfDwGhy7NYLB7nbzb6IUcikZP4mFNTk+cx7QRMnAO4UapdlGURRM2NakHBpMaWSkQRILFo7kNQKysreyorMz2h" +
        "ULgQCoV+7/f7/+Dz+a6q1t5swd0V0NXeKK8Xc/lRIpHsoTaey9UI9I0AqVAwMDjajWtqavJKwrDRD9Pj8VBmvVBZmS0cOHAQf9P24Qclkc+BIHKOShLBwYZC" +
        "ePl3ov9g8JpsOCpSoLM46upq4/l87alMJnMqlUp9QB52K3zXXQFd5dKSZjweE21TV1cnft+9e/eF2gZ0EcEJD35hYSHu9XoLG41099hzqqioSITD4ePxeLzH" +
        "5SId5XNqa+tE0NgshcKYBE804eGb8m+c5+jomLgG1neWNBbdAfX1dU5bW5v4t/TnLy0t9fB9aGu0aTm0TzMCKrjrLcS7ArrGRUDBwwe0wUO/ft1lzWqvkH8Z" +
        "Kpv5TrfbvWnVHI/RpGdTqdTvmpubOwIBv7SGICiAWdhUmHEAJ6CglDBicJDXoZJ7grtCbhcACu4CRBI0AO7b1+rU1zf0oGFxb3AZKEzwvQi1Zekr4A7YluhL" +
        "67U5dwV0jSsSifzvurq6v+GhXr9+Q/7NVHP6JEBBmyKgBFSO42xKK4bH+JaFZDJ5hDRSZWVlN4KH24GA4lvGYrFLBvCy0DY0NCzuCCgoA77ut68m4c9BKZXP" +
        "RUDpzd+/f1gqV7g3kEmgdRFMPp9NG4lE4uFw+GgqlWKz7AroVi2/P/B/MpnM39CDhDZhYeoRiPv3DZD5wYMH3dlsNhYKhY5t1nm5bPqJVJHH47nmOE4P/49P" +
        "GolE+gKBwD/YTQPzyaloNNpJXhSUPteCRiU9pQJKJoBrIlPx0083RcNS84cvCqjhwgJwQ0OChpAaRFWc1NfRXC53lPfiu4bDYTAEz8x1uqtB17igr6moqDiW" +
        "y+XOEFggGIaUdkGqOdTEEdJQKHSU9zmbuFwuF6a2zybj+2Kx2Hv8O1UkshAIKALl9XrfDYfDHalUqrOmpubo9PR0W3nPE9dBz9WVK5flZ9wX6H0QRAIx0lom" +
        "E2BYo/3+AMLoVFSkxY1A6+ICtbTsZZNcognwhRXQ1fTKbHZkuPycyv+/nKqb14WFhXxZjd3yMU208SBJ1KOh8NsIPDD7P/zwgyUKw1etLbVubMZy2f56q7HO" +
        "gWoCvMK520JD6feY4WKxeGlpaek0mws26NnZ2d9ls9kuAkCsAweCiS9KpQohJhjURZIfTACfNzs7I24Dgjs8PCLaF43c0NBwkaAym80e8fl85JHX9Lw3VED1" +
        "Yf+SkG5m+kIhcuX/X/7vPEx8NWrqJN0nJyd7Jicn4waovCBCSD88GEy0C/TdBAwaLX/zzdeiUTGdBw8e7HiWh7Iey23vabFYLHDov630PstbCrEZ5/qneDz+" +
        "Hi4AETzakzZrSCrgn+LQlc/XOIcOvepUVmYlG0CXK4J5+/Zt0cCYffACb7/9tnP48OGL8Xj8A7T7hguoCp12Ey4fGMBD5uAB87CXlpZqnlahYXdjkviZV0Wm" +
        "P+9DtecmwmZel9KLi0t7rBCWQB1oSM4VSht8LgTRak+58RwIIAe+GW3HPDh+j5YkKU5OkciXCJgEPiCOkZGRiwCNPR6P+GGbuVyrAITo78voxvtsCzOBlvyu" +
        "sbHxYi6X68Cn5O2alsJ6IJj79u2Tuj8allKrUvWA+udektoii8Dn1dTU9JCq8vv9V1fLHbBmAVXBnJ2dbcfcEbEuLCy0WaCEPETt2+FBGe3yc5Q3+To1f8o4" +
        "rIlmNA7//7ymkfPh+w1mc86ejzknfsc5sJSmGxOFWeL89TrRhhw+n1doFXnlfImM0TDBYEh8TrotDc/nXXl/b+9d56uvvgL93tPU1HRuu7LRhcPhk7W1tefN" +
        "8wnIddNmwsF9QGPi0hhuqlZJteF/3rjxk5Rb8VfRpvirr732Kvf0SkVFxcfRaPT4amr+axZQLZPhrxQKhW4SvoqJtKBdqU9jCvV3/PvyZQTTPGzAFwgl9INc" +
        "LILK8bxaR/vYzTEpPhQRN7uf3/H9LHY+GgDTRMTK7telVgGfEk2AxkRrmA7LZqG70YACz4EUDt+HsGLueai1tbWdoVDorLMNVyQSuRAOh12ZTCZfVVXV29bW" +
        "7vzrv/6roLcQPgSUAGn//gNQTrr27t1bJGV16RIJg6K4B5BMcG95P71VHo+n20L/JKvwzAKqWmR+fj4OUntycrJbS2XkxvDBeJjj4wYTqcKrAoHGMgHEI59v" +
        "OTlBuWNPiQ6NxM56ntTEShoUs2Qwm5yTadEgTcLCdySXiXBxbXwv/lMymZASYDQac1KppKRZKB8SqSKomUwlpqtvYmI8j9bE/GH6CRgGBh443333nQxHqKqq" +
        "OpPL1bwXi8Xex0Jsp+WyrgL0OolE4gO3293T3t4uv+NaqZ6hTWtq8gRCRd6LOacSxb1G4Vy79r3kiBFUMgGjowed/fvbL1ZVVX9A+fhp92RVAoopHxwc7EYg" +
        "1dcgUADaxb+hLalHq7ZRf834gPipT7748pugJn89gyb1k3XzmBTJ4yek56utG0SvmKz6+gYJBKi7c9NB/wCu4DWVSp22/tSFmZmZIp+Jf5rJ/GDLnoMi7JhE" +
        "omKv19fl8/mOBwKBbUlT4/F4pC8KzdfW1jYG0ASANDlTZIJKFfeFnGo+nycYAtrnBAJB+f3Vq1dEUHVoBPc4GAwB/SNHe25NAqoPrFAofDI0NNSFylbGXwXE" +
        "Kvm/KZGZuT9wV6KVuBh8NQRTBUIF5HHhpW1iUZK+GpgsF571Wjb/V/JvDZOcT/xKzDC5PH7HkU6nnLq6etGSVE44MGMkqePx+IVoNHqs3KdMJpMnl5aWTpH/" +
        "I2rFtTH5RKNdMplv5X0+n6+UF9xuwxBcthAAxiCdTh8JhUIfIhvNzXecO3c8IgcQ+XJdNTU1MSJ2tC2b1ACqH4qMoNSwRAizgS16PonFYq5VCyhCgkmfnZ09" +
        "2tvb2wWD8PffX3N+/PG6jVAxlTMifCg5TgjcITsFVU0d2Os1QmAiYSN8qp3wXfABjb8KGeysPNDp6Sn5f6Nx119IOS/Mi+b3ODDjmCBT9UjLvxkq7nhJIPl/" +
        "S2tzzkLPAEw8FvBQvclkMn3Nzc1n8L/ZZF988YVlorstwRjXZNmTSbe87/P5tm3nZSAQuOTxeP62sbGxy6TUskLHA+Mf9625ufkU7kAsFjvW0NBw5vDhw2IV" +
        "YYqGzhzOU3KoKDTej9b9RQEt12gjIyN3BwYG4jj/sPqSfDaq/KFyWNoHZyBaJrjhIQbFj0RAjQYVYS+LpOdthG80LqoeATWDrgQF9BgpwtME9Zfyq+VuAj8j" +
        "HAopoySnAsirMd+VqiG1NHjWCuQv5jHNxgyczeVy3dPT7R1cFxoU7Ylm+fHHH+Q9fDbnUl9f/4nP50ugjZ6XqnErlmrSbDYrWhJ5MKXSh/KKyxcKhcTn5j3t" +
        "7e09XCfximEFHJV7wnPAV0XpWW368+/SH3jYjFWB3uXy5cvxL7/8spTvI2WEH0Wkhg+GyTMAgbAENUTcmEs1o8bMG61hzPoj045G1Z912oVmAXSGpf7uaaxt" +
        "+re8d/kyLoYwcpRXTuRQc845s5nQquxmkObBYFAEEy1JPdvr9ZKbXbUAMSyhrq7uIudE0pr7BhwPF4kJIBDSYuL+4i/+gvs0RvNbLBYTKu/tuAKBwNlkMnm4" +
        "qqrqqPrmyq3v8/lggD7K8IiKiooeAkvST6TfCEZNwaNX8AsjIyO93LtoNHpu+b0uCahNHR0dGxs7wc38p3/6J/E10XBolwMH6qVqQHpl797WC3xgIBCQhOt6" +
        "LRVKJmiQX9WE/0qdkjax3rESk4bNqZ6jKqIYxvUOvlZakUjkUiQScZHsnpyc6ObcSLcwCeSHHx7KoAVQQmwKsgHFYvEU7sFyTOV2WX6/H279YzMzM0dBOiGg" +
        "KCPywigwOPcZjJtOp2u9Xu/5lpY9bQTYmHoUnzJUDw4O5t1u94cI6PLvKAnozMxMZ39/fw9+JuaJe1VXVyvRGSBWONibm5tEWLmpXq/36nrfUH1IaC6Xy/UH" +
        "rX+vJKD8LhAI5FeqUlGRsuAIQBICHN5MAUCz1NfXdxs/3S2BGEKKm4QWxT/FrEFjc/DgwSIPlqACwd5OQ2RdNvNCJsMCT8R9u3v3joyArK+v68SFotkQnGgq" +
        "le4hkc99wC0g9sANIh23f//+DjIDy6+9JKBoT1Qz2pPonC8HmMtIFZKzmPVMJgPesOSTbYSAllWXCk8jQFheXl3+OeUprPLXzVjBYPBSXV39kUym8kO/399l" +
        "/N+IPDzu8eeffy5+PZUrzgsqm7q6Ovy0q7RwbCcBdRkE1R8QUJQZiXmqafjzxBUm3ywzSM9WVKR7yIzwHgSUzQoYBV+UQBse1OWrJKAQT7HL8T25QURWe/Yw" +
        "60duXgGHFxO2GRdd/rodFw8EVLnf73+/vr5edhBUjTwUJsjhdxEooD3wixXilsvlzvNgE4nEtUgkcpwqzna4D2wsfHqCUFPm7ZXA07a/tONioXAYUoa14EBb" +
        "skFJQ+GjU7+fm5trd7lc4o7pdZcElOoPZb7PP//COXTokIzysyNV2A37dzJR/3qvchBGZWXlsXA49PfxeDzEvSRX+sUXXzqXL1+WggeCiWIgeGJ6B8FobW1d" +
        "G8IaDodd20FAYS6xoxolS4OAcq3a/oIA28l6hYqKijjCSwGDKiMZD205oXzudrt/r+wnLK+aSKJoJBr/AN9IE9TJZPKlGbu3EeYvGo2eDYfDZ4PB0KlkMnkC" +
        "LWLaladKCHyTYvFKQEq51PQJoV3Gi1r6tcGeZBdAeyEUFgEmmYb1KA0/6+IcVECRJ5SdyW1LSrHbuoWXaGNOJpOn0J6YdHLG2nHKK+/V69TPFgFdntLhQrXi" +
        "shGkrC/TUr+ah1NRUTG+sLBwiodBWg5fDN/UCKC3hKaiOIJyyGazYgoxiclksjORSHbiz2ogxd+RNKedgwBrqxhBLPdTafQ4+V6uB3M/OTnZFgwGO1wuF+d5" +
        "1mIc2KziEhhGFgPgmZ2dpa+pvVgsPhJQ/vNzAX0UrPDlW3LVO0yTBoPBQjAYlH6hhYWFT0zBI2CLGQuC6CKoePDgnvinRMLxeEJMJYEFAYiWXLUkS+6W1g2+" +
        "h3zjZjXprXCNpJuu+f3+Ns6JAg4Ci4DiY8bj8XdcLhd1/D6fz3c6kUBAU3L+IJ5439SUwdSGw+HflY/V8SqaqAyBLeae6g5/AOflVlz0Tl2kx7i/PBSElLQd" +
        "SCkEEK2Dicc8Pg7ziwuiCo1jtaa82m7KS6RwSM1t8SYssMk0WKKaSCoNDYkf+nhaKiCWw7TLLAnQCBI03B2fz9cRjUbbATU/JqDlJTc+WP2CxcVFg63aXeuy" +
        "yNvqg0MLEjAQjBKY0mQHup9gYWxsNE5kq9atvD1DTaktDDDqm9r4lj4h/FD8aDAPCCibjetks4HtWJaWks2FMFM9REDp0UdAMf1VVVUoRSOg+gUGxZOW9BI3" +
        "gro76Y/x8fE2/uhJtdLd9Wz+GgfYBCJYsLOsYDB41uVynSXFFAwGT0WjsRPl6C8rCKpFFbwiwrnV0b66gkYIKXM/Gn5W3gOmsmYZ9USmylFu9lpLLNUlAeWi" +
        "s9lKmcfDzTMpkAcC5GWAKsDSXQFdnwfJA0ILokW5x0ND1ULhOD8/X2qygxgsGAx+rD1V5Z+h0Xu5a7bVArp8KfCofHPpMv4zyK5wiUrySesxASVapKhPNGn4" +
        "JfskTwfjGT4GUdjGXdLLscgJYp4xg0SuVJaoY9Oqm81OAvL9W/wvG5H3bVXgs9ZlGxMtMMj0p5V3TZQv7T8rb+tR8M9ybVtKnBEFGgFtFDRSf/89wTKCPkFI" +
        "mZG+WRe7kxf4gHg83kf6CBOPEiCxTTVlZGRE/E9nm62iSVXaGVILloxssYQqW56fLUeX8XM53z+v5Raj9Jcgf4goAYYg2USTaFGqSwjq8PAw6KEV4W27a/UL" +
        "HCWBDX49QQWBKH4obRGGznHyxHYcDru4uNiGbCCcNvtTCuiWm3EVUO09YwHyVgKM8lUuoCBSRECBghFd4ryDvPmXf/kXAZo+fPiwODExcXy5Gt5dq182yDkX" +
        "i8XOkd88ePCAIPb7+/uc69d/lET9zMxM+3YayFUsFiG2iGv2B3eFahmBEIn55a4huWBlxful6le5ib+aTqcB3Do1NTRAVUiSVQWUfhNMPUwb2213v0jLInsE" +
        "3Myk5AMHDgiaB18UIAlaFDMP5U5xm9xnNe+amKdUi/tClI6lINuwAlt1CVS+KgFVSFQsFvsYQMPhwx1Oa+s+qQqADgci9sc//tECcG8XR0ZGTinx6Xa5keux" +
        "tNWEBzI1NdU+Ojp6YnJyskPJIFZ7L8BIYqXMPY4Jypy+L6hlrl+/fmJoaKh3u9xXcruYddxCMhMaIFkhhDjssUDPss6sGOEvXyXnwCZQASEcb2pq7tae8vv3" +
        "+wVp89lnn0rTHCeA2l5cXDxRVVVFWwS5O+dlWjbihCvgv42Pj3dZGGIpYb6a+4FCgMSADgWQ5Ya+8b6gfGjgwwRWV1dvGQBkLYtiDtrTpiQfi+Ax508T0F9y" +
        "Fx8TUJX6TCZzbWlpqQ2T3t/fK3yQmB6CJUw9ESj14omJiTOVlZVn4B/abmjwtS5L/iAMcNPT07yWqjyBQKBjrQO87IDY09XV1Se03q4ksmByCVSz2ewYaadQ" +
        "KASxl/OirTIapN8BcgcJh4DaLlgRQNpBrIkvtXNYYrZVWZyfXbWFiB3zeDwf7t3b2sWuoDLw7bffCcCWHmeiLTPuZEABzTJYABfBIuF33Jqenj4+PDzcYya5" +
        "SSAjG9WQahn421osiaXn/j3tKfA3HT78lnPlylVJOSGkPOTq6up4Pp//JJvN0tPzwuVDNXc5OTnRQWEHxj82cmVlpoRUQpEFg8H3lgkohHLPLqCgwQOBgKDB" +
        "zeyfJUHa4IsCIqGHRDmPlPZmZmamJ5lMwmOOqaNhrdQRuZ1cgHK6H0bKAHSgHYbiBQd+FpuW9+HqYIrJbVpWvlVfq7pU0BHW1tb2TE8fkoeNFsWVAopXXV0l" +
        "bpbf77/icrnqfD6ftCm/KEspkRjGoPcHC0yrEIEfAsqGTiaTRx3HObZSR265idcyafla0W6o/5BKpU62tLScAn6H1gQIgJmnMxG/iRGAtNWyczgpEOGNjU09" +
        "mUyGQ8y+xZQ62ykAmpqa6hoeHoZVRbQZ1oKNCrCBVmsqP4rVTKfTp21NXAR0LavsPn+M3w+pBdoZTiPQPefPX5AN4Xa7401NTWPJZPLdaDRawkpu9UI4+/v7" +
        "u01r+oxE7UoTToqJNCW98lVV2cf+TvOl6iaxQEKBcrJT/MZ/UUA5ksnkaY5YLHbe7fZ0GvTJgiTvEUyqTZh8qGLInb722muC64OWEG4ePsv2mZcg/OUP8UVh" +
        "Vi7nO11cXMxPTEz8L9Vk5H9pJFT8Jb3dBDYtLS1nMdHhcFhQN8+y9D4nEonj0BEWi8UiDxShhNjgs88+k/el0xWCXmICHIDeF8Eqcb8gk2MDkyIj7wksELAR" +
        "1UhQTOAMbBXyiQLKzwZRZ+iIlHFQ16o8b9qM6+rqOvWegE3ki810MwE5iGn65ptvBTalvlk2m+3J5XI9pFM4eUxiKBS6AAhCozulpl5Pd6Cc2bmMPEyosG3F" +
        "ow3TTau1stJxoLVIlOOyKKcUm5KNB9W14jZpnbUYzGcWzvKlkMd0On3plVcOdfCd3C/Hgf9+2vnzn/8s9/vQoUNtra2txVQqdS6ZTL6/VS7UzMyMUCNxTlhS" +
        "2lPwO/fsaRYACOePG6SuEJahfBk2GcOSuBI155oFlEGjdXV1iUwm82E8Hj8B1R6U0OxytAwMEUZghyXKVzgZkemBA/tF45gJZnXSupBOp9swixaRQ6oKBM+a" +
        "WDzWgKYpccwDvsavpLXATIgriI8E3oAbzVgZkuWwn6AJKFrs29cm54+FwKzHYtH/wKSP9aT15ro531QqdeTgwYP0l5/n38fHx8Wlgo+T+6yzieBE0gkjW+GT" +
        "Ipyjo6M9aEjuHXEIrdOvvvpaaZodLiH3F7eIlo7yRVbI0B3RVDf3/AJqpuUGcehP5vO1R30+fx5zh0aBOIqDXKnhKR8V9W58NsNYhxPNjeZ9hsKwMh8ORyAx" +
        "tRQ0hj5HqwtlNIwCK3ta24nSe5MstlrScjwZ8AEPVQHCNKoR7HHjTL0Yzqj50lhAZRDG1FCs4MBd4TWdTl9LJpPtG8XvWZbYvuB2u/e3trZeQbtjrdCk3EcC" +
        "J66Lezw7O4smRajfh0VlM5rm1CrNz8+/YzoChJxXgmjYABluOz8/f4JgCZNvZin5S/ywZX9f4uji2rjv2jlgpzOXMhZrSq5xExKJxBFmj9NXgoaBYZjdTQoK" +
        "7YNW5Qayg9hJ/DtACIVXmW7RrBC7ogU4KX3V96iger3ePMfTtIRWdfRQgVTqbgTPpDtG5LyUFpHfEfCQDsEl4YA95ZVXDol7wo2n5ItpJ89rfWlnMxZl56am" +
        "5kvxeKID/5OgA+FEy/NqOz7lfFtaWj5xuVzvQviwkQJa7jJZ1L8lX3tdcp7kzvHJHcc5wb3lnrP5QTXhLj2eITFDeJWyE2UH+RzPwLSLmHlOaxZQm4KCaP90" +
        "OBw+nU6nu1Kp1Cd8MH4mZVEifQRAuUM5WW6oGf5k8qdoUaU+NFSI5lUFVBn0lM+T9gF2mjGp6l8+umBNWSgXPT6PCqhqTv1/tKe2UvBx+n2czyMNj1WolBYM" +
        "UkgQD3D99ntKLgO+LJp7OahYW4JxX9SFIY+5Wi1n528eQQC4YO2wxWcjYsZacS7wsnLduVz1+VQqXSCpb5H2zkYuC/bIW7ZA2qpPWrqiEu0699pC5x5zuebn" +
        "59sJpLkWfFHDPBiW+49iiEQi3LNn06DLTlLaDpLJ5DGIWWOxWJwbCuDZsDBTheqXA18FXw9Tz8kjwAgJwoyZUGRLOcmsGVrwCFCgZl+HSGE2NNlbRjpmj0ca" +
        "VUtqZBrQRk1NJiJWZ97sXhPAmV4an3wGm2tpaekMZAPhcPi/6FgaGFi4uaRQdCMsr4pwvuq6YLos7+hJNvVqhEcDH4/Hw2ah+HGUz8KkG2qZO0KwAWqIDd/Y" +
        "KG5IvLa2lqT+2Y0YILaMypLJJd1WUEs5b9WOaHf1O7X0y72ZnZ3tBFfM/aMPiQ1GCjMQMOad60P5lW/i5xJQ25t9Nh6Pn0Xj5HK5E4VC6ykE1KRpbgov+U8/" +
        "hYQ7FC3IRShnfHlPfjknKLkwI6xKn/joZ0VsGypHBMMADszfcyMeRcV6oYZzHqJaAyckCrcVoFL2QAMVPgfhxC81gx3i8Vgs1qMU4dxcfCzja5sihW4IFVA2" +
        "FwQNmC3q6nxXOp0+lU6n3+Ph6sQ3/d6Vlv57KpU6lkgkjlVUVJyprq4+io+Mr4+55z7qwAozE0DSNkfxY43m914FfL5ewaduHFJrTFd+QtlT7hGvysrMOdhu" +
        "4a6JiYlOnanEvePZqhWF2JeybrlLt24FXkVDWZJWZkFaX67Oee01zL0ZtceD5VAzgCBomsdovIVlrQLGnBsNqlz2XLjPCQYReEwKjf9TzIm00baYZ7lodReU" +
        "15TALpEQCNjP+ElxS9hYpJvQ8KZPmwAuVOI2xflXv1ZdCtXmuowGNZ2XZrROUO5FZWVlRz5fc9Fw3+cvYRrJkDzN7LvsvSCtlc1mqfm3/fa3v5WNpsEd94zs" +
        "CbEAbkpVVfYMQQvvSaVS1yhdQ2i2UfSTGgeAVeA5s2H4f2QAq4qPatJNM908e73P3GOeB26V+p7L78W6CqglgD0djUZPIxCNjY3C82l9NeH6vHPnTie7n5PE" +
        "HyQxzf8DNDADoubkYtSf0dE25r4agX3Eg++zO9Nw/HChtO/C2ktCnVQRJhy/xpoioY7BP7QInO7p6eluzkO1JkEdzHPwJVGMMK6GV7S16Zl5FCzow9FNVH4v" +
        "jKtiND5/g4ASdHFuv/rVr7hXEC7AD3pklVrrUjAYbLdu1PHf/OY33d99920bZWeEU1kJI5GYTCc5cuRXwkzY0NDQBq7C5/O9v1FpKetetQMaUYXDc1PAslLi" +
        "aG2eQJV7S6qJgJlODvrklTC4fK0rRKZ8WgerWCwKY/GycYNQDLZhqjQXCYsegZQKow4qNX0qZrLu8mUGIZg5mZRe0R5E3sqcjLDW1NR8jGBqhFuuQRYWFq4u" +
        "LCywY38HszQ3jl2tRF4UIdDwHk/YauuQbAw7G/0xn1kP9bfM95j7oRUTzpVggM+koAEvU0tLS8eePc1FYHdkR8BAPCnx7ipzW6jfM0W4oaERh0YsBXV7igxm" +
        "cJrxh2EnMYHV3a54PFEkiCVtZa2KcCBZd0A017OS/OokmJGRkS4qS2xyzDYWC41ukU1xM+vTjC7iPvCsyAS1te2T961kSTYUw7VSedM+iPfKKzoIiGrOx6eB" +
        "YDZWHgSms8r5OwZm8dBJWfBVCDc3hfJh+U1f6cYTgeO/wa1OQIew82qwB/igMQmuMEHKc49A8KpZBzXlmnlQ7a9T94w7Y/J+mD+0Hhugo6NDtAjEDc3Ne+B6" +
        "P/JLeFJXmfuTy+WI9D9sbm7uMpPyRkQAOAhUzOS7O7KxdLQOOAI7RAKep85oNHoN98EK6tVn0bIIH2VPrs10BtyQ/DGbgdiE+0ORBGVEwIzfzDNNJDLyvoMH" +
        "XxFhXum6NxxkuPxLLUfRU9uXVUBpe1AXYfl7CALIIszMTP/HQqHwP8103QEJYNDGfMZKEbPNleZpXXn48GGXKdfdETcDx51gjLKdicDDYn7wZ3VQhE7DUwFV" +
        "lg8VUBUe9W81IY3pw42g9wiQjTF1D2VjofECASHYOm/9UskDup4gqLrZLLPI+0S/IIu4pvv37x/FehhBfSCbg01stJxh+ng0/keCTZRETzgc/hhBhZ9zLQJq" +
        "E++daEdcDEU14f9qZM6mJXpHCVCw4dpRJvyeuAFXjFzzlgjosyw1Zy6Xi9xhyUVY/h4D4nXNK/0gvg/FAgQGDbLSgiR1fHz8k/7+/jY4OvHd2PkIOIvxhmhK" +
        "E32nRCA1BYXmsaNkSj3dOmfUmkmpenFofhTNAfpeU2AjI3skcCTDcfv2Hefy5e+cxcV5SbkVi0XKnJ8Eg8HatdTY3YaNULpFc7nceCKR6MbdMdqbEZCTZSVF" +
        "85namqETWIrFoqSNuAY6T1fz3WV56MNocPDBCKoFcZempvC+QmEMinl5Ptxv7p8Z/5MqFUK2lYA+LQWz0vsxY2go5vWgAYkmFSmjKSSLwOl58OB+GwJiRkz/" +
        "YKP4eTGB5BSZLqdJexVIS9Vy0laUeIjPdG30MeVyuStomH/8x//rfPnlF+JWkFkg2g+Hw3ke3Fq0mOsRvxbW6Xg6nT5e/n2gs8bHxzsQHgVoaA8V1467pNrU" +
        "zgVYFei8fBIh1gt3Ag2N8OkcKqwBgGblXkKDshBMgkZemWD3pGf9Qgrosy6zm2kzmJMbRYs0AoVbYR9Kx717/Z1ffvmVVGR4MEwuUY2IYGDOuWlmRqck7iFn" +
        "/YMFtFxYKdJcy6IqlUwmP1haWuqhYQ6tQ2WFIA+wbkWF8GN1Edy51yEtxPfZSg+9U++lUinpByonJLP+PHOhzq1lOIZ1xeJjY2NxJpj8+c//T3z3lpY9MnCD" +
        "+4kVQXhpqUaDYt4NiOigHCiBp13nDhNQ8nEGa2gFVCh78HnhSmen9/X1y3AyfLRXXnlFZj8pmzQ5SZ2TpKXJ9cav2uS/zLzct691jOCJsSxMacNfJKIFcWVZ" +
        "iy+tx/d5vV7GBgF0BnNa+l15gYS1FqtVlv+U4IeCDLBA+vxh6AajwUYvFpfS3GusFQJK7rO9PSbt1ryPYbxP+84dIaAaVJUDGtS3snOWxJGnTEli+K23Dksp" +
        "jooSDWu21PmBzZNKkKDR/0Ysa5JlqAAbA7+MAGZkZFQgi8PDw0fRPiGbdlqP73vSz+r+6FrLNY+NjX1y9+7dLrISCCH3nZQZuV40I0ri/v372e++u+x8/fXX" +
        "co10XSC8jDjiPQRmT/uObS+gBqjxiLCqXECtnyWzltjpaCgePKDjQCAAGdo/WLP2qQYG5cdGLhuFywMFF2DKlgauyBEKhY5S5tzocyh/Xf7zLy3ynnQcqIAi" +
        "3AgdrguuEgJKxwXWAbcK3x7cKIctN5/dsQJahpqPmZmfhniKqo5WoEjvKEM0QshD9/v91+Lx+LtbPRhCsxBKoKWbSlFX5bX9jVzPshFtabiTwgaDhm/cuC4g" +
        "HpLuCCbVOxOw9knLDNgMnonRru2S+0RRWN+4sCMFlKUpDm6YpZq2FSjpx9Z/I7/o2L59zDdlzxeuhXf5QN8XmVVkenr6eKFQ6CHQRADJQqA5AXaTQeF5gLSH" +
        "jQb0FZkD8BEIJn4/72N6jKKgdqSAlvmbeWPiH0Wm5QKqJFxa3nNeoFXeO8UyWMpH4Jnx8fETWorcaL94tefKPabdw4wapyxscBWUrjl4D5oVwQQjQDECbZnL" +
        "NUrFjKOqqqpgtecvfu+2FVDN/dl5nDAT2+S+8xik70VliSv3lVVj4iNTnmQMjQVZn7KT5wSTupWjZnQaNhkGqm5kQojMgRyyZwg6ScATpVPqhMiBih6BIKVM" +
        "Gg/xTRFOgNW/ZNp3hIBaIb2mAA6T3HZtCwFllaO1FO1z716/gF2MBZgR+GAul4sz59KOezm7FZ2cOg2bQgfJduh5VEAVFENwZ4Dp9EzNCMKMLAX5zr/6q3dI" +
        "OzG+G9aaVX/vthVQXTw0GrNwzLUWrjVwy/vuvIjL4COnxZQr4Sv1aa3po4EGBgYEj8q18aAbG5vO1NXVnclmszDj1W70eHGWYgomJsb//tat239HQYGoHBNO" +
        "eZhNxv3H9+deA7OkL94gp6JS1sXvTCaT54jY1+qi7AQBHWdqmyU2sEgioUa0NegXWUDROiOykRACyrU6+pCSbV9fn1gCfkda5vXXX5fW3mKxmCdaZm20kFqS" +
        "ha7R0bG/I1/76aefCn7gxo2fREtqZ67jGKtFyw/NfLxSzkVg4/H4STDCz3Ku215AMfHAusyNgM3XLw/U9LwP65DSn82C2qpV1nrboRUWEvTkRIl0W1ulU1Ou" +
        "J5/PS/8WmhRBgdFF23mXlpaKQNkqKytdG9EKrcWPsbHRP/b33/trsAvffvuN8913BssK+IRNQmROTd2gvBKSakIwCZiqqqouMCX7eTildoKAXqUShK9GlYhW" +
        "C3yfQmFMHqwlVT1BPT0YDK66zryRywZHnfiblDk5R4AVPGywAa+//pqAV+bmZkWAKSMCAiY4wf9T0Merrx4ClAHeoDQ6cL2W7ZLtePhw4K+vXDGVIBgOYeAj" +
        "14y1Il309ttvi4+prTRAFMPhCJ2/v1fao+fJPGx7AeXiIdSqrMx2GtxmXJx0BJR0BxjEsbGxU/S++f3+k1tNCGuZmY8PDg6eou0BgcNE4qtBHQPcr7l5zxEl" +
        "rYjH40UiYc4bQPLw8F0BliC8tEnU1zf0qCCsRzuH1ufHx8c/GhkZ6aYSRKWIjWTIOUZFu3O0t7dLi81rr73ORnkf3n1nnde2F1AeCq2qBEuZTKYL02JmjU4I" +
        "OBghRZO63e4TDMfa6vOl9fbBgwc9aETgZ2wmGtyoTRNcWE73UutHNlt1weVyd2p3JBsQQDBAZ1BBpG4CgcCVeDz+75+HyIylrB9o997e3m5YC/keBNS4F7PS" +
        "TUAuk8AHbU8DIMIJeNzZgLXtBdRWiUAhoUWLaCL676lkIJzKWmzhdDLJbSvMvOY9oSwk+AGHyrmRSiJK57xtF6aYT13pdPpd23hW1GY8UENE0VRwCKYSiUQe" +
        "ktjnEVCtYDFVEBTYnTu3xawTsV+9ek3672GDYbgGXFW/+tW/E0HN5/MnN0Jz7igB1egQB51ORnCVBEdoTspxaAA7uPWM1+tt34q5ozMzM9A6nrl161YHJUCG" +
        "URDI4XfywHlF+y/X8i5bkKA02NTU1I0QEVwhQOwzrg/BSaVSJPVPP0c+Vshob9682U1AhGBy4E7gLtH0R9C2b1+raG2idOhuNnr64LYXUJaaw9ra2o9DoVA3" +
        "Wol2DloqeIBEudSIW1pamGfe5Xa7HyMH2IxlWZo7Me3wfv7zP/+zCCV+J5qIn6uqqoT0t/zv3NZnjsfjAr4OBAIXEU6mgbDQxiaabnzmc7OFjffGxsa6AX6Y" +
        "VNJlCYhwJxBgXA9cCipCYFYbGho+htd0o336HSGguvBFM5lMobGx8cSrr75qNcOcQL6IMCl579279xOEobKycj9o840gBCtrSgNtfnF0dLSNYIiIXMETaCMA" +
        "u2+88YbT3t4mG+hpA3s9hmroUjKZvNDc3NxJRyh5XjIAtFMom8darAM8n7Zd4xQBEJqTMivCiVtEudVy5csGevPNN4VcDUHlXm/GJt9RAgpKyePxnKyrqzvx" +
        "1ltvyYP66quvxFSBtMePGhh4S7RSOBymk/EkPul6n4fVSEJk0NfX14bWxJ/DtON2kJLZv3+/c/jwYefXv36bztFzNLw9jXPUZU0959zcvOcilDG0W3/9NZmK" +
        "IeE6WutUaoSTbAIbB63J56GR6TowjCkLAugm7UWkzoY6ePCgVIQ2CxG2owRUk/GZTOZsW1vbUTSZkgWQlqESohhMOIJyudxFSoiWdeRPljOpRBGzEqCX9STm" +
        "ZiXJnZqaOqpt0LQ0g/hBg9L5yHejjUxPzgEi99rVYlNdZvDCpWw2y/l28dlmMxhyCHg7QT85jnP1aVA+Mgm4HHfu3DnKPUFrfvXVlxIMUdUCaIzFoT+KVBLC" +
        "iWkniMtkMsJQsllrRwmoLrRMbW0tvKKdPECqNPCWkvAGv4hJpA0BjbBv3z7H0kh2UTuGvKqc/Xn59A5bYWlHIBFGOwWkg9SWTj5hQwDk5fsUgAw7CcEQaP5X" +
        "XjnotLfvx80ogIl8hrTa7xlfE43Gug26yRBFWFrImicJqPInDQ4OfsLmYczlxYsXxfXQogZ4AO4DFS3uD+eJtm9qahIUkrPJa0cKqOUwBTXf6Xa7z5OmYWnK" +
        "ieYtzK7yMZF0NhPeUgQDXeFwqAuBshA+EuDX9LOtYAoTigofn6FEXmhsEOSUBa9evSK1ddJIVF3YDBw89D179jxTrsvlgpE4yJggSBu6SZ8pm4ntv4LcvrRU" +
        "08/NzeWJ0sfHx48SmXPgckAvjlk3lsXwpMIHgFDC70R/UT6f3xBKx5dWQHUBUM5kMmjAPD4Vvh/mDCAt9W+iYYRUaW2obVMPp6asrcherzfu83k7lPBA56GD" +
        "RKIYoMMC0D4IgsL+iHrJFfJq+qBg0KjVjfDUPpynLVdZoxvfZeh4TO8+rkr5ZmJZum1ouRkZI1kNtPu1a6Z8yrlznYbOvVIrWWLa0fggpyxz8pasHS2gdqxj" +
        "bTKZjKdSqTFQNqRk0HRUcEhDkUp5VLXJSoSqk9IoMYKUKo/0FcqnPKEc+Jt0YyIkkHjhq9F7g/YBI4BQIqTlBGHPs1z2fO3UZEsuIdTpfwKbUP5eODkLhcIp" +
        "rAcanQ369dcmx6lzNQ27dKWQuBGpk1kgywD3k9LwbNXa0QKq2oY6NRyZ8Ja2tLTkESZYPNCgIHMQIAQJ2kJKiUrrqK0Y5b3jNgMgwgg9TmOjcuMvWMqclDxs" +
        "igY8ZNvSfA2/mADnefOGRetLQneIduT/DRWlX0dR2sEVo6dGRkZOADBRk06gxjUDUsEKKCUk5UrFAdASzCZNJpNnt6rq9tIIKEvNYTgcJsl9trl5D/OyhAgM" +
        "MDAPFK3x+utvlHgszWjpUTHbSosDgoeFr2b8ypCwt1l6bxFadRXsz8KVZFuaryp/1DqlsDqIwh9xqbIJZRCWtE7znqGhoRMK9AD9Tl0dsAmIdx2ghbZHW5JR" +
        "ICiC9icej1+zELmrL8IA260/g01s8eVIp9MfLCw09oCrJGAierV0hOIvohl5eGYu6XiJfVmbLNGuym2vf6c0OdDHKOfm8/A3PW3Nz8/HHz58eBEtCN5VAySS" +
        "9r29vUVcFxiilTMVP5PmNjYby5J1yUYiSifHia+Jf5zNZo+gNbeq7+mlFdDyhRatqKhoq66u6uZhIWxoFCJvA9qoFS0yNzfXprSFhgff/L1qQkOg6y9YYZQc" +
        "qk1LCexto0zj7OzsUSo+pIgw9dTI+S4dO4ifSRBo8rCG0JauV92AmHXq6CCn8JVxRSorM9fD4ch/JjOw1XBE52UXUITK4/HAANcNkQBBE4KItuEh4ocRzNB1" +
        "+CKYuGU5zM6BgYEeuiZJEdnBAxaFZIhygcddvXpZ3BL8Yn4PAokAkAmBtbV5QezbgPECJBYbNZxsPdaL8QS2IHCKRKKX6urqOgyn6I8SzRv2iwq0LJOFjzG9" +
        "ZKvPt2iDNQDETBY2lZ/LUvXBFJO7JOAjiue6qCpBCmvmUCWEUIGshG0PEVpJO5JHaGdelE34pPVin90GrPKadm1t7Xm0J9Ul0i48YMwfZtDOflqRVHUz15Lt" +
        "DRodHe2+edPwHLGZqP6Uz1NiYAMWQKd7mBGOBsJHOZeNB+1jIpFY9/aQjVwvnYDqIrpWon/8MCBvROoAJhja0NHREY9EIkfxWdFUWyWow8PD5+/du9dJ2RS/" +
        "k5It5UgyD9oHpNUkMgtoTFwXHTmpU/wikcjpjcZubsR6mQW0EIvFjjFNrr4eAW2REiioIyJhuOkbGhrPUDr0+/1bpnUGBwdFOD///DPn3/7tolSCwGO+9dab" +
        "Uj4l2KGSZOatM9PeVJVisZjUzu1wWmlce9ECoNWsl1ZAdfBYNBptq67Ondi7t1UqRAiAcsfjxzU0NPRg9oGx6STmjVrasAb4hFTSwMCAxWd+J2kjAiU0I2kh" +
        "4ISmSpWT7IPNLhQsG/SnVvM/V0fli7BeWgHV3CiBQnV19QlAHKRpLl++IoRXlAPBkAIMTiQSPaRo3G73E7nU12NZUEc7IGcS7J9//rmYdKJ2fgdOAK1JUQES" +
        "XooBcDaR4rLDGxBIYYzbDNaRzVgvtYDaWaN9BBAEIqDKKf3dvj0n1DP4omYSb5wUTU91dfU7Flj8M3rwtaxyNjvbI98BVG58fLyHJHtvb5+Y9IsXL9qxOqbV" +
        "l6CHXng2U319vetFIaPYyPXSCqguNA25QK/Xe2rfvn0dCAggEWrYCCzmE9MPl/2BAwe6crlcF0NPw+HwMw05KKcxnJmZEeDw2NgYh3wf5pysAkLa12ca4ihD" +
        "YtYBDQPVw7RrBWknCyfrpRdQHjDED9Fo9MjevXuLyuWE5qJMSICCLwjyR0Eki4uLn7hcrnct9WOJOlwXP5cT0C4bBSmAZ4DOaExQ9owup+yKcILPJJVkPs8l" +
        "yXVQUQgnfeh79uyRcuRmN/1t1XrpBbR8geBpbm46aqi4ma/pF3AFBK1UaMBO0vVIFaa+vu68pnDsjHtB4HPgCxL9g25HGBcWFgA5lyi+FdiM4JvBqvcETE0v" +
        "P5kEhI/ovLGxUYQT8DAVLlyRl0k4WbsCWraYy26GdQV70XQIAi3CVG+A6P344/ciNNTth4baBQ3E7Es7szPv9/s5QPGXZnUq2KRcMHEjqJXjRnD09xsBZQMg" +
        "yAA5SLT/+te/tnM8mylX/vdQKPxfn9ZYtxPXroCWLR2/mE6nP96zZ083goBAgFQiaEKoQDhRxYG9xOBHEyVUEzVtcpFQ1CBoZhY9I8bnRThNQ9qUfAaCCm8U" +
        "n6lYUmrm+JxUf0gjHTp0SKtAH1vhXNWIwp20XAQAu+tnqR6hqBkdHT2hkDXIs3QAmJkoslQayU1Fh/IomhTgsNvtEqEz48SNBgUOh1DSa25mz5s5TgivGR2e" +
        "E7NOwQAXAk3d1NSkLb4XXpagaPnaFdCn88fHBwcHx/BBAWjghxJpE0BRbVKacUqMVG9UiLS9VycKG02qvJ6ml0gPtC695xQDYAdhhhCCmk6nz6XT6fe3e6L9" +
        "edeuif+FVpFkMvluMBjsDoVCXeQhMckETqYXyZho7e5EAJUXv7xNWdsyEEiGdtnuUdGcOh8UhBF1ddyGWCwuQ2tdL5m2XGntatA1runp6TyVnqGhoTzRNwdB" +
        "DwILuwd+JtpSk+i6tCWEPibTPQo+s4ac5gU7RRnSiPV+vtt+7QroGpdNFXXNzEz/p0Jh/Df4lUrYYNk9xLTjh9IrpEsZTXS0N0csFuuz/T8inC+7OV9p7Qro" +
        "M6zyxHv5z6tZ5XQ6T6LW2V2P1q5NeYa1K1jOpq3/D9cIFDnsLktAAAAAAElFTkSuQmCC"
}
