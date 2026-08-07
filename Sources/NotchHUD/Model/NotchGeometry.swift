import CoreGraphics

enum NotchGeometry {
    /// Bounds of the compact DynamicNotch pill, including the physical cutout.
    /// Leading/trailing content is top-aligned with the cutout and extends away
    /// from its corresponding edge. `sideInset` accounts for the compact
    /// container's padding outside each rendered content view.
    static func compactPillRect(
        from notchRect: CGRect,
        leadingSize: CGSize,
        trailingSize: CGSize,
        sideInset: CGFloat
    ) -> CGRect {
        var result = notchRect

        // The compact HUD never grows past the notch band, so the reported
        // content height (which includes SwiftUI's own slack) must not stretch
        // the border downwards.
        let height = notchRect.height

        if leadingSize.width > 0, leadingSize.height > 0 {
            result = result.union(CGRect(
                x: notchRect.minX - leadingSize.width - sideInset,
                y: notchRect.maxY - height,
                width: leadingSize.width + sideInset,
                height: height
            ))
        }

        if trailingSize.width > 0, trailingSize.height > 0 {
            result = result.union(CGRect(
                x: notchRect.maxX,
                y: notchRect.maxY - height,
                width: trailingSize.width + sideInset,
                height: height
            ))
        }

        return result
    }

    static func borderRect(from notchRect: CGRect, strokeWidth: CGFloat = 2) -> CGRect {
        notchRect.insetBy(dx: -(strokeWidth / 2), dy: -(strokeWidth / 2))
    }

    /// Open path tracing the two sides and rounded bottom of a notch cutout.
    /// The top edge is intentionally omitted because it sits beyond the display.
    static func borderPath(
        in rect: CGRect,
        cornerRadius: CGFloat,
        strokeWidth: CGFloat = 2
    ) -> CGPath {
        let inset = max(0, strokeWidth / 2)
        let bounds = rect.insetBy(dx: inset, dy: inset)
        let radius = max(0, min(cornerRadius, min(bounds.width, bounds.height) / 2))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX + radius, y: bounds.minY),
            control: CGPoint(x: bounds.minX, y: bounds.minY)
        )
        path.addLine(to: CGPoint(x: bounds.maxX - radius, y: bounds.minY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX, y: bounds.minY + radius),
            control: CGPoint(x: bounds.maxX, y: bounds.minY)
        )
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        return path
    }

    /// The physical notch cutout rect from a screen's auxiliary areas.
    /// Returns nil when there is no notch (no valid aux gap).
    static func notchRect(
        auxLeftMaxX: CGFloat?,
        auxRightMinX: CGFloat?,
        frameMaxY: CGFloat,
        safeTop: CGFloat
    ) -> CGRect? {
        guard
            let auxLeftMaxX,
            let auxRightMinX,
            auxRightMinX > auxLeftMaxX
        else {
            return nil
        }

        return CGRect(
            x: auxLeftMaxX,
            y: frameMaxY - safeTop,
            width: auxRightMinX - auxLeftMaxX,
            height: safeTop
        )
    }

    /// Widened trigger zone covering the visible peek beside the cutout.
    static func hitRect(
        from notchRect: CGRect,
        sideMargin: CGFloat,
        bottomExtra: CGFloat
    ) -> CGRect {
        CGRect(
            x: notchRect.minX - sideMargin,
            y: notchRect.minY - bottomExtra,
            width: notchRect.width + (sideMargin * 2),
            height: notchRect.height + bottomExtra
        )
    }

    /// Fallback centered rect when there is no notch.
    static func fallbackRect(
        frameMidX: CGFloat,
        frameMaxY: CGFloat,
        visibleMaxY: CGFloat,
        width: CGFloat
    ) -> CGRect {
        let height = max(frameMaxY - visibleMaxY, 32)
        return CGRect(
            x: frameMidX - (width / 2),
            y: frameMaxY - height,
            width: width,
            height: height
        )
    }

    /// Expanded-content hit region (for keeping the panel open while the pointer is over it).
    static func expandedContentRect(
        frameMidX: CGFloat,
        frameMaxY: CGFloat,
        notchHeight: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let totalHeight = height + notchHeight
        return CGRect(
            x: frameMidX - (width / 2),
            y: frameMaxY - totalHeight,
            width: width,
            height: totalHeight
        )
    }
}
