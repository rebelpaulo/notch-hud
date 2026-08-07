import CoreGraphics
import Testing
@testable import NotchHUD

@Test func notchRectUsesAuxiliaryAreaGap() throws {
    let rect = try #require(NotchGeometry.notchRect(
        auxLeftMaxX: 918,
        auxRightMinX: 1138,
        frameMaxY: 1329,
        safeTop: 38
    ))

    #expect(rect == CGRect(x: 918, y: 1291, width: 220, height: 38))
}

@Test func notchRectRequiresBothAuxiliaryAreas() {
    #expect(NotchGeometry.notchRect(
        auxLeftMaxX: nil,
        auxRightMinX: 1138,
        frameMaxY: 1329,
        safeTop: 38
    ) == nil)
    #expect(NotchGeometry.notchRect(
        auxLeftMaxX: 918,
        auxRightMinX: nil,
        frameMaxY: 1329,
        safeTop: 38
    ) == nil)
}

@Test func notchRectRequiresPositiveAuxiliaryGap() {
    #expect(NotchGeometry.notchRect(
        auxLeftMaxX: 918,
        auxRightMinX: 918,
        frameMaxY: 1329,
        safeTop: 38
    ) == nil)
    #expect(NotchGeometry.notchRect(
        auxLeftMaxX: 918,
        auxRightMinX: 900,
        frameMaxY: 1329,
        safeTop: 38
    ) == nil)
}

@Test func borderGeometryExpandsForStrokeAndLeavesTopOpen() {
    let notch = CGRect(x: 918, y: 1291, width: 220, height: 38)
    let border = NotchGeometry.borderRect(from: notch, strokeWidth: 2)
    #expect(border == CGRect(x: 917, y: 1290, width: 222, height: 40))

    let path = NotchGeometry.borderPath(
        in: CGRect(origin: .zero, size: border.size),
        cornerRadius: 10,
        strokeWidth: 2
    )
    #expect(path.boundingBoxOfPath == CGRect(x: 1, y: 1, width: 220, height: 38))
    var elements: [CGPathElementType] = []
    path.applyWithBlock { elements.append($0.pointee.type) }
    #expect(elements == [.moveToPoint, .addLineToPoint, .addQuadCurveToPoint,
                         .addLineToPoint, .addQuadCurveToPoint, .addLineToPoint])
    #expect(elements.contains(.closeSubpath) == false)
}

@Test func compactPillRectUnionsRenderedLeadingAndTrailingExtents() {
    let notch = CGRect(x: 918, y: 1291, width: 220, height: 38)

    let pill = NotchGeometry.compactPillRect(
        from: notch,
        leadingSize: CGSize(width: 92, height: 24),
        trailingSize: CGSize(width: 76, height: 18),
        sideInset: 14
    )

    #expect(pill == CGRect(x: 812, y: 1291, width: 416, height: 38))
    #expect(NotchGeometry.borderRect(from: pill) == CGRect(x: 811, y: 1290, width: 418, height: 40))
}

@Test func compactPillRectFallsBackToPhysicalNotchAtRest() {
    let notch = CGRect(x: 918, y: 1291, width: 220, height: 38)

    #expect(NotchGeometry.compactPillRect(
        from: notch,
        leadingSize: .zero,
        trailingSize: .zero,
        sideInset: 14
    ) == notch)
}

@Test func compactPillRectKeepsBandHeightForTallerRenderedContent() {
    // SwiftUI reports slack taller than the band; the pill never grows past
    // it, so the border must not hang below the rendered black shape.
    let notch = CGRect(x: 918, y: 1291, width: 220, height: 38)

    let pill = NotchGeometry.compactPillRect(
        from: notch,
        leadingSize: CGSize(width: 80, height: 46),
        trailingSize: .zero,
        sideInset: 14
    )

    #expect(pill == CGRect(x: 824, y: 1291, width: 314, height: 38))
    #expect(pill.maxY == notch.maxY)
    #expect(pill.height == notch.height)
}

@Test func hitRectExpandsAroundNotch() {
    let notchRect = CGRect(x: 918, y: 1291, width: 220, height: 38)

    let hitRect = NotchGeometry.hitRect(
        from: notchRect,
        sideMargin: 150,
        bottomExtra: 16
    )

    #expect(hitRect == CGRect(x: 768, y: 1275, width: 520, height: 54))
}

@Test func peekEdgeIsInsideHitRectButOutsideNotchRect() {
    let notchRect = CGRect(x: 918, y: 1291, width: 220, height: 38)
    let hitRect = NotchGeometry.hitRect(
        from: notchRect,
        sideMargin: 150,
        bottomExtra: 16
    )
    let peekEdge = CGPoint(x: 850, y: 1300)

    #expect(notchRect.contains(peekEdge) == false)
    #expect(hitRect.contains(peekEdge) == true)
}

@Test func fallbackRectIsCentered() {
    let rect = NotchGeometry.fallbackRect(
        frameMidX: 720,
        frameMaxY: 900,
        visibleMaxY: 875,
        width: 300
    )

    #expect(rect == CGRect(x: 570, y: 868, width: 300, height: 32))
    #expect(rect.midX == 720)
}

@Test func expandedContentRectCoversTopCenterOnly() {
    let rect = NotchGeometry.expandedContentRect(
        frameMidX: 1028,
        frameMaxY: 1329,
        notchHeight: 38,
        width: 370,
        height: 230
    )

    #expect(rect.contains(CGPoint(x: 1028, y: 1300)))
    #expect(rect.contains(CGPoint(x: 200, y: 200)) == false)
}
