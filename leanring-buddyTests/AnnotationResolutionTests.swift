//
//  AnnotationResolutionTests.swift
//  leanring-buddyTests
//
//  Tests for CompanionManager.resolveAnnotationsToScreenRects — the pure static
//  function that converts ParsedScreenAnnotation values (raw parser output) into
//  ResolvedScreenAnnotation values (AppKit-global rects + screen assignment).
//
//  This function is the annotation counterpart of the pointing-resolution logic
//  in sendTranscriptToClaudeWithScreenshot: element-ID targets look up the
//  inventory, pixel-rect targets use ScreenCoordinateConverter math.
//
//  All test inputs are value types (structs / CGRect / etc.) — no display
//  hardware, no NSScreen, no TCC grants needed.
//
//  CASES COVERED
//  ─────────────────────────────────────────────────────────────────────────────
//  1. Element-ID target, ID found in inventory → resolved to element's appKitFrame
//  2. Element-ID target, ID missing from inventory → annotation dropped
//  3. Element-ID target, inventory is nil → annotation dropped
//  4. Pixel-rect target, cursor screen used by default (no screenNumber) → resolved
//  5. Pixel-rect target, explicit screenNumber selects the right capture → resolved
//  6. Pixel-rect target, screenNumber out of range → falls back to cursor screen
//  7. Multiple annotations — resolved count matches parseable subset
//  8. Screen assignment for element-ID: annotation's displayFrameOfTargetScreen
//     is the screen frame containing the element center
//

import Testing
import CoreGraphics
@testable import leanring_buddy

// MARK: - Helpers for building test fixtures

/// Builds a minimal AccessibilityElementInventory for testing.
/// Only the fields accessed by resolveAnnotationsToScreenRects are populated.
private func makeTestInventory(
    elements: [AccessibleElement],
    frontmostAppName: String = "TestApp"
) -> AccessibilityElementInventory {
    AccessibilityElementInventory(
        elements: elements,
        frontmostAppName: frontmostAppName,
        frontmostAppBundleID: "com.test.TestApp",
        captureOutcome: .captured
    )
}

/// Builds a minimal AccessibleElement for testing. The axElementHandle is a
/// dummy application element (PID 0); Phase D is not under test here.
private func makeTestElement(
    elementID: Int,
    appKitFrame: CGRect
) -> AccessibleElement {
    AccessibleElement(
        elementID: elementID,
        role: "AXButton",
        subrole: nil,
        title: "Test Element \(elementID)",
        cgFrame: appKitFrame, // Using appKitFrame for both — only appKitFrame matters here
        appKitFrame: appKitFrame,
        axElementHandle: AXUIElementCreateApplication(0),
        owningProcessID: 0
    )
}

/// Builds a minimal CompanionScreenCapture for testing. The imageData field is
/// set to empty Data because resolveAnnotationsToScreenRects never reads image
/// bytes — only the dimensional and display-frame fields are used.
///
/// Field order matches the struct declaration in CompanionScreenCaptureUtility.swift:
///   imageData, label, isCursorScreen, displayWidthInPoints, displayHeightInPoints,
///   displayFrame, screenshotWidthInPixels, screenshotHeightInPixels
private func makeTestScreenCapture(
    screenshotWidthInPixels: Int,
    screenshotHeightInPixels: Int,
    displayWidthInPoints: Int,
    displayHeightInPoints: Int,
    displayFrame: CGRect,
    isCursorScreen: Bool,
    label: String = "screen1"
) -> CompanionScreenCapture {
    CompanionScreenCapture(
        imageData: Data(),
        label: label,
        isCursorScreen: isCursorScreen,
        displayWidthInPoints: displayWidthInPoints,
        displayHeightInPoints: displayHeightInPoints,
        displayFrame: displayFrame,
        screenshotWidthInPixels: screenshotWidthInPixels,
        screenshotHeightInPixels: screenshotHeightInPixels
    )
}

// MARK: - Tests

struct AnnotationResolutionTests {

    // MARK: - Element-ID resolution

    /// When the element ID is present in the inventory, the resolved annotation
    /// should use the element's appKitFrame verbatim.
    @Test func elementIDFoundInInventoryResolvesToElementAppKitFrame() {
        let elementAppKitFrame = CGRect(x: 200, y: 400, width: 120, height: 32)
        let element = makeTestElement(elementID: 5, appKitFrame: elementAppKitFrame)
        let inventory = makeTestInventory(elements: [element])
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let parsedAnnotation = ParsedScreenAnnotation(
            kind: .box,
            target: .elementID(5),
            label: "submit button"
        )

        let resolvedAnnotations = CompanionManager.resolveAnnotationsToScreenRects(
            parsedAnnotations: [parsedAnnotation],
            inventory: inventory,
            screenCaptures: [],
            allScreenFramesInAppKitCoordinates: [primaryScreenFrame]
        )

        #expect(resolvedAnnotations.count == 1)
        let resolved = resolvedAnnotations[0]
        #expect(resolved.kind == .box)
        #expect(resolved.label == "submit button")
        // The rect must exactly match the element's appKitFrame — no conversion applied.
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.origin.x - 200) < 0.001)
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.origin.y - 400) < 0.001)
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.width - 120) < 0.001)
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.height - 32) < 0.001)
    }

    /// When the element ID is NOT present in the inventory, the annotation must
    /// be dropped — never produce a zero-rect or (0,0) artifact.
    @Test func elementIDMissingFromInventoryDropsAnnotation() {
        let element = makeTestElement(elementID: 3, appKitFrame: CGRect(x: 100, y: 100, width: 80, height: 24))
        let inventory = makeTestInventory(elements: [element])
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Referencing element ID 99 which is not in the inventory
        let parsedAnnotation = ParsedScreenAnnotation(
            kind: .circle,
            target: .elementID(99),
            label: "missing element"
        )

        let resolvedAnnotations = CompanionManager.resolveAnnotationsToScreenRects(
            parsedAnnotations: [parsedAnnotation],
            inventory: inventory,
            screenCaptures: [],
            allScreenFramesInAppKitCoordinates: [primaryScreenFrame]
        )

        #expect(resolvedAnnotations.isEmpty)
    }

    /// When the inventory is nil (AX walk timed out or no AX available), all
    /// element-ID annotations must be dropped.
    @Test func elementIDWithNilInventoryDropsAnnotation() {
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let parsedAnnotation = ParsedScreenAnnotation(
            kind: .highlight,
            target: .elementID(1),
            label: "some element"
        )

        let resolvedAnnotations = CompanionManager.resolveAnnotationsToScreenRects(
            parsedAnnotations: [parsedAnnotation],
            inventory: nil,  // No inventory available
            screenCaptures: [],
            allScreenFramesInAppKitCoordinates: [primaryScreenFrame]
        )

        #expect(resolvedAnnotations.isEmpty)
    }

    // MARK: - Pixel-rect resolution

    /// A pixel-rect annotation with no screen number should use the cursor screen.
    ///
    /// Primary display: 1440×900 pts, screenshot 1280×800 px.
    /// Pixel-rect: (320, 200, 200, 40) in screenshot pixel space.
    /// Expected AppKit global:
    ///   scaleX = 1440/1280 = 1.125
    ///   scaleY = 900/800   = 1.125
    ///   displayLocalX = 320 * 1.125 = 360
    ///   displayLocalY = 200 * 1.125 = 225
    ///   displayLocalWidth  = 200 * 1.125 = 225
    ///   displayLocalHeight = 40  * 1.125 = 45
    ///   appKitLocalY = 900 - (225 + 45) = 630
    ///   globalX = 360 + 0 = 360
    ///   globalY = 630 + 0 = 630
    @Test func pixelRectWithNoCursorScreenNumberResolvesUsingCursorScreen() {
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursorScreenCapture = makeTestScreenCapture(
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrame: primaryScreenFrame,
            isCursorScreen: true,
            label: "screen1 (primary focus)"
        )

        let parsedAnnotation = ParsedScreenAnnotation(
            kind: .arrow,
            target: .pixelRect(rect: CGRect(x: 320, y: 200, width: 200, height: 40), screenNumber: nil),
            label: "some region"
        )

        let resolvedAnnotations = CompanionManager.resolveAnnotationsToScreenRects(
            parsedAnnotations: [parsedAnnotation],
            inventory: nil,
            screenCaptures: [cursorScreenCapture],
            allScreenFramesInAppKitCoordinates: [primaryScreenFrame]
        )

        #expect(resolvedAnnotations.count == 1)
        let resolved = resolvedAnnotations[0]
        #expect(resolved.kind == .arrow)
        #expect(resolved.label == "some region")
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.origin.x - 360) < 0.001)
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.origin.y - 630) < 0.001)
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.width - 225) < 0.001)
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.height - 45) < 0.001)
        // Screen assignment: should be the cursor screen's display frame
        #expect(resolved.displayFrameOfTargetScreen == primaryScreenFrame)
    }

    /// A pixel-rect annotation with screenNumber: 2 should use the second capture,
    /// not the cursor screen.
    ///
    /// Secondary display: 2560×1440 pts at AppKit (1440, 0), screenshot 1280×720 px.
    /// Pixel-rect: (640, 360, 100, 50) — center of secondary screenshot.
    /// Expected:
    ///   scaleX = 2560/1280 = 2.0
    ///   scaleY = 1440/720  = 2.0
    ///   displayLocalX = 640 * 2 = 1280
    ///   displayLocalY = 360 * 2 = 720
    ///   displayLocalWidth  = 100 * 2 = 200
    ///   displayLocalHeight = 50  * 2 = 100
    ///   appKitLocalY = 1440 - (720 + 100) = 620
    ///   globalX = 1280 + 1440 = 2720
    ///   globalY = 620  + 0    = 620
    @Test func pixelRectWithScreenNumber2UsesSecondCapture() {
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let secondaryScreenFrame = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

        let primaryCapture = makeTestScreenCapture(
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrame: primaryScreenFrame,
            isCursorScreen: true,
            label: "screen1 (primary focus)"
        )
        let secondaryCapture = makeTestScreenCapture(
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 720,
            displayWidthInPoints: 2560,
            displayHeightInPoints: 1440,
            displayFrame: secondaryScreenFrame,
            isCursorScreen: false,
            label: "screen2"
        )

        let parsedAnnotation = ParsedScreenAnnotation(
            kind: .box,
            target: .pixelRect(rect: CGRect(x: 640, y: 360, width: 100, height: 50), screenNumber: 2),
            label: "secondary element"
        )

        let resolvedAnnotations = CompanionManager.resolveAnnotationsToScreenRects(
            parsedAnnotations: [parsedAnnotation],
            inventory: nil,
            screenCaptures: [primaryCapture, secondaryCapture],
            allScreenFramesInAppKitCoordinates: [primaryScreenFrame, secondaryScreenFrame]
        )

        #expect(resolvedAnnotations.count == 1)
        let resolved = resolvedAnnotations[0]
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.origin.x - 2720) < 0.001)
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.origin.y - 620) < 0.001)
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.width - 200) < 0.001)
        #expect(abs(resolved.rectInAppKitGlobalCoordinates.height - 100) < 0.001)
        // Screen assignment should be the secondary display's frame
        #expect(resolved.displayFrameOfTargetScreen == secondaryScreenFrame)
    }

    /// A pixel-rect with an out-of-range screenNumber falls back to the cursor
    /// screen rather than crashing or dropping the annotation.
    @Test func pixelRectWithOutOfRangeScreenNumberFallsBackToCursorScreen() {
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursorCapture = makeTestScreenCapture(
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrame: primaryScreenFrame,
            isCursorScreen: true
        )

        // screenNumber: 5 is out of range (only 1 capture available)
        let parsedAnnotation = ParsedScreenAnnotation(
            kind: .highlight,
            target: .pixelRect(rect: CGRect(x: 100, y: 100, width: 50, height: 20), screenNumber: 5),
            label: nil
        )

        let resolvedAnnotations = CompanionManager.resolveAnnotationsToScreenRects(
            parsedAnnotations: [parsedAnnotation],
            inventory: nil,
            screenCaptures: [cursorCapture],
            allScreenFramesInAppKitCoordinates: [primaryScreenFrame]
        )

        // Should fall back to cursor screen — not drop the annotation
        #expect(resolvedAnnotations.count == 1)
        #expect(resolvedAnnotations[0].displayFrameOfTargetScreen == primaryScreenFrame)
    }

    // MARK: - Mixed annotations

    /// Multiple annotations in one response — some resolvable (element found,
    /// pixel-rect valid), some not (element ID missing) — should produce only
    /// the resolvable subset, in order.
    @Test func mixedAnnotationsProduceOnlyResolvableSubsetInOrder() {
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let element = makeTestElement(elementID: 2, appKitFrame: CGRect(x: 300, y: 500, width: 80, height: 20))
        let inventory = makeTestInventory(elements: [element])

        let cursorCapture = makeTestScreenCapture(
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrame: primaryScreenFrame,
            isCursorScreen: true
        )

        let parsedAnnotations: [ParsedScreenAnnotation] = [
            // Resolvable: element E2 exists in inventory
            ParsedScreenAnnotation(kind: .box,    target: .elementID(2),   label: "name field"),
            // Not resolvable: element E99 is not in inventory
            ParsedScreenAnnotation(kind: .circle, target: .elementID(99),  label: "missing"),
            // Resolvable: pixel rect on cursor screen
            ParsedScreenAnnotation(kind: .arrow,  target: .pixelRect(rect: CGRect(x: 100, y: 100, width: 60, height: 20), screenNumber: nil), label: "arrow"),
        ]

        let resolvedAnnotations = CompanionManager.resolveAnnotationsToScreenRects(
            parsedAnnotations: parsedAnnotations,
            inventory: inventory,
            screenCaptures: [cursorCapture],
            allScreenFramesInAppKitCoordinates: [primaryScreenFrame]
        )

        // Only 2 of 3 annotations are resolvable
        #expect(resolvedAnnotations.count == 2)
        #expect(resolvedAnnotations[0].kind == .box)
        #expect(resolvedAnnotations[0].label == "name field")
        #expect(resolvedAnnotations[1].kind == .arrow)
        #expect(resolvedAnnotations[1].label == "arrow")
    }

    // MARK: - Screen assignment for element-ID

    /// The displayFrameOfTargetScreen for an element-ID annotation should be the
    /// screen frame that contains the element's AppKit center.
    @Test func elementIDAnnotationIsAssignedToScreenContainingElementCenter() {
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let secondaryScreenFrame = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

        // Element on the secondary display
        let elementOnSecondary = makeTestElement(
            elementID: 7,
            appKitFrame: CGRect(x: 1800, y: 400, width: 200, height: 40)
        )
        let inventory = makeTestInventory(elements: [elementOnSecondary])

        let parsedAnnotation = ParsedScreenAnnotation(
            kind: .highlight,
            target: .elementID(7),
            label: "secondary element"
        )

        let resolvedAnnotations = CompanionManager.resolveAnnotationsToScreenRects(
            parsedAnnotations: [parsedAnnotation],
            inventory: inventory,
            screenCaptures: [],
            allScreenFramesInAppKitCoordinates: [primaryScreenFrame, secondaryScreenFrame]
        )

        #expect(resolvedAnnotations.count == 1)
        // Element center: (1800 + 200/2, 400 + 40/2) = (1900, 420)
        // 1900 is inside secondaryScreenFrame (x: 1440, width: 2560) → assigned to secondary
        #expect(resolvedAnnotations[0].displayFrameOfTargetScreen == secondaryScreenFrame)
    }

    // MARK: - Label preservation

    /// Labels should pass through resolution unchanged, including nil labels.
    @Test func nilLabelRemainsNilAfterResolution() {
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let element = makeTestElement(elementID: 1, appKitFrame: CGRect(x: 100, y: 200, width: 80, height: 24))
        let inventory = makeTestInventory(elements: [element])

        let parsedAnnotation = ParsedScreenAnnotation(
            kind: .circle,
            target: .elementID(1),
            label: nil  // No label provided
        )

        let resolvedAnnotations = CompanionManager.resolveAnnotationsToScreenRects(
            parsedAnnotations: [parsedAnnotation],
            inventory: inventory,
            screenCaptures: [],
            allScreenFramesInAppKitCoordinates: [primaryScreenFrame]
        )

        #expect(resolvedAnnotations.count == 1)
        #expect(resolvedAnnotations[0].label == nil)
    }
}

