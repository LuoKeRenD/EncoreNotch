//
//  ClawdSprite.swift
//  EncoreNotch
//
//  Animated pixel Clawd for the closed notch. Every frame is drawn once into a
//  bitmap and played back by Core Animation, so animating costs no SwiftUI
//  updates (redrawing in SwiftUI recomposited the whole notch).
//

import AppKit
import SwiftUI

/// How Clawd leaves when a session completes.
enum ClawdProp: Equatable {
    /// Runs across the island and carries the spinner away.
    case asterisk
    /// Takes out the music spectrum, sets it in its slot and leaves.
    case spectrum
    /// Walks to the spinner, swaps it for the music spectrum and carries it away.
    case swap
}

enum ClawdScript: Equatable {
    /// Faces you and types on a laptop whose lid hides his lower body. Loops. Slot sized.
    case typing
    /// Stands and blinks. Loops. Slot sized.
    case idle
    /// Bounces beside a "!". Loops. Slot sized.
    case alert
    /// Walks in from the left edge, then bounces beside a "!". Fills the given width.
    case enterThenAlert
    /// Jumps, waves and leaves. `.spectrum` is slot sized; the others fill the given width.
    case celebrate(ClawdProp)

    /// Canvas width in pixel units: Clawd's 16 plus one for a waving arm. The
    /// same for every script, and narrow enough to sit in the music spectrum's
    /// slot, so Clawd is the same size on either side of the island.
    var slotColumns: Int { 17 }

    static let rows = 16
}

enum ClawdTiming {
    static let jumpFrame: TimeInterval = 0.08
    static let jump = jumpFrame * 7
    static let land: TimeInterval = 0.1
    static let waveFrame: TimeInterval = 0.15
    static let wave = waveFrame * 6
    static var greeting: TimeInterval { jump + land + wave }

    /// Taking the spectrum out and holding it up.
    static let pullOut: TimeInterval = 0.45
    static let walkOffSlot: TimeInterval = 1.0

    /// Turning round to set the spectrum down behind him, then turning back.
    static let turn: TimeInterval = 0.15
    static let backHold: TimeInterval = 0.1
    static let setDown: TimeInterval = 0.3
    static var placeBehind: TimeInterval { turn + backHold + setDown + turn }
    /// From the start of turning round until the spectrum is down.
    static var placedAfter: TimeInterval { turn + backHold }

    /// Walking across without stopping.
    static let crossing: TimeInterval = 1.6

    /// Walking to the spinner, picking it up, putting the spectrum back and leaving.
    static let walkToSlot: TimeInterval = 0.9
    static let grab: TimeInterval = 0.25
    static let swapPullOut: TimeInterval = 0.3
    static let walkOffSwap: TimeInterval = 0.5

    /// How long the island shows a completed session. Every celebration fits inside it.
    static let celebration: TimeInterval = 4.3

    /// When the real spectrum takes its place in the slot, if Clawd puts one there.
    static func spectrumAppears(for prop: ClawdProp) -> TimeInterval? {
        switch prop {
        case .spectrum: return greeting + pullOut + placedAfter
        case .swap: return greeting + walkToSlot + grab + swapPullOut + placedAfter
        case .asterisk: return nil
        }
    }

    /// Pixel size that keeps Clawd crisp and inside a closed notch row of `rowHeight`.
    static func unit(forRowHeight rowHeight: CGFloat) -> CGFloat {
        rowHeight >= 26 ? 1.5 : 1
    }
}

struct ClawdSprite: NSViewRepresentable {
    let script: ClawdScript
    let unit: CGFloat
    /// For whole-island scripts: the width of the right slot holding the spinner.
    var slotWidth: CGFloat = 0

    func makeNSView(context: Context) -> ClawdSpriteView {
        ClawdSpriteView()
    }

    func updateNSView(_ view: ClawdSpriteView, context: Context) {
        view.configure(script: script, unit: unit, slotWidth: slotWidth)
    }
}

// MARK: - Drawing

private let clawdOrange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
private let bangYellow = NSColor(red: 1, green: 0.76, blue: 0.2, alpha: 1)

private struct Px {
    let x, y, w, h: Int
    let color: NSColor
}

private enum ArmPose { case side, up, wave, low }
private enum Facing { case front, turning, back }
private enum LegPose { case stand, walkA, walkB, tuck }

/// Clawd facing front: 16 by 10 units, the terminal banner's 16 by 5 cells
/// with each cell two units tall. A raised arm reaches above the head.
private struct ClawdPose {
    var x = 0
    var y = 6
    var left: ArmPose = .side
    var right: ArmPose = .side
    var legs: LegPose = .stand
    var blink = false
    var facing: Facing = .front

    func pixels() -> [Px] {
        let c = clawdOrange
        var px: [Px] = [Px(x: x + 2, y: y, w: 12, h: 2, color: c)]
        if blink || facing == .back {
            px.append(Px(x: x + 2, y: y + 2, w: 12, h: 2, color: c))
        } else if facing == .turning {
            // Half turned, so both eyes have moved toward one side.
            px += [
                Px(x: x + 2, y: y + 2, w: 6, h: 2, color: c),
                Px(x: x + 9, y: y + 2, w: 3, h: 2, color: c),
                Px(x: x + 13, y: y + 2, w: 1, h: 2, color: c),
            ]
        } else {
            px += [
                Px(x: x + 2, y: y + 2, w: 2, h: 2, color: c),
                Px(x: x + 5, y: y + 2, w: 6, h: 2, color: c),
                Px(x: x + 12, y: y + 2, w: 2, h: 2, color: c),
            ]
        }
        px.append(Px(x: x + 2, y: y + 4, w: 12, h: 4, color: c))
        px += arm(left, column: x, mirrored: true)
        px += arm(right, column: x + 14, mirrored: false)
        px += legPixels(legs, x: x, y: y + 8, columns: [3, 5, 10, 12])
        return px
    }

    private func arm(_ pose: ArmPose, column: Int, mirrored: Bool) -> [Px] {
        let c = clawdOrange
        switch pose {
        case .side: return [Px(x: column, y: y + 4, w: 2, h: 2, color: c)]
        case .up: return [Px(x: column, y: y - 1, w: 2, h: 5, color: c)]
        case .wave:
            // Tilted outward, with an elbow joining it to the shoulder.
            return [
                Px(x: mirrored ? column + 1 : column, y: y + 3, w: 1, h: 3, color: c),
                Px(x: mirrored ? column - 1 : column + 1, y: y - 2, w: 2, h: 5, color: c),
            ]
        case .low: return [Px(x: column, y: y + 6, w: 2, h: 2, color: c)]
        }
    }
}

private func legPixels(_ legs: LegPose, x: Int, y: Int, columns: [Int]) -> [Px] {
    columns.enumerated().map { index, column in
        let height: Int
        switch legs {
        case .stand: height = 2
        case .tuck: height = 1
        case .walkA: height = index.isMultiple(of: 2) ? 2 : 1
        case .walkB: height = index.isMultiple(of: 2) ? 1 : 2
        }
        return Px(x: x + column, y: y, w: 1, h: height, color: clawdOrange)
    }
}

/// Clawd facing you, typing on a keyboard that hides his lower body. The
/// strip along the bottom is the laptop's screen; his hands tap in turn and
/// the key under the lowered one lights up.
private func typingPixels(frame: Int, blink: Bool) -> [Px] {
    let c = clawdOrange
    let y = 6
    var px: [Px] = [Px(x: 2, y: y, w: 12, h: 2, color: c)]
    if blink {
        px.append(Px(x: 2, y: y + 2, w: 12, h: 2, color: c))
    } else {
        px += [
            Px(x: 2, y: y + 2, w: 2, h: 2, color: c),
            Px(x: 5, y: y + 2, w: 6, h: 2, color: c),
            Px(x: 12, y: y + 2, w: 2, h: 2, color: c),
        ]
    }
    px.append(Px(x: 2, y: y + 4, w: 12, h: 2, color: c))

    let leftDown = frame.isMultiple(of: 2)

    // The keyboard: keys in staggered rows over a lighter deck, and a space bar.
    let key = NSColor(white: 0.4, alpha: 1)
    px.append(Px(x: 1, y: 12, w: 14, h: 3, color: NSColor(white: 0.66, alpha: 1)))
    for column in stride(from: 2, through: 13, by: 2) {
        px.append(Px(x: column, y: 12, w: 1, h: 1, color: key))
    }
    for column in stride(from: 3, through: 12, by: 2) {
        px.append(Px(x: column, y: 13, w: 1, h: 1, color: key))
    }
    px.append(Px(x: 5, y: 14, w: 6, h: 1, color: key))
    px.append(Px(x: leftDown ? 3 : 12, y: 13, w: 1, h: 1, color: .white))

    // The screen, glowing a little as text scrolls by.
    px.append(Px(x: 0, y: 15, w: 16, h: 1, color: NSColor(white: 0.22, alpha: 1)))
    let glow = NSColor(red: 0.45, green: 0.75, blue: 1, alpha: 0.85)
    px.append(Px(x: 2 + (frame * 3) % 9, y: 15, w: 3, h: 1, color: glow))

    // Arms reach forward over the keys; one hand is down while the other lifts.
    px += [
        Px(x: 0, y: y + 4, w: 2, h: 2, color: c),
        Px(x: 14, y: y + 4, w: 2, h: 2, color: c),
        Px(x: 2, y: leftDown ? 12 : 11, w: 2, h: 1, color: c),
        Px(x: 12, y: leftDown ? 11 : 12, w: 2, h: 1, color: c),
    ]
    return px
}

private enum Props {
    static func bang(x: Int, y: Int, bright: Bool) -> [Px] {
        let color = bright ? bangYellow : bangYellow.blended(withFraction: 0.3, of: clawdOrange) ?? bangYellow
        return [
            Px(x: x, y: y, w: 2, h: 3, color: color),
            Px(x: x, y: y + 4, w: 2, h: 1, color: color),
        ]
    }

    /// Four bars, bottoms aligned at `y + 6`.
    static func spectrum(x: Int, y: Int, phase: Int) -> [Px] {
        let heights = [[3, 6, 2, 4], [5, 3, 6, 2], [2, 5, 4, 6]][phase % 3]
        return heights.enumerated().map { index, height in
            Px(x: x + index * 2, y: y + 6 - height, w: 1, h: height, color: NSColor(white: 0.9, alpha: 1))
        }
    }
}

private struct FrameRenderer {
    let unit: CGFloat
    let scale: CGFloat

    func image(_ pixels: [Px], columns: Int, rows: Int = ClawdScript.rows) -> CGImage? {
        let pointsPerUnit = unit * scale
        let width = Int((CGFloat(columns) * pointsPerUnit).rounded(.up))
        let height = Int((CGFloat(rows) * pointsPerUnit).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setShouldAntialias(false)
        for px in pixels {
            context.setFillColor(px.color.cgColor)
            context.fill(CGRect(
                x: CGFloat(px.x) * pointsPerUnit,
                y: CGFloat(rows - px.y - px.h) * pointsPerUnit,
                width: CGFloat(px.w) * pointsPerUnit,
                height: CGFloat(px.h) * pointsPerUnit
            ))
        }
        return context.makeImage()
    }

    func asterisk(size: CGFloat) -> CGImage? {
        let text = NSAttributedString(string: "✻", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: clawdOrange,
        ])
        let side = ceil(size * 1.3)
        let measured = text.size()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            text.draw(at: NSPoint(x: (side - measured.width) / 2, y: (side - measured.height) / 2))
            return true
        }
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        let hints: [NSImageRep.HintKey: Any] = [
            .ctm: NSAffineTransform(transform: AffineTransform(scaleByX: scale, byY: scale)),
        ]
        return image.cgImage(forProposedRect: &rect, context: nil, hints: hints)
    }
}

// MARK: - Timeline

/// Keyframes for one layer property over a script's one-shot duration.
private struct Track<Value> {
    var times: [TimeInterval] = []
    var values: [Value] = []

    mutating func add(_ value: Value, at time: TimeInterval) {
        times.append(time)
        values.append(value)
    }

    func animation(keyPath: String, duration: TimeInterval, discrete: Bool) -> CAKeyframeAnimation? {
        guard !values.isEmpty, duration > 0 else { return nil }
        var times = times
        var values = values
        if times.first! > 0 {
            times.insert(0, at: 0)
            values.insert(values[0], at: 0)
        }
        var keyTimes = times.map { NSNumber(value: min(1, $0 / duration)) }
        if discrete {
            // Discrete keyframes take one more key time than values; the last ends the final value.
            keyTimes.append(1)
        } else if times.last! < duration {
            values.append(values.last!)
            keyTimes.append(1)
        }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = discrete ? .discrete : .linear
        animation.duration = duration
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }
}

/// Piecewise-linear horizontal movement, so a carried prop can follow Clawd.
private struct Path1D {
    private(set) var keys: [(time: TimeInterval, x: CGFloat)] = []

    mutating func add(_ x: CGFloat, at time: TimeInterval) {
        keys.append((time, x))
    }

    func x(at time: TimeInterval) -> CGFloat {
        guard let first = keys.first else { return 0 }
        if time <= first.time { return first.x }
        for (a, b) in zip(keys, keys.dropFirst()) where time <= b.time {
            guard b.time > a.time else { return b.x }
            return a.x + (b.x - a.x) * CGFloat((time - a.time) / (b.time - a.time))
        }
        return keys.last!.x
    }
}

// MARK: - View

final class ClawdSpriteView: NSView {
    private var script: ClawdScript?
    private var unit: CGFloat = 0
    private var slotWidth: CGFloat = 0
    private var playedSize: CGSize = .zero
    private var playedScale: CGFloat = 0

    private let sprite = CALayer()
    private let prop = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for sublayer in [sprite, prop] {
            sublayer.anchorPoint = .zero
            sublayer.contentsGravity = .resize
            sublayer.magnificationFilter = .nearest
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(script: ClawdScript, unit: CGFloat, slotWidth: CGFloat) {
        guard script != self.script || unit != self.unit || slotWidth != self.slotWidth else { return }
        self.script = script
        self.unit = unit
        self.slotWidth = slotWidth
        play()
    }

    override func layout() {
        super.layout()
        if bounds.size != playedSize { play() }
    }

    /// Core Animation drops animations when a view leaves its window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        play()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if window?.backingScaleFactor != playedScale { play() }
    }

    private func play() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        sprite.removeAllAnimations()
        prop.removeAllAnimations()
        sprite.contents = nil
        prop.contents = nil
        sprite.opacity = 1
        prop.opacity = 1

        guard let script, let window, unit > 0, bounds.width > 0 else { return }
        playedSize = bounds.size
        playedScale = window.backingScaleFactor
        let renderer = FrameRenderer(unit: unit, scale: playedScale)
        for sublayer in [sprite, prop] { sublayer.contentsScale = playedScale }

        switch script {
        case .typing: playTyping(renderer)
        case .idle: playIdle(renderer)
        case .alert: playAlert(renderer, columns: script.slotColumns)
        case .enterThenAlert: playEnterThenAlert(renderer)
        case .celebrate(let prop): playCelebration(renderer, prop: prop)
        }
    }

    private var rowsHeight: CGFloat { CGFloat(ClawdScript.rows) * unit }

    private func placeSprite(columns: Int, x: CGFloat) {
        sprite.frame = CGRect(x: x, y: (bounds.height - rowsHeight) / 2, width: CGFloat(columns) * unit, height: rowsHeight)
    }

    private func loop(_ layer: CALayer, frames: [CGImage?], each: TimeInterval, beginTime: CFTimeInterval = 0) {
        let images = frames.compactMap { $0 }
        guard let first = images.first else { return }
        if beginTime == 0 { layer.contents = first }
        guard images.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images
        animation.calculationMode = .discrete
        animation.duration = each * TimeInterval(images.count)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        if beginTime > 0 { animation.beginTime = beginTime }
        layer.add(animation, forKey: "loop")
    }

    private func add(_ animation: CAKeyframeAnimation?, to layer: CALayer, key: String, begin: CFTimeInterval) {
        guard let animation else { return }
        animation.beginTime = begin
        layer.add(animation, forKey: key)
    }

    // MARK: Loops

    private func playTyping(_ renderer: FrameRenderer) {
        let columns = ClawdScript.typing.slotColumns
        placeSprite(columns: columns, x: 0)
        let frames = (0..<12).map { index in
            renderer.image(typingPixels(frame: index, blink: index == 9), columns: columns)
        }
        loop(sprite, frames: frames, each: 0.13)
    }

    private func playIdle(_ renderer: FrameRenderer) {
        let columns = ClawdScript.idle.slotColumns
        placeSprite(columns: columns, x: 0)
        let frames = (0..<12).map { index -> CGImage? in
            var pose = ClawdPose()
            pose.blink = index == 8
            return renderer.image(pose.pixels(), columns: columns)
        }
        loop(sprite, frames: frames, each: 0.2)
    }

    private static let bounceHeights = [0, -1, -3, -4, -3, -1, 0, 0]

    private func alertFrames(_ renderer: FrameRenderer, columns: Int) -> [CGImage?] {
        Self.bounceHeights.enumerated().map { index, dy in
            var pose = ClawdPose()
            pose.y = 6 + dy
            pose.legs = dy < 0 ? .tuck : .stand
            // The "!" pops above his right shoulder, so his arms stay down.
            let pixels = pose.pixels() + Props.bang(x: 15, y: dy <= -3 ? 0 : 1, bright: index < 4)
            return renderer.image(pixels, columns: columns)
        }
    }

    private func playAlert(_ renderer: FrameRenderer, columns: Int) {
        placeSprite(columns: columns, x: 0)
        loop(sprite, frames: alertFrames(renderer, columns: columns), each: 0.08)
    }

    // MARK: One-shots

    private func walkFrames(_ renderer: FrameRenderer, columns: Int, right: ArmPose = .side) -> [CGImage] {
        [LegPose.walkA, .stand, .walkB, .stand].compactMap { legs in
            var pose = ClawdPose()
            pose.legs = legs
            pose.right = right
            pose.y = legs == .stand ? 6 : 5
            return renderer.image(pose.pixels(), columns: columns)
        }
    }

    private func playEnterThenAlert(_ renderer: FrameRenderer) {
        let columns = ClawdScript.enterThenAlert.slotColumns
        let walkDuration: TimeInterval = 0.7
        placeSprite(columns: columns, x: 0)

        var contents = Track<CGImage>()
        let walk = walkFrames(renderer, columns: columns)
        var time: TimeInterval = 0
        var step = 0
        while time < walkDuration {
            contents.add(walk[step % walk.count], at: time)
            time += 0.1
            step += 1
        }
        var position = Track<NSValue>()
        position.add(NSValue(point: CGPoint(x: -CGFloat(columns) * unit, y: sprite.frame.minY)), at: 0)
        position.add(NSValue(point: sprite.frame.origin), at: walkDuration)

        let begin = sprite.convertTime(CACurrentMediaTime(), from: nil)
        add(contents.animation(keyPath: "contents", duration: walkDuration, discrete: true), to: sprite, key: "contents", begin: begin)
        add(position.animation(keyPath: "position", duration: walkDuration, discrete: false), to: sprite, key: "position", begin: begin)
        loop(sprite, frames: alertFrames(renderer, columns: columns), each: 0.08, beginTime: begin + walkDuration)
    }

    private func playCelebration(_ renderer: FrameRenderer, prop kind: ClawdProp) {
        let columns = ClawdScript.celebrate(kind).slotColumns
        placeSprite(columns: columns, x: 0)
        let baseY = sprite.frame.minY
        let exitX = bounds.width + 4 * unit

        var contents = Track<CGImage>()
        var path = Path1D()
        var time: TimeInterval = 0

        func show(_ pose: ClawdPose, extra: [Px] = [], for duration: TimeInterval) {
            if let image = renderer.image(pose.pixels() + extra, columns: columns) {
                contents.add(image, at: time)
            }
            time += duration
        }

        func walk(to x: CGFloat, over duration: TimeInterval, carrying: Bool) {
            let frames = walkFrames(renderer, columns: columns, right: carrying ? .up : .side)
            path.add(path.x(at: time), at: time)
            let end = time + duration
            var step = 0
            while time < end - 0.001 {
                contents.add(frames[step % frames.count], at: time)
                time += 0.1
                step += 1
            }
            time = end
            path.add(x, at: end)
        }

        path.add(0, at: 0)

        // Jump.
        for dy in [0, -2, -4, -5, -4, -2, 0] {
            var pose = ClawdPose()
            pose.y = 6 + dy
            pose.legs = dy < 0 ? .tuck : .stand
            pose.left = dy <= -4 ? .up : .side
            pose.right = dy <= -4 ? .up : .side
            show(pose, for: ClawdTiming.jumpFrame)
        }
        show(ClawdPose(), for: ClawdTiming.land)

        // Wave.
        for index in 0..<6 {
            var pose = ClawdPose()
            pose.right = index.isMultiple(of: 2) ? .up : .wave
            pose.blink = index == 3
            show(pose, for: ClawdTiming.waveFrame)
        }

        /// Turns round, sets the held spectrum down behind him, and turns back.
        /// While carrying the spinner his right hand stays up holding it.
        func placeBehind(carryingSpinner: Bool, held: [Px]) {
            var turning = ClawdPose()
            turning.facing = .turning
            turning.left = .up
            turning.right = .up
            show(turning, extra: held, for: ClawdTiming.turn)
            var back = ClawdPose()
            back.facing = .back
            back.left = .up
            back.right = .up
            show(back, extra: held, for: ClawdTiming.backHold)
            back.left = .low
            back.right = carryingSpinner ? .up : .low
            show(back, for: ClawdTiming.setDown)
            var returning = ClawdPose()
            returning.facing = .turning
            returning.right = carryingSpinner ? .up : .side
            show(returning, for: ClawdTiming.turn)
        }

        // The spinner Clawd picks up, sitting in the right slot.
        var grabAt: TimeInterval?
        var asteriskOrigin = CGPoint.zero
        let handOffset = 13 * unit
        if kind != .spectrum, let image = renderer.asterisk(size: 15) {
            let side = ceil(15 * 1.3)
            let center = bounds.width - max(slotWidth, side) / 2
            asteriskOrigin = CGPoint(x: center - side / 2, y: (bounds.height - side) / 2)
            prop.frame = CGRect(origin: asteriskOrigin, size: CGSize(width: side, height: side))
            prop.contents = image
        }

        switch kind {
        case .spectrum:
            // Takes the spectrum out and holds it up, then sets it down in the
            // slot behind him, where the real one appears.
            for phase in 0..<3 {
                var pose = ClawdPose()
                pose.left = .up
                pose.right = .up
                show(pose, extra: Props.spectrum(x: 5, y: 0, phase: phase), for: ClawdTiming.pullOut / 3)
            }
            placeBehind(carryingSpinner: false, held: Props.spectrum(x: 5, y: 0, phase: 0))
            walk(to: exitX, over: ClawdTiming.walkOffSlot, carrying: false)

        case .asterisk:
            let reach = asteriskOrigin.x - handOffset
            let start = time
            walk(to: exitX, over: ClawdTiming.crossing, carrying: false)
            grabAt = start + ClawdTiming.crossing * TimeInterval(max(0, min(1, reach / exitX)))
            // Walking frames switch to carrying once Clawd has it.
            rebuildWalk(&contents, from: grabAt!, to: time, renderer: renderer, columns: columns)

        case .swap:
            // Stands in front of the slot, picks the spinner up, then puts the
            // spectrum back behind him and leaves carrying the spinner.
            let slotCenter = asteriskOrigin.x + prop.frame.width / 2
            let stop = max(0, slotCenter - 8 * unit)
            walk(to: stop, over: ClawdTiming.walkToSlot, carrying: false)
            grabAt = time + 0.05
            var holding = ClawdPose()
            holding.right = .up
            show(holding, for: ClawdTiming.grab)
            holding.left = .up
            show(holding, extra: Props.spectrum(x: 0, y: 0, phase: 1), for: ClawdTiming.swapPullOut)
            placeBehind(carryingSpinner: true, held: Props.spectrum(x: 0, y: 0, phase: 1))
            path.add(stop, at: time)
            walk(to: exitX, over: ClawdTiming.walkOffSwap, carrying: true)
        }

        let walkEnd = time
        let duration = ClawdTiming.celebration
        var position = Track<NSValue>()
        for key in path.keys {
            position.add(NSValue(point: CGPoint(x: key.x, y: baseY)), at: key.time)
        }
        var opacity = Track<NSNumber>()
        opacity.add(1, at: 0)
        opacity.add(0, at: walkEnd)

        let begin = sprite.convertTime(CACurrentMediaTime(), from: nil)
        add(contents.animation(keyPath: "contents", duration: duration, discrete: true), to: sprite, key: "contents", begin: begin)
        add(position.animation(keyPath: "position", duration: duration, discrete: false), to: sprite, key: "position", begin: begin)
        add(opacity.animation(keyPath: "opacity", duration: duration, discrete: true), to: sprite, key: "opacity", begin: begin)

        if let grabAt {
            // Held above the raised hand from the moment Clawd reaches it.
            let carriedY = baseY + rowsHeight - prop.frame.height + 3 * unit
            let carriedX = handOffset - 3 * unit
            var propPosition = Track<NSValue>()
            propPosition.add(NSValue(point: asteriskOrigin), at: 0)
            propPosition.add(NSValue(point: asteriskOrigin), at: grabAt)
            let lift = min(grabAt + 0.05, walkEnd)
            propPosition.add(NSValue(point: CGPoint(x: path.x(at: lift) + carriedX, y: carriedY)), at: lift)
            for key in path.keys where key.time > lift {
                propPosition.add(NSValue(point: CGPoint(x: key.x + carriedX, y: carriedY)), at: key.time)
            }
            add(propPosition.animation(keyPath: "position", duration: duration, discrete: false), to: prop, key: "position", begin: begin)
            add(opacity.animation(keyPath: "opacity", duration: duration, discrete: true), to: prop, key: "opacity", begin: begin)
        }
    }

    /// Replaces walking frames from `start` on with ones holding the spinner up.
    private func rebuildWalk(_ contents: inout Track<CGImage>, from start: TimeInterval, to end: TimeInterval, renderer: FrameRenderer, columns: Int) {
        let carrying = walkFrames(renderer, columns: columns, right: .up)
        for index in contents.times.indices where contents.times[index] >= start && contents.times[index] < end {
            contents.values[index] = carrying[index % carrying.count]
        }
    }
}
