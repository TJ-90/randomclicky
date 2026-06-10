//
//  ScreenCoordinateConverter.swift
//  leanring-buddy
//
//  Centralises all coordinate-space conversions used by the pointing pipeline.
//  There are three coordinate spaces in play on macOS:
//
//  1. Screenshot pixels  – top-left origin, integer pixels. Claude's pointing
//                          coordinates live here (e.g. (640, 400) in a 1280×800 image).
//  2. AppKit global      – bottom-left origin of the PRIMARY display, floating-point
//                          points. NSScreen.frame, NSEvent.mouseLocation, and the
//                          overlay's BlueCursorView all live here.
//  3. CG global          – top-left origin of the PRIMARY display, floating-point
//                          points. AXUIElement position/size and CGEvent coordinates
//                          live here.
//
//  The converter functions are pure static functions — they accept all inputs as
//  parameters so they contain no NSScreen / CGDisplay side effects and can be called
//  from any thread and tested without a display attached.
//
//  Naming follows the codebase's clarity-first convention: every parameter name
//  describes exactly what coordinate space and unit the value is in.
//

import CoreGraphics

enum ScreenCoordinateConverter {

    // MARK: - Screenshot pixels → AppKit global

    /// Converts a point expressed in screenshot-pixel space (top-left origin,
    /// pixel units as Claude emits in [POINT:x,y:…] tags) to a global AppKit
    /// point (bottom-left origin of the primary display, point units) that the
    /// overlay's BlueCursorView can use directly.
    ///
    /// Why clamping: Claude's coordinate estimate can land slightly outside the
    /// image bounds due to model imprecision; clamping keeps the cursor on-screen
    /// rather than flying off to a display edge.
    ///
    /// Why the Y flip happens BEFORE adding displayFrame.origin: the screenshot
    /// is captured in display-local space, so the flip must be relative to the
    /// display's own height before the display's AppKit origin is added.
    ///
    /// - Parameters:
    ///   - screenshotPixelPoint: The (x, y) coordinate Claude produced, in the
    ///     screenshot's pixel space (top-left origin).
    ///   - screenshotWidthInPixels: The pixel width of the screenshot image.
    ///   - screenshotHeightInPixels: The pixel height of the screenshot image.
    ///   - displayWidthInPoints: The display's logical point width (from NSScreen.frame).
    ///   - displayHeightInPoints: The display's logical point height (from NSScreen.frame).
    ///   - displayFrameInAppKitCoordinates: The NSScreen.frame for the target display,
    ///     which gives both the display's size and its origin in AppKit global space.
    ///     Must be in AppKit coordinates (bottom-left origin) — NOT SCDisplay.frame.
    /// - Returns: The corresponding point in AppKit global coordinates.
    static func convertScreenshotPixelPointToAppKitGlobalPoint(
        screenshotPixelPoint: CGPoint,
        screenshotWidthInPixels: CGFloat,
        screenshotHeightInPixels: CGFloat,
        displayWidthInPoints: CGFloat,
        displayHeightInPoints: CGFloat,
        displayFrameInAppKitCoordinates: CGRect
    ) -> CGPoint {
        // Clamp to screenshot coordinate space so out-of-bounds estimates from
        // Claude don't place the cursor off the edge of the display.
        let clampedScreenshotX = max(0, min(screenshotPixelPoint.x, screenshotWidthInPixels))
        let clampedScreenshotY = max(0, min(screenshotPixelPoint.y, screenshotHeightInPixels))

        // Scale from screenshot pixels to display points.
        // The screenshot is downscaled (e.g. 1280px wide for a 1512pt display),
        // so we undo that downscaling here.
        let displayLocalX = clampedScreenshotX * (displayWidthInPoints / screenshotWidthInPixels)
        let displayLocalY = clampedScreenshotY * (displayHeightInPoints / screenshotHeightInPixels)

        // Flip Y from top-left (screenshot) to bottom-left (AppKit) within
        // this display's local coordinate system, BEFORE adding the display's
        // global origin. The flip is relative to the display's own height.
        let displayLocalAppKitY = displayHeightInPoints - displayLocalY

        // Translate from display-local AppKit coordinates to AppKit global
        // coordinates by adding the display's origin. For the primary display
        // this origin is (0, 0); for secondary displays it reflects the user's
        // arrangement in System Settings → Displays.
        let globalAppKitX = displayLocalX + displayFrameInAppKitCoordinates.origin.x
        let globalAppKitY = displayLocalAppKitY + displayFrameInAppKitCoordinates.origin.y

        return CGPoint(x: globalAppKitX, y: globalAppKitY)
    }

    // MARK: - CG global ↔ AppKit global (points)

    /// Converts a point from CG global coordinates (top-left origin of the primary
    /// display) to AppKit global coordinates (bottom-left origin of the primary display).
    ///
    /// Why we flip against primaryScreenFrame.maxY (not .height): On macOS the
    /// primary display's AppKit frame does NOT always start at y=0 — the menu bar
    /// height is included in the frame but the usable area starts below it. Using
    /// maxY (the top edge of the primary screen in AppKit space) is the correct
    /// mirror axis. NSScreen.screens[0] is the primary display by macOS convention;
    /// the caller must pass screens[0].frame, never NSScreen.main.frame, because
    /// NSScreen.main changes with focus while NSScreen.screens[0] is stable.
    ///
    /// - Parameters:
    ///   - cgGlobalPoint: A point in CG global space (top-left origin of primary display).
    ///   - primaryScreenFrameInAppKitCoordinates: NSScreen.screens[0].frame — the primary
    ///     display's frame in AppKit coordinates. The maxY of this rect is the flip axis.
    /// - Returns: The equivalent point in AppKit global coordinates.
    static func convertCGGlobalPointToAppKitGlobalPoint(
        cgGlobalPoint: CGPoint,
        primaryScreenFrameInAppKitCoordinates: CGRect
    ) -> CGPoint {
        let appKitY = primaryScreenFrameInAppKitCoordinates.maxY - cgGlobalPoint.y
        return CGPoint(x: cgGlobalPoint.x, y: appKitY)
    }

    /// Converts a point from AppKit global coordinates (bottom-left origin of the
    /// primary display) back to CG global coordinates (top-left origin).
    ///
    /// This is the exact inverse of `convertCGGlobalPointToAppKitGlobalPoint`.
    ///
    /// - Parameters:
    ///   - appKitGlobalPoint: A point in AppKit global space.
    ///   - primaryScreenFrameInAppKitCoordinates: NSScreen.screens[0].frame. The maxY
    ///     of this rect is the flip axis, identical to the forward conversion.
    /// - Returns: The equivalent point in CG global coordinates.
    static func convertAppKitGlobalPointToCGGlobalPoint(
        appKitGlobalPoint: CGPoint,
        primaryScreenFrameInAppKitCoordinates: CGRect
    ) -> CGPoint {
        let cgY = primaryScreenFrameInAppKitCoordinates.maxY - appKitGlobalPoint.y
        return CGPoint(x: appKitGlobalPoint.x, y: cgY)
    }

    // MARK: - CG global ↔ AppKit global (rects)

    /// Converts a rect from CG global coordinates to AppKit global coordinates.
    ///
    /// Why rect conversion differs from point conversion: flipping a rect's Y
    /// coordinate alone would place its origin at the top-left corner in AppKit
    /// space, but AppKit expects the origin at the BOTTOM-left corner of the rect.
    /// So the formula is `appKitY = primaryScreenMaxY - (cgY + rectHeight)`, which
    /// simultaneously flips the axis AND adjusts for the rect's own height. This is
    /// the same pattern used in WindowPositionManager.shrinkOverlappingFocusedWindow
    /// (line: `otherNSScreenY = screenFrame.maxY - otherPosition.y - otherSize.height`).
    ///
    /// - Parameters:
    ///   - cgGlobalRect: A rect in CG global space (top-left origin of primary display).
    ///   - primaryScreenFrameInAppKitCoordinates: NSScreen.screens[0].frame.
    /// - Returns: The equivalent rect in AppKit global coordinates.
    static func convertCGGlobalRectToAppKitGlobalRect(
        cgGlobalRect: CGRect,
        primaryScreenFrameInAppKitCoordinates: CGRect
    ) -> CGRect {
        let appKitY = primaryScreenFrameInAppKitCoordinates.maxY - (cgGlobalRect.origin.y + cgGlobalRect.height)
        return CGRect(
            x: cgGlobalRect.origin.x,
            y: appKitY,
            width: cgGlobalRect.width,
            height: cgGlobalRect.height
        )
    }

    /// Converts a rect from AppKit global coordinates back to CG global coordinates.
    ///
    /// This is the exact inverse of `convertCGGlobalRectToAppKitGlobalRect`.
    /// The inverse formula is `cgY = primaryScreenMaxY - (appKitY + rectHeight)`,
    /// which is structurally identical to the forward direction because the flip
    /// is its own inverse when the rect height adjustment is included.
    ///
    /// - Parameters:
    ///   - appKitGlobalRect: A rect in AppKit global space.
    ///   - primaryScreenFrameInAppKitCoordinates: NSScreen.screens[0].frame.
    /// - Returns: The equivalent rect in CG global coordinates.
    static func convertAppKitGlobalRectToCGGlobalRect(
        appKitGlobalRect: CGRect,
        primaryScreenFrameInAppKitCoordinates: CGRect
    ) -> CGRect {
        let cgY = primaryScreenFrameInAppKitCoordinates.maxY - (appKitGlobalRect.origin.y + appKitGlobalRect.height)
        return CGRect(
            x: appKitGlobalRect.origin.x,
            y: cgY,
            width: appKitGlobalRect.width,
            height: appKitGlobalRect.height
        )
    }

    // MARK: - Display points → Screenshot pixels (rect)

    /// Converts a rect from display-point space (AppKit global coordinates, the internal
    /// representation of AX element frames after CG→AppKit conversion) into screenshot-pixel
    /// space (top-left origin, matching the coordinate space of the images Claude receives).
    ///
    /// This is the inverse of the screenshot-pixel → display-point scaling that
    /// `convertScreenshotPixelPointToAppKitGlobalPoint` performs. The prompt formatter in
    /// `AccessibilityElementInventoryService` uses this so inventory element frames share
    /// a coordinate space with the screenshot images — enabling Claude to cross-check visual
    /// and structural signals without coordinate-space confusion.
    ///
    /// Why top-left origin in the output: screenshot images are top-left origin (pixel row 0
    /// is the top of the display). We undo the AppKit bottom-left flip here by converting
    /// the AppKit global rect back into display-local space and then flipping Y relative to
    /// the display's own height before scaling to pixels.
    ///
    /// Why we subtract displayFrame.origin before the flip: the rect's AppKit coordinates
    /// are global (multi-monitor), so we must translate to display-local first. The flip
    /// must be relative to the display's own height, not the global primary-screen height.
    ///
    /// - Parameters:
    ///   - appKitGlobalRect: A rect in AppKit global coordinates (e.g., an AX element frame
    ///     after conversion via `convertCGGlobalRectToAppKitGlobalRect`).
    ///   - displayFrameInAppKitCoordinates: The NSScreen.frame for the display this rect lives
    ///     on, in AppKit coordinates. Used to translate from global to display-local before
    ///     scaling. Must be the same display frame that was used during CG→AppKit conversion.
    ///   - screenshotWidthInPixels: The pixel width of the screenshot image for this display.
    ///   - screenshotHeightInPixels: The pixel height of the screenshot image for this display.
    /// - Returns: The rect in screenshot-pixel space (top-left origin, integer-valued pixels).
    static func convertAppKitGlobalRectToScreenshotPixelRect(
        appKitGlobalRect: CGRect,
        displayFrameInAppKitCoordinates: CGRect,
        screenshotWidthInPixels: CGFloat,
        screenshotHeightInPixels: CGFloat
    ) -> CGRect {
        // Step 1: Translate from AppKit global to display-local AppKit coordinates.
        // Subtracting the display's global origin gives us coordinates relative to
        // the bottom-left corner of this specific display.
        let displayLocalAppKitX = appKitGlobalRect.origin.x - displayFrameInAppKitCoordinates.origin.x
        let displayLocalAppKitY = appKitGlobalRect.origin.y - displayFrameInAppKitCoordinates.origin.y

        // Step 2: Flip Y from AppKit bottom-left to top-left within the display.
        // AppKit origin is at the bottom of the display; screenshots have origin at top.
        // `displayLocalAppKitY` is the distance from the display bottom to the rect's
        // BOTTOM edge (AppKit convention). Adding height gives the distance from the
        // display bottom to the rect's TOP edge, then subtracting from displayHeight
        // gives the distance from the display TOP to the rect's TOP edge — which is
        // the top-left Y coordinate we need.
        let displayHeight = displayFrameInAppKitCoordinates.height
        let displayLocalTopLeftY = displayHeight - (displayLocalAppKitY + appKitGlobalRect.height)

        // Step 3: Scale from display points to screenshot pixels.
        let scaleX = screenshotWidthInPixels / displayFrameInAppKitCoordinates.width
        let scaleY = screenshotHeightInPixels / displayHeight

        return CGRect(
            x: displayLocalAppKitX * scaleX,
            y: displayLocalTopLeftY * scaleY,
            width: appKitGlobalRect.width * scaleX,
            height: appKitGlobalRect.height * scaleY
        )
    }
}
