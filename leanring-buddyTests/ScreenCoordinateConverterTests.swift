//
//  ScreenCoordinateConverterTests.swift
//  leanring-buddyTests
//
//  Tests for ScreenCoordinateConverter — the single source of truth for all
//  coordinate-space conversions in the pointing pipeline. These are pure-function
//  tests: no display hardware, no NSScreen, no TCC grants required.
//
//  Coordinate spaces under test:
//    - Screenshot pixels: top-left origin, pixel units (Claude's output space)
//    - AppKit global:     bottom-left origin of the primary display, point units
//    - CG global:         top-left origin of the primary display, point units
//
//  The multi-monitor Y-flip is the highest-risk correctness trap in this
//  codebase (displays above/left of primary have non-zero or negative origins
//  in AppKit space), so secondary-display cases are tested explicitly.
//

import Testing
@testable import leanring_buddy

struct ScreenCoordinateConverterTests {

    // MARK: - Screenshot pixels → AppKit global (primary display)

    /// Verifies the canonical conversion path: a screenshot pixel coordinate from
    /// Claude is scaled from the downscaled image to display points, then Y-flipped
    /// within the display before the display's AppKit origin is added.
    ///
    /// Setup: 1280×800 screenshot of a 1440×900-point primary display.
    /// Claude emits (640, 400) — the exact centre of the screenshot.
    ///
    /// Expected output:
    ///   displayLocalX = 640 * (1440/1280) = 720
    ///   displayLocalY = 400 * (900/800)   = 450
    ///   appKitY (flipped) = 900 - 450 = 450
    ///   globalAppKitX = 720 + 0 = 720
    ///   globalAppKitY = 450 + 0 = 450
    @Test func screenshotPixelCentreMapsToCentreOfPrimaryDisplayInAppKitCoordinates() {
        let primaryDisplayFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let resultPoint = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
            screenshotPixelPoint: CGPoint(x: 640, y: 400),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrameInAppKitCoordinates: primaryDisplayFrameInAppKitCoordinates
        )

        #expect(resultPoint.x == 720)
        #expect(resultPoint.y == 450)
    }

    /// Verifies the top-left corner of the screenshot maps to the top-left of the
    /// display in AppKit coordinates, which is (0, displayHeight) because AppKit's
    /// Y axis runs upward.
    @Test func screenshotTopLeftCornerMapsToAppKitTopLeftOfPrimaryDisplay() {
        let primaryDisplayFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let resultPoint = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
            screenshotPixelPoint: CGPoint(x: 0, y: 0),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrameInAppKitCoordinates: primaryDisplayFrameInAppKitCoordinates
        )

        // Top-left of the screenshot = top-left of the display = (0, 900) in AppKit
        #expect(resultPoint.x == 0)
        #expect(resultPoint.y == 900)
    }

    /// Verifies the bottom-right corner of the screenshot maps to (displayWidth, 0)
    /// in AppKit — the bottom-right of the display with the y-axis flipped.
    @Test func screenshotBottomRightCornerMapsToAppKitBottomRightOfPrimaryDisplay() {
        let primaryDisplayFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let resultPoint = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
            screenshotPixelPoint: CGPoint(x: 1280, y: 800),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrameInAppKitCoordinates: primaryDisplayFrameInAppKitCoordinates
        )

        #expect(resultPoint.x == 1440)
        #expect(resultPoint.y == 0)
    }

    // MARK: - Screenshot pixels → AppKit global (secondary display)

    /// Verifies a secondary display whose AppKit origin is to the RIGHT of the primary.
    ///
    /// Setup: secondary display is 2560×1440 points, positioned at AppKit origin
    /// (1440, 0) — immediately right of a 1440-wide primary. Screenshot is 1280×720px.
    ///
    /// Claude emits (640, 360) — the exact centre of the secondary screenshot.
    ///
    /// Expected:
    ///   displayLocalX = 640 * (2560/1280) = 1280
    ///   displayLocalY = 360 * (1440/720)  = 720
    ///   appKitLocalY  = 1440 - 720        = 720
    ///   globalX       = 1280 + 1440       = 2720
    ///   globalY       = 720  + 0          = 720
    @Test func screenshotPixelCentreOnSecondaryDisplayRightOfPrimaryMapsCorrectly() {
        let secondaryDisplayFrameInAppKitCoordinates = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

        let resultPoint = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
            screenshotPixelPoint: CGPoint(x: 640, y: 360),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 720,
            displayWidthInPoints: 2560,
            displayHeightInPoints: 1440,
            displayFrameInAppKitCoordinates: secondaryDisplayFrameInAppKitCoordinates
        )

        #expect(resultPoint.x == 2720)
        #expect(resultPoint.y == 720)
    }

    /// Verifies a secondary display arranged ABOVE the primary in System Settings.
    ///
    /// When a display is above the primary, its AppKit y-origin is POSITIVE (its
    /// bottom edge is above the primary's top edge). This is a common source of
    /// coordinate bugs because the sign is unintuitive.
    ///
    /// Setup: primary is 1440×900. Secondary (1280×800 pts) is placed directly
    /// above: AppKit origin = (0, 900).
    /// Screenshot is 1280×800 pixels (1:1 with points in this test).
    ///
    /// Claude emits (0, 0) — the top-left of the screenshot, which maps to the
    /// top-left of the secondary display in AppKit: (0, 900 + 800) = (0, 1700).
    @Test func screenshotTopLeftOnDisplayArrangedAbovePrimaryMapsCorrectly() {
        let secondaryDisplayAbovePrimaryFrameInAppKitCoordinates = CGRect(x: 0, y: 900, width: 1280, height: 800)

        let resultPoint = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
            screenshotPixelPoint: CGPoint(x: 0, y: 0),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1280,
            displayHeightInPoints: 800,
            displayFrameInAppKitCoordinates: secondaryDisplayAbovePrimaryFrameInAppKitCoordinates
        )

        // Screenshot top-left → display-local top-left → AppKit: (0, 800) in display-local
        // + displayFrame.origin.y = 900 → global y = 1700
        #expect(resultPoint.x == 0)
        #expect(resultPoint.y == 1700)
    }

    /// Verifies a secondary display arranged to the LEFT of the primary (negative
    /// x-origin in AppKit coordinates is impossible — leftmost display always has
    /// x=0; instead the primary shifts right). This test models the realistic case:
    /// secondary at x=0, primary at x=1280 (secondary is to the left of primary).
    ///
    /// Claude emits (640, 400) — the centre of the secondary screenshot.
    ///
    /// Secondary frame in AppKit: (0, 0, 1280, 800).
    /// Expected globalX = 640*(1280/1280) + 0 = 640
    /// Expected globalY = 800 - 400*(800/800) + 0 = 400
    @Test func screenshotCentreOnDisplayArrangedLeftOfPrimaryMapsCorrectly() {
        let secondaryDisplayToLeftFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1280, height: 800)

        let resultPoint = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
            screenshotPixelPoint: CGPoint(x: 640, y: 400),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1280,
            displayHeightInPoints: 800,
            displayFrameInAppKitCoordinates: secondaryDisplayToLeftFrameInAppKitCoordinates
        )

        #expect(resultPoint.x == 640)
        #expect(resultPoint.y == 400)
    }

    // MARK: - Out-of-bounds clamping

    /// Verifies that a screenshot x-coordinate that exceeds the screenshot width
    /// is clamped to the screenshot width before scaling, not wrapped or crashed.
    /// Claude occasionally over-estimates coordinates by a few pixels.
    @Test func screenshotXCoordinateExceedingWidthIsClampedToScreenshotEdge() {
        let primaryDisplayFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // x = 1300 exceeds screenshotWidth = 1280; should be clamped to 1280
        let resultPoint = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
            screenshotPixelPoint: CGPoint(x: 1300, y: 400),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrameInAppKitCoordinates: primaryDisplayFrameInAppKitCoordinates
        )

        // Clamped x = 1280 → displayLocalX = 1280*(1440/1280) = 1440
        #expect(resultPoint.x == 1440)
    }

    /// Verifies that a screenshot y-coordinate that exceeds the screenshot height
    /// is clamped. The resulting AppKit y should be 0 (bottom of the display).
    @Test func screenshotYCoordinateExceedingHeightIsClampedToScreenshotEdge() {
        let primaryDisplayFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // y = 850 exceeds screenshotHeight = 800; should be clamped to 800
        let resultPoint = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
            screenshotPixelPoint: CGPoint(x: 0, y: 850),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrameInAppKitCoordinates: primaryDisplayFrameInAppKitCoordinates
        )

        // Clamped y = 800 → displayLocalY = 800*(900/800) = 900
        // appKitLocalY = 900 - 900 = 0
        #expect(resultPoint.y == 0)
    }

    /// Verifies negative screenshot coordinates are clamped to 0 (the top-left edge).
    @Test func negativeScreenshotCoordinatesAreClampedToZero() {
        let primaryDisplayFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let resultPoint = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
            screenshotPixelPoint: CGPoint(x: -50, y: -20),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrameInAppKitCoordinates: primaryDisplayFrameInAppKitCoordinates
        )

        // Clamped to (0, 0) → displayLocal (0, 0) → appKit (0, 900)
        #expect(resultPoint.x == 0)
        #expect(resultPoint.y == 900)
    }

    // MARK: - CG global ↔ AppKit global round-trips (points)

    /// Verifies that converting a CG point to AppKit and back returns the original value.
    /// Uses a primary display frame that matches the common MacBook Pro 14" logical resolution.
    @Test func cgGlobalPointToAppKitAndBackProducesOriginalPointOnPrimaryDisplay() {
        let primaryScreenFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let originalCGPoint = CGPoint(x: 756, y: 200)

        let appKitPoint = ScreenCoordinateConverter.convertCGGlobalPointToAppKitGlobalPoint(
            cgGlobalPoint: originalCGPoint,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )
        let roundTrippedCGPoint = ScreenCoordinateConverter.convertAppKitGlobalPointToCGGlobalPoint(
            appKitGlobalPoint: appKitPoint,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )

        #expect(abs(roundTrippedCGPoint.x - originalCGPoint.x) < 0.001)
        #expect(abs(roundTrippedCGPoint.y - originalCGPoint.y) < 0.001)
    }

    /// Verifies the CG→AppKit→CG round-trip for a point on a secondary display.
    /// Secondary display points use the same primary-screen maxY flip axis because
    /// the CG↔AppKit flip for AX coordinates is always against the primary screen.
    @Test func cgGlobalPointToAppKitAndBackProducesOriginalPointOnSecondaryDisplay() {
        // Primary is 1440×900 at AppKit origin (0,0).
        // A point on the secondary display (to the right) in CG space.
        let primaryScreenFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cgPointOnSecondaryDisplay = CGPoint(x: 1800, y: 300)

        let appKitPoint = ScreenCoordinateConverter.convertCGGlobalPointToAppKitGlobalPoint(
            cgGlobalPoint: cgPointOnSecondaryDisplay,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )
        let roundTrippedCGPoint = ScreenCoordinateConverter.convertAppKitGlobalPointToCGGlobalPoint(
            appKitGlobalPoint: appKitPoint,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )

        #expect(abs(roundTrippedCGPoint.x - cgPointOnSecondaryDisplay.x) < 0.001)
        #expect(abs(roundTrippedCGPoint.y - cgPointOnSecondaryDisplay.y) < 0.001)
    }

    /// Verifies the CG→AppKit conversion produces the expected value using the
    /// same formula as WindowPositionManager.shrinkOverlappingFocusedWindow:
    /// appKitY = screenFrame.maxY - cgY
    @Test func cgGlobalPointToAppKitYUsesMaxYOfPrimaryScreenAsFlipAxis() {
        let primaryScreenFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // CG y=100 from the top → AppKit y = 900 - 100 = 800
        let cgPoint = CGPoint(x: 500, y: 100)

        let appKitPoint = ScreenCoordinateConverter.convertCGGlobalPointToAppKitGlobalPoint(
            cgGlobalPoint: cgPoint,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )

        #expect(appKitPoint.x == 500)
        #expect(appKitPoint.y == 800)
    }

    // MARK: - CG global ↔ AppKit global round-trips (rects)

    /// Verifies that converting a CG rect to AppKit and back returns the original value.
    ///
    /// Rect conversion is distinct from point conversion because the origin must
    /// shift by the rect's height during the Y flip. This test catches the common
    /// bug of using the point formula on a rect (which places the origin at the
    /// top-left corner in AppKit space instead of the bottom-left corner).
    @Test func cgGlobalRectToAppKitAndBackProducesOriginalRectOnPrimaryDisplay() {
        let primaryScreenFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let originalCGRect = CGRect(x: 100, y: 200, width: 300, height: 50)

        let appKitRect = ScreenCoordinateConverter.convertCGGlobalRectToAppKitGlobalRect(
            cgGlobalRect: originalCGRect,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )
        let roundTrippedCGRect = ScreenCoordinateConverter.convertAppKitGlobalRectToCGGlobalRect(
            appKitGlobalRect: appKitRect,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )

        #expect(abs(roundTrippedCGRect.origin.x - originalCGRect.origin.x) < 0.001)
        #expect(abs(roundTrippedCGRect.origin.y - originalCGRect.origin.y) < 0.001)
        #expect(abs(roundTrippedCGRect.width  - originalCGRect.width)  < 0.001)
        #expect(abs(roundTrippedCGRect.height - originalCGRect.height) < 0.001)
    }

    /// Verifies the rect Y flip formula explicitly: AppKit y = maxY - (cgY + height),
    /// NOT maxY - cgY. This test exists specifically to catch the off-by-height
    /// mistake that would place the rect's origin at the wrong edge.
    @Test func cgGlobalRectYFlipUsesHeightAdjustedFormulaNotPointFlipFormula() {
        let primaryScreenFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // A rect at CG y=200 with height=50.
        // Correct AppKit y = 900 - (200 + 50) = 650.
        // Wrong formula (point flip): 900 - 200 = 700 — this test catches that.
        let cgRect = CGRect(x: 100, y: 200, width: 300, height: 50)

        let appKitRect = ScreenCoordinateConverter.convertCGGlobalRectToAppKitGlobalRect(
            cgGlobalRect: cgRect,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )

        #expect(appKitRect.origin.x == 100)
        #expect(appKitRect.origin.y == 650)   // 900 - (200 + 50) = 650, not 700
        #expect(appKitRect.width == 300)
        #expect(appKitRect.height == 50)
    }

    /// Verifies the rect round-trip on a secondary display using a non-zero primary
    /// screen maxY (i.e., a primary with a menu bar that shifts the effective height).
    @Test func cgGlobalRectToAppKitAndBackProducesOriginalRectOnSecondaryDisplay() {
        let primaryScreenFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // A rect whose x-origin is on a secondary display to the right
        let cgRectOnSecondaryDisplay = CGRect(x: 1600, y: 100, width: 200, height: 80)

        let appKitRect = ScreenCoordinateConverter.convertCGGlobalRectToAppKitGlobalRect(
            cgGlobalRect: cgRectOnSecondaryDisplay,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )
        let roundTrippedCGRect = ScreenCoordinateConverter.convertAppKitGlobalRectToCGGlobalRect(
            appKitGlobalRect: appKitRect,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )

        #expect(abs(roundTrippedCGRect.origin.x - cgRectOnSecondaryDisplay.origin.x) < 0.001)
        #expect(abs(roundTrippedCGRect.origin.y - cgRectOnSecondaryDisplay.origin.y) < 0.001)
        #expect(abs(roundTrippedCGRect.width  - cgRectOnSecondaryDisplay.width)  < 0.001)
        #expect(abs(roundTrippedCGRect.height - cgRectOnSecondaryDisplay.height) < 0.001)
    }
}
