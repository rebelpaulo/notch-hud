import AppKit
import SwiftUI

extension UsageProviderKind {
    /// One place for the palette, so re-tinting a provider later is a
    /// one-line edit instead of a grep across every view that draws a chip.
    /// Both are deliberately deeper than the stock system colors — pure
    /// `.systemOrange`/`.systemBlue` glow on `Color.notchBackground` and lose
    /// legibility against the fill's low-opacity track; these shades hold
    /// contrast at 6pt of height.
    var tint: Color {
        switch self {
        case .claude:
            // Claude's own brand terracotta, muted a touch further for a
            // black panel rather than a white marketing page.
            Color(red: 0.80, green: 0.44, blue: 0.31)
        case .codex:
            // A cobalt blue rather than iOS system blue's cyan lean, which
            // washed out next to the orange at small sizes.
            Color(red: 0.32, green: 0.52, blue: 0.92)
        }
    }
}

/// A single quota bar, drawn as one `Canvas` pass rather than stacked
/// capsules — the pace marker has to punch a transparent notch through both
/// the track and the fill wherever it lands, which only a shared drawing
/// pass can do cleanly.
struct UsageGauge: View {
    /// 0...100.
    let percentUsed: Double
    /// nil draws a plain bar with no marker — the pace engine hasn't
    /// produced an answer yet (not enough history, or none was handed in).
    let pace: UsagePace?
    let tint: Color
    let accessibilityLabel: String
    let accessibilityValue: String

    private let height: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let radius = size.height / 2
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)

            context.fill(track, with: .color(tint.opacity(0.22)))

            var filled = context
            filled.clip(to: track)

            let fillWidth = size.width * CGFloat(min(max(percentUsed, 0), 100)) / 100
            filled.fill(Path(CGRect(x: 0, y: 0, width: fillWidth, height: size.height)), with: .color(tint))

            // THE POINT OF THIS WIDGET: a marker at the percent the window
            // *should* be at by now if usage were spread evenly, so "84% used"
            // reads instantly as "ahead of" or "behind" that line rather than
            // as a bare number the user has to do math on. Red = burning
            // faster than the window allows, green = at or under pace.
            if let pace {
                let markerX = size.width * CGFloat(min(max(pace.expectedPercent, 0), 100)) / 100
                let markerColor: Color = pace.deltaPercent > 0
                    ? Color(nsColor: .systemRed)
                    : Color(nsColor: .systemGreen)

                // Punch a fully transparent 4pt gap (true alpha, via .clear
                // blend — not a background-colored rect) so the marker reads
                // against fill, track, or the panel behind either. Then draw
                // the 2pt stripe centered in it, leaving a 1pt transparent
                // halo on each side as specified.
                var punch = filled
                punch.blendMode = .clear
                punch.fill(
                    Path(CGRect(x: markerX - 2, y: 0, width: 4, height: size.height)),
                    with: .color(.black)
                )
                filled.fill(
                    Path(CGRect(x: markerX - 1, y: 0, width: 2, height: size.height)),
                    with: .color(markerColor)
                )
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(accessibilityValue))
    }
}
