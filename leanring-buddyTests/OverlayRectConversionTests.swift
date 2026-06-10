//
//  OverlayRectConversionTests.swift
//  leanring-buddyTests
//
//  Tests for the `convertAppKitGlobalRectToSwiftUILocalRect` helper that lives in
//  BlueCursorView (OverlayWindow.swift). Because the helper is private to the view
//  struct, we test it here via a thin public static wrapper extracted for testability:
//  `OverlayRectConverter.convertAppKitGlobalRectToSwiftUILocalRect(appKitGlobalRect:screenFrame:)`.
//
//  This is consistent with the codebase pattern of extracting pure static functions
//  for testability (see CompanionManager.parsePointingCoordinates,
//  CompanionManager.resolveElementIDToAppKitCenter, etc.).
//
//  COORDINATE SPACE CONTRACT UNDER TEST
//  ─────────────────────────────────────────────────────────────────────────────
//  Input:  AppKit global rect (bottom-left origin of primary display, points).
//  Output: SwiftUI-local rect (top-left origin, relative to the overlay window
//          that covers `screenFrame`).
//
//  The key formula:
//    swiftUILocalX = appKitRect.origin.x - screenFrame.origin.x
//    swiftUILocalY = (screenFrame.origin.y + screenFrame.height)
//                   - (appKitRect.origin.y + appKitRect.height)
//    width  = appKitRect.width   (unchanged)
//    height = appKitRect.height  (unchanged)
//
//  The Y formula converts the AppKit rect's TOP edge (origin.y + height) to
//  SwiftUI's top-left coordinate system. Using origin.y alone would place the
//  rect's bottom edge at the SwiftUI origin — a common off-by-height bug.
//

import Testing
import CoreGraphics
@testable import leanring_buddy

/// Pure static wrapper exposing the rect-conversion formula for unit testing.
/// The production version is BlueCursorView.convertAppKitGlobalRectToSwiftUILocalRect(_:).
/// Both implementations must stay in sync; any change to the formula should be
/// reflected in both this wrapper and the private method.
enum OverlayRectConverter {
    /// Converts an AppKit-global rect to a SwiftUI-local rect relative to the
    /// overlay window whose bounds match `screenFrame`.
    static func convertAppKitGlobalRectToSwiftUILocalRect(
        appKitGlobalRect: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        let swiftUILocalX = appKitGlobalRect.origin.x - screenFrame.origin.x
        let appKitTopEdgeY = appKitGlobalRect.origin.y + appKitGlobalRect.height
        let swiftUILocalY = (screenFrame.origin.y + screenFrame.height) - appKitTopEdgeY
        return CGRect(
            x: swiftUILocalX,
            y: swiftUILocalY,
            width: appKitGlobalRect.width,
            height: appKitGlobalRect.height
        )
    }
}

struct OverlayRectConversionTests {

    // MARK: - Primary display (origin at 0,0)

    /// A rect exactly at the top-left of the primary display should map to (0,0)
    /// in SwiftUI-local coordinates — the top-left of the overlay window.
    ///
    /// Setup: primary display 1440×900 at AppKit origin (0,0).
    /// A 100×30 rect whose AppKit origin is at (0, 870) — which puts its TOP
    /// edge at y=870+30=900, i.e. the very top of the display.
    /// In SwiftUI: y = (0+900) - (870+30) = 900 - 900 = 0. ✓
    @Test func rectAtTopLeftOfPrimaryDisplayMapsToSwiftUIOrigin() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Rect whose top edge sits at the very top of the display:
        // AppKit origin.y = displayHeight - rectHeight = 900 - 30 = 870
        let appKitRect = CGRect(x: 0, y: 870, width: 100, height: 30)

        let swiftUILocalRect = OverlayRectConverter.convertAppKitGlobalRectToSwiftUILocalRect(
            appKitGlobalRect: appKitRect,
            screenFrame: screenFrame
        )

        #expect(swiftUILocalRect.origin.x == 0)
        #expect(swiftUILocalRect.origin.y == 0)
        #expect(swiftUILocalRect.width == 100)
        #expect(swiftUILocalRect.height == 30)
    }

    /// A rect at the center of the primary display should map to the center
    /// of the SwiftUI coordinate space for that overlay window.
    ///
    /// Primary display 1440×900. A 200×40 rect centered at (720, 450) in AppKit:
    ///   AppKit rect: (620, 430, 200, 40)  — origin is bottom-left of rect
    ///   SwiftUI y = (0+900) - (430+40) = 900 - 470 = 430
    ///   SwiftUI center y = 430 + 40/2 = 450  ✓ (matches AppKit center y)
    @Test func rectAtCenterOfPrimaryDisplayMapsToSwiftUICenter() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let appKitRect = CGRect(x: 620, y: 430, width: 200, height: 40)

        let swiftUILocalRect = OverlayRectConverter.convertAppKitGlobalRectToSwiftUILocalRect(
            appKitGlobalRect: appKitRect,
            screenFrame: screenFrame
        )

        // SwiftUI center should be at the visual center of the display
        let swiftUICenterX = swiftUILocalRect.midX
        let swiftUICenterY = swiftUILocalRect.midY
        #expect(abs(swiftUICenterX - 720) < 0.001)  // center x unchanged
        #expect(abs(swiftUICenterY - 450) < 0.001)  // center y flipped correctly
        #expect(swiftUILocalRect.width == 200)
        #expect(swiftUILocalRect.height == 40)
    }

    /// Verifies that size (width and height) passes through unchanged — only
    /// the origin is transformed by the coordinate-space conversion.
    @Test func rectSizeIsPreservedAfterConversion() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let appKitRect = CGRect(x: 300, y: 200, width: 350, height: 75)

        let swiftUILocalRect = OverlayRectConverter.convertAppKitGlobalRectToSwiftUILocalRect(
            appKitGlobalRect: appKitRect,
            screenFrame: screenFrame
        )

        #expect(swiftUILocalRect.width == 350)
        #expect(swiftUILocalRect.height == 75)
    }

    // MARK: - Secondary display (non-zero origin)

    /// A rect on a secondary display arranged to the RIGHT of the primary must
    /// produce SwiftUI-local coordinates relative to THAT display's overlay window,
    /// not relative to the global AppKit origin.
    ///
    /// Secondary display: 2560×1440 points, AppKit origin at (1440, 0).
    /// A 300×50 button at AppKit (2000, 700):
    ///   swiftUILocalX = 2000 - 1440 = 560
    ///   appKitTopEdge = 700 + 50 = 750
    ///   swiftUILocalY = (0 + 1440) - 750 = 690
    @Test func rectOnSecondaryDisplayToRightOfPrimaryMapsToLocalCoordinates() {
        let secondaryScreenFrame = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let appKitRect = CGRect(x: 2000, y: 700, width: 300, height: 50)

        let swiftUILocalRect = OverlayRectConverter.convertAppKitGlobalRectToSwiftUILocalRect(
            appKitGlobalRect: appKitRect,
            screenFrame: secondaryScreenFrame
        )

        #expect(abs(swiftUILocalRect.origin.x - 560) < 0.001)
        #expect(abs(swiftUILocalRect.origin.y - 690) < 0.001)
        #expect(swiftUILocalRect.width == 300)
        #expect(swiftUILocalRect.height == 50)
    }

    /// A rect on a secondary display arranged ABOVE the primary (positive y-origin
    /// in AppKit) must correctly subtract the display's y-offset so the result is
    /// local to that screen's overlay window.
    ///
    /// Secondary display: 1280×800 pts, AppKit origin at (0, 900) (directly above
    /// a 1440×900 primary).
    /// A 120×28 element at AppKit (400, 1640):
    ///   appKitTopEdge = 1640 + 28 = 1668
    ///   swiftUILocalY = (900 + 800) - 1668 = 1700 - 1668 = 32
    ///   swiftUILocalX = 400 - 0 = 400
    @Test func rectOnSecondaryDisplayAbovePrimaryMapsToLocalCoordinates() {
        let secondaryScreenFrame = CGRect(x: 0, y: 900, width: 1280, height: 800)
        let appKitRect = CGRect(x: 400, y: 1640, width: 120, height: 28)

        let swiftUILocalRect = OverlayRectConverter.convertAppKitGlobalRectToSwiftUILocalRect(
            appKitGlobalRect: appKitRect,
            screenFrame: secondaryScreenFrame
        )

        #expect(abs(swiftUILocalRect.origin.x - 400) < 0.001)
        #expect(abs(swiftUILocalRect.origin.y - 32) < 0.001)
        #expect(swiftUILocalRect.width == 120)
        #expect(swiftUILocalRect.height == 28)
    }

    // MARK: - Off-screen rect (wrong screen — should be filtered before reaching here)

    /// A rect whose AppKit x-coordinate is entirely on a different screen will
    /// produce a negative or very large SwiftUI-local x, which SwiftUI clips
    /// outside the overlay bounds. This test documents the expected behavior
    /// rather than asserting a filtered result — the filtering happens in
    /// BlueCursorView.annotationsForThisScreen before this converter is called.
    ///
    /// Primary display 1440×900. A rect at AppKit x=2000 (on a secondary display)
    /// would produce swiftUILocalX = 2000 - 0 = 2000, which is outside the
    /// 1440-wide overlay. We verify the math is correct (2000) rather than
    /// filtered (which is the caller's responsibility).
    @Test func rectOnOtherScreenProducesOutOfBoundsXAfterConversion() {
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rectOnSecondaryDisplay = CGRect(x: 2000, y: 400, width: 200, height: 40)

        let swiftUILocalRect = OverlayRectConverter.convertAppKitGlobalRectToSwiftUILocalRect(
            appKitGlobalRect: rectOnSecondaryDisplay,
            screenFrame: primaryScreenFrame
        )

        // x is well outside the primary display's 1440-pt width — the caller
        // should have filtered this out; the converter reports it faithfully.
        #expect(swiftUILocalRect.origin.x > primaryScreenFrame.width)
    }

    // MARK: - Y-flip correctness (off-by-height regression)

    /// Explicitly tests that the Y conversion uses `origin.y + height` (the AppKit
    /// TOP edge) rather than `origin.y` (the AppKit BOTTOM edge). Using the bottom
    /// edge would place the rect at the wrong vertical position.
    ///
    /// Primary display 1440×900. A 50-pt-tall rect at AppKit y=200:
    ///   Correct: swiftUILocalY = 900 - (200 + 50) = 650
    ///   Bug:     swiftUILocalY = 900 - 200         = 700  (off by rect height)
    @Test func swiftUILocalYUsesAppKitTopEdgeNotBottomEdge() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let appKitRect = CGRect(x: 100, y: 200, width: 300, height: 50)

        let swiftUILocalRect = OverlayRectConverter.convertAppKitGlobalRectToSwiftUILocalRect(
            appKitGlobalRect: appKitRect,
            screenFrame: screenFrame
        )

        // Correct: 900 - (200 + 50) = 650. Wrong (if origin.y used): 900 - 200 = 700.
        #expect(swiftUILocalRect.origin.y == 650)
    }
}
