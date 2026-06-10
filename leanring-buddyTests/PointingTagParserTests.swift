//
//  PointingTagParserTests.swift
//  leanring-buddyTests
//
//  Tests for CompanionManager.parsePointingCoordinates(from:) — the pure static
//  function that parses [POINT:...] tags from Claude's responses.
//
//  Three tag forms are tested:
//    [POINT:E<digits>(:label)?]          — element-ID form (U3, grounded pointing)
//    [POINT:x,y(:label)?(:screenN)?]     — legacy pixel-coordinate form (R3 fallback)
//    [POINT:none]                        — explicit no-pointing instruction
//
//  LEGACY REGRESSION CONTRACT
//  ──────────────────────────
//  The legacy regex behaviour is a hard boundary: any change to parsePointingCoordinates
//  that causes a legacy corpus case to change its result is a regression. The corpus
//  below encodes the ACTUAL behaviour of the regex as it existed before U3 landed:
//
//    [POINT:400,300:terminal:screen2]   → coord (400,300), label "terminal", screen 2
//    [POINT:400,300]                    → coord (400,300), label nil, screen nil
//    [POINT:none]                       → coord nil, label "none"
//    response with no tag               → coord nil, label nil, spoken = full text
//    tag not at end of response         → no match (end-anchored), full text spoken
//    [POINT:12,34:label with spaces]    → coord (12,34), label "label with spaces"
//    [POINT:abc]                        → no match (no comma, not "none"), full text spoken
//
//  PURE HELPER TESTS
//  ─────────────────
//  resolveElementIDToAppKitCenter and findScreenFrameContainingOrNearestToPoint are
//  also pure static functions and are tested here as a coherent unit with the parser.
//

import Testing
import CoreGraphics
@testable import leanring_buddy

struct PointingTagParserTests {

    // MARK: - Element-ID form: [POINT:E<digits>(:label)?]

    /// [POINT:E12:submit button] at end of response → elementID 12, label "submit button",
    /// spoken text excludes the tag.
    @Test func elementIDTagWithLabelParsesCorrectly() {
        let response = "click the button at the bottom of the form [POINT:E12:submit button]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.elementID == 12)
        #expect(result.elementLabel == "submit button")
        #expect(result.coordinate == nil)
        #expect(result.screenNumber == nil)
        #expect(result.spokenText == "click the button at the bottom of the form")
    }

    /// [POINT:E7] with no label → elementID 7, label nil, spoken text excludes the tag.
    @Test func elementIDTagWithoutLabelParsesCorrectly() {
        let response = "tap that button to proceed [POINT:E7]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.elementID == 7)
        #expect(result.elementLabel == nil)
        #expect(result.coordinate == nil)
        #expect(result.spokenText == "tap that button to proceed")
    }

    /// Larger element ID (three digits) is parsed correctly.
    @Test func elementIDTagWithLargeIDParsesCorrectly() {
        let response = "see this control [POINT:E142:settings panel]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.elementID == 142)
        #expect(result.elementLabel == "settings panel")
    }

    /// Label containing spaces and mixed case is preserved exactly.
    @Test func elementIDTagLabelWithSpacesIsPreservedExactly() {
        let response = "look here [POINT:E3:New Folder button]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.elementLabel == "New Folder button")
    }

    /// Trailing whitespace after the tag is trimmed from the spoken text (same as legacy).
    @Test func elementIDTagSpokenTextIsTrimmedOfWhitespace() {
        // Two trailing spaces after the tag
        let response = "click submit [POINT:E5:button]  "

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.elementID == 5)
        // The spoken text must not end with trailing whitespace
        #expect(result.spokenText == "click submit")
    }

    /// An element-ID tag in the MIDDLE of a response is not matched (end-anchored).
    @Test func elementIDTagInMiddleOfResponseIsIgnored() {
        let response = "[POINT:E4:foo] and then some more text here"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.elementID == nil)
        #expect(result.coordinate == nil)
        // Full text is spoken because no tag was found at end
        #expect(result.spokenText == response)
    }

    // MARK: - Legacy regression corpus: pixel-coordinate form

    /// [POINT:400,300:terminal:screen2] → coord (400,300), label "terminal", screen 2.
    /// This is the canonical multi-screen example from the system prompt.
    @Test func legacyPixelCoordinateWithLabelAndScreenNumberParsesCorrectly() {
        let response = "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.coordinate == CGPoint(x: 400, y: 300))
        #expect(result.elementLabel == "terminal")
        #expect(result.screenNumber == 2)
        #expect(result.elementID == nil)
        #expect(result.spokenText == "that's over on your other monitor — see the terminal window?")
    }

    /// [POINT:400,300] with no label or screen → coord (400,300), label nil, screen nil.
    @Test func legacyPixelCoordinateWithoutLabelOrScreenParsesCorrectly() {
        let response = "click there [POINT:400,300]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.coordinate == CGPoint(x: 400, y: 300))
        #expect(result.elementLabel == nil)
        #expect(result.screenNumber == nil)
        #expect(result.elementID == nil)
        #expect(result.spokenText == "click there")
    }

    /// [POINT:none] → coord nil, label "none", elementID nil.
    @Test func noneTagProducesNilCoordinateAndNoneLabel() {
        let response = "html is the skeleton of every web page [POINT:none]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.coordinate == nil)
        #expect(result.elementLabel == "none")
        #expect(result.elementID == nil)
        #expect(result.spokenText == "html is the skeleton of every web page")
    }

    /// A response with no tag at all → full text spoken, all fields nil.
    @Test func responseWithNoTagProducesFullSpokenTextAndAllNilFields() {
        let response = "the mitochondria is the powerhouse of the cell"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.coordinate == nil)
        #expect(result.elementLabel == nil)
        #expect(result.screenNumber == nil)
        #expect(result.elementID == nil)
        #expect(result.spokenText == response)
    }

    /// A tag that is NOT at the end of the response is silently ignored (end-anchored
    /// regex). The full response text is spoken as-is.
    @Test func legacyPixelTagInMiddleOfResponseIsNotMatched() {
        let response = "[POINT:400,300:terminal:screen2] this text appears after the tag"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.coordinate == nil)
        #expect(result.elementID == nil)
        #expect(result.spokenText == response)
    }

    /// [POINT:12,34:label with spaces] → the label group in the legacy regex is
    /// [^\]:\s][^\]:]*? which allows spaces inside the label as long as the first
    /// character is not whitespace, colon, or close-bracket.
    @Test func legacyPixelCoordinateWithSpacedLabelParsesCorrectly() {
        let response = "look here [POINT:12,34:label with spaces]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.coordinate == CGPoint(x: 12, y: 34))
        #expect(result.elementLabel == "label with spaces")
        #expect(result.elementID == nil)
    }

    /// [POINT:abc] is malformed — "abc" is neither "none" nor a pair of digits,
    /// so neither regex branch matches. The full text is spoken.
    @Test func malformedTagWithAlphabeticBodyIsRejectedCompletely() {
        let response = "some response [POINT:abc]"

        let result = CompanionManager.parsePointingCoordinates(from: response)

        #expect(result.coordinate == nil)
        #expect(result.elementID == nil)
        #expect(result.spokenText == response)
    }

    // MARK: - Screen-assignment helper: findScreenFrameContainingOrNearestToPoint

    /// A point inside screen 2's frame is assigned to screen 2, not screen 1.
    @Test func screenAssignmentSelectsScreenContainingPoint() {
        let screen1Frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screen2Frame = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

        // A point clearly inside screen 2
        let pointInsideScreen2 = CGPoint(x: 2000, y: 500)

        let assignedFrame = CompanionManager.findScreenFrameContainingOrNearestToPoint(
            point: pointInsideScreen2,
            allScreenFramesInAppKitCoordinates: [screen1Frame, screen2Frame]
        )

        #expect(assignedFrame == screen2Frame)
    }

    /// A point that is outside both screen frames is assigned to the NEAREST screen,
    /// not dropped or assigned to an arbitrary screen.
    @Test func screenAssignmentFallsBackToNearestScreenWhenPointIsOutsideAll() {
        let screen1Frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screen2Frame = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

        // A point to the right of both screens — closer to screen2's right edge
        // than to screen1's right edge
        let pointBeyondScreen2 = CGPoint(x: 5000, y: 500)

        let assignedFrame = CompanionManager.findScreenFrameContainingOrNearestToPoint(
            point: pointBeyondScreen2,
            allScreenFramesInAppKitCoordinates: [screen1Frame, screen2Frame]
        )

        // screen2 ends at x=4000; screen1 ends at x=1440. Point at x=5000 is
        // 1000 pts from screen2's edge and 3560 pts from screen1's edge.
        #expect(assignedFrame == screen2Frame)
    }

    /// A single screen always gets assigned, regardless of where the point is.
    @Test func screenAssignmentWithSingleScreenAlwaysReturnsThatScreen() {
        let onlyScreenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Point completely off screen
        let offScreenPoint = CGPoint(x: 9999, y: 9999)

        let assignedFrame = CompanionManager.findScreenFrameContainingOrNearestToPoint(
            point: offScreenPoint,
            allScreenFramesInAppKitCoordinates: [onlyScreenFrame]
        )

        #expect(assignedFrame == onlyScreenFrame)
    }

    /// A point exactly on the boundary of a screen is considered to be inside it
    /// (distance zero).
    @Test func screenAssignmentPointOnBoundaryIsAssignedToThatScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Point on the right edge of the screen
        let boundaryPoint = CGPoint(x: 1440, y: 450)

        let assignedFrame = CompanionManager.findScreenFrameContainingOrNearestToPoint(
            point: boundaryPoint,
            allScreenFramesInAppKitCoordinates: [screenFrame]
        )

        #expect(assignedFrame == screenFrame)
    }

    // MARK: - Element-ID lookup resolution: resolveElementIDToAppKitCenter

    /// When the inventory is nil (AX walk not yet wired), resolution returns nil.
    @Test func elementIDResolutionWithNilInventoryReturnsNil() {
        let resolvedCenter = CompanionManager.resolveElementIDToAppKitCenter(
            elementID: 5,
            inventory: nil,
            allScreenFramesInAppKitCoordinates: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        )

        #expect(resolvedCenter == nil)
    }

    /// When the element ID is not present in the inventory, resolution returns nil.
    @Test func elementIDResolutionWithUnknownIDReturnsNil() {
        let inventory = makeMinimalInventory(elements: [
            makeAccessibleElement(elementID: 1, appKitFrame: CGRect(x: 100, y: 200, width: 80, height: 30))
        ])

        let resolvedCenter = CompanionManager.resolveElementIDToAppKitCenter(
            elementID: 99,
            inventory: inventory,
            allScreenFramesInAppKitCoordinates: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        )

        #expect(resolvedCenter == nil)
    }

    /// When the element ID is found, resolution returns the exact AppKit center of
    /// that element's frame.
    ///
    /// Element frame: x=100, y=200, width=80, height=30.
    /// Expected center: x = 100 + 80/2 = 140, y = 200 + 30/2 = 215.
    @Test func elementIDResolutionWithKnownIDReturnsAppKitCenter() {
        let elementFrame = CGRect(x: 100, y: 200, width: 80, height: 30)
        let inventory = makeMinimalInventory(elements: [
            makeAccessibleElement(elementID: 7, appKitFrame: elementFrame)
        ])

        let resolvedCenter = CompanionManager.resolveElementIDToAppKitCenter(
            elementID: 7,
            inventory: inventory,
            allScreenFramesInAppKitCoordinates: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        )

        #expect(resolvedCenter != nil)
        #expect(abs((resolvedCenter?.x ?? 0) - 140) < 0.001)
        #expect(abs((resolvedCenter?.y ?? 0) - 215) < 0.001)
    }

    /// Multiple elements in the inventory — the correct one is selected by ID.
    @Test func elementIDResolutionSelectsCorrectElementAmongMultiple() {
        let frameForElement3 = CGRect(x: 400, y: 600, width: 120, height: 40)
        let inventory = makeMinimalInventory(elements: [
            makeAccessibleElement(elementID: 1, appKitFrame: CGRect(x: 10, y: 10, width: 50, height: 20)),
            makeAccessibleElement(elementID: 3, appKitFrame: frameForElement3),
            makeAccessibleElement(elementID: 5, appKitFrame: CGRect(x: 700, y: 800, width: 60, height: 25))
        ])

        let resolvedCenter = CompanionManager.resolveElementIDToAppKitCenter(
            elementID: 3,
            inventory: inventory,
            allScreenFramesInAppKitCoordinates: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        )

        // Center of CGRect(x:400, y:600, width:120, height:40) = (460, 620)
        #expect(resolvedCenter != nil)
        #expect(abs((resolvedCenter?.x ?? 0) - 460) < 0.001)
        #expect(abs((resolvedCenter?.y ?? 0) - 620) < 0.001)
    }
}

// MARK: - Test Helpers

/// Creates a minimal AccessibilityElementInventory wrapping the provided elements.
/// All metadata fields are set to empty / placeholder values — the tests only
/// exercise element lookup and center computation, not metadata.
private func makeMinimalInventory(elements: [AccessibleElement]) -> AccessibilityElementInventory {
    return AccessibilityElementInventory(
        elements: elements,
        frontmostAppName: "TestApp",
        frontmostAppBundleID: "com.test.app",
        captureOutcome: .captured
    )
}

/// Creates an AccessibleElement with the given ID and AppKit frame. All other
/// fields are set to inert placeholder values — the tests only need the ID and frame.
///
/// NOTE: AXUIElementCreateApplication(0) is used to produce a non-nil AXUIElement
/// handle for the `axElementHandle` field, which is a non-optional stored property.
/// Process ID 0 is the kernel — the handle will never be used for real AX calls in
/// unit tests, it exists only to satisfy the struct's requirements.
private func makeAccessibleElement(elementID: Int, appKitFrame: CGRect) -> AccessibleElement {
    return AccessibleElement(
        elementID: elementID,
        role: "AXButton",
        subrole: nil,
        title: "Test Button \(elementID)",
        cgFrame: .zero,   // CG frame not needed for center resolution tests
        appKitFrame: appKitFrame,
        axElementHandle: AXUIElementCreateApplication(0),
        owningProcessID: 0
    )
}
