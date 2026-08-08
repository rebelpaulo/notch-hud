import SwiftUI

struct AgentSprite: View {
    let status: DisplayStatus
    var size: CGFloat = 18
    /// Identity color (agent), animation stays status-driven. nil = status color.
    var tint: Color?

    private static let frames: [[UInt8]] = [
        [
            0b00111100,
            0b01111110,
            0b11011011,
            0b11111111,
            0b01111110,
            0b00111100,
            0b00100100,
            0b01000010
        ],
        [
            0b00000000,
            0b00111100,
            0b01111110,
            0b11011011,
            0b11111111,
            0b01111110,
            0b00100100,
            0b01000010
        ]
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 1.2) % 2
            Canvas(rendersAsynchronously: false) { graphicsContext, canvasSize in
                let pixelWidth = canvasSize.width / 8
                let pixelHeight = canvasSize.height / 8
                let frame = Self.frames[status == .working ? phase : 0]
                let opacity = status == .needsMe && phase == 1 ? 0.55 : 1.0

                for (rowIndex, row) in frame.enumerated() {
                    for column in 0..<8 where row & (1 << (7 - column)) != 0 {
                        let rect = CGRect(
                            x: CGFloat(column) * pixelWidth,
                            y: CGFloat(rowIndex) * pixelHeight,
                            width: pixelWidth,
                            height: pixelHeight
                        )
                        graphicsContext.fill(
                            Path(rect),
                            with: .color((tint ?? status.color).opacity(opacity))
                        )
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(status.label) agent"))
    }
}
