//
//  ClaudeIndicators.swift
//  LyricsIsland
//

import AppKit
import ClaudeMonitorKit
import SwiftUI

extension ClaudeSessionState {
    var spinnerColor: Color {
        switch self {
        case .working: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .compacting: return Color(red: 0.55, green: 0.62, blue: 1)
        case .waitingForApproval: return Color(red: 1, green: 0.76, blue: 0.2)
        case .failed: return .red
        case .waitingForInput: return .gray
        }
    }

    var spinnerAnimates: Bool {
        switch self {
        case .working, .compacting, .waitingForApproval: return true
        case .failed, .waitingForInput: return false
        }
    }
}

/// The asterisk that cycles while Claude Code works in a terminal.
///
/// Frames are drawn once and cycled by Core Animation, so running it costs no
/// SwiftUI updates. Redrawing the text instead recomposited the whole notch.
struct ClaudeSpinner: NSViewRepresentable {
    let state: ClaudeSessionState
    var size: CGFloat = 13

    func makeNSView(context: Context) -> SpinnerView {
        SpinnerView()
    }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.configure(color: NSColor(state.spinnerColor), animates: state.spinnerAnimates, size: size)
    }
}

final class SpinnerView: NSView {
    private static let glyphs = ["·", "✢", "✳", "✶", "✻", "✽"]
    private static let sequence = glyphs + glyphs.reversed()
    private static let frameDuration: CFTimeInterval = 0.12
    private static let restingGlyph = "✻"
    private static let animationKey = "spin"

    private var color = NSColor.clear
    private var animates = false
    private var size: CGFloat = 0
    private var scale: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .center
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(size * 1.3), height: ceil(size * 1.3))
    }

    func configure(color: NSColor, animates: Bool, size: CGFloat) {
        guard color != self.color || animates != self.animates || size != self.size else { return }
        let sizeChanged = size != self.size
        self.color = color
        self.animates = animates
        self.size = size
        if sizeChanged { invalidateIntrinsicContentSize() }
        applyAppearance()
    }

    /// Core Animation drops animations when a view leaves its window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyAppearance()
    }

    private func applyAppearance() {
        guard let layer, let window, size > 0 else { return }
        scale = window.backingScaleFactor
        layer.contentsScale = scale
        layer.removeAnimation(forKey: Self.animationKey)
        layer.contents = image(for: Self.restingGlyph)

        guard animates else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = Self.sequence.compactMap { image(for: $0) }
        animation.calculationMode = .discrete
        animation.duration = Self.frameDuration * CFTimeInterval(Self.sequence.count)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.animationKey)
    }

    private func image(for glyph: String) -> CGImage? {
        let text = NSAttributedString(string: glyph, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
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

/// Claude Code's terminal mascot, drawn from the block characters of its banner.
struct ClawdMark: View {
    /// Filled cells per row as inclusive column ranges.
    private static let rows: [[ClosedRange<Int>]] = [
        [2...13],
        [2...3, 5...10, 12...13],
        [0...15],
        [2...13],
        [3...3, 5...5, 10...10, 12...12],
    ]
    private static let columns = 16

    /// Width of one cell. Terminal cells are twice as tall as they are wide.
    var cellWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, _ in
            let color = Color(red: 0.85, green: 0.47, blue: 0.34)
            for (row, runs) in Self.rows.enumerated() {
                for run in runs {
                    let rect = CGRect(
                        x: CGFloat(run.lowerBound) * cellWidth,
                        y: CGFloat(row) * cellWidth * 2,
                        width: CGFloat(run.count) * cellWidth,
                        height: cellWidth * 2
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(Self.columns) * cellWidth, height: CGFloat(Self.rows.count) * cellWidth * 2)
    }
}
