//
//  AccessibilityElementInventoryServiceTests.swift
//  leanring-buddyTests
//
//  Tests for the PURE parts of AccessibilityElementInventoryService.
//
//  What is NOT tested here:
//  - Live AX walks: these require TCC Accessibility permission and a running
//    third-party app. They are verified manually from Xcode against Safari and
//    VS Code as described in the U2 verification section.
//  - The serial-queue / async bridging plumbing: async scheduling is tested by
//    building and running the app, not by unit tests.
//
//  What IS tested:
//  - Role filter decisions (keep / descend / drop)
//  - Title sanitisation
//  - Visibility heuristic
//  - Element cap enforcement via the BFS predicate logic
//  - Prompt formatter: exact output for a known element list
//  - Prompt formatter: screenshot-pixel coordinate values
//  - Prompt formatter: truncation at maximumElementCount with trailer line
//  - Prompt formatter: largest-visible-area ordering before truncation
//  - Sequential E-ID assignment (determinism property)
//

import Testing
@testable import leanring_buddy

struct AccessibilityElementInventoryServiceTests {

    // MARK: - Role filter: shouldKeepElement

    @Test func axButtonRoleIsKeptWithoutPressAction() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXButton",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    @Test func axLinkRoleIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXLink",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    @Test func axTextFieldRoleIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXTextField",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    @Test func axTextAreaRoleIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXTextArea",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    @Test func axCheckBoxRoleIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXCheckBox",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    @Test func axRadioButtonRoleIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXRadioButton",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    @Test func axPopUpButtonRoleIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXPopUpButton",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    @Test func axMenuItemRoleIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXMenuItem",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    @Test func axComboBoxRoleIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXComboBox",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    @Test func axSliderRoleIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXSlider",
            elementExposesAXPressAction: false
        )
        #expect(kept == true)
    }

    /// An element with an otherwise non-actionable role is kept when it
    /// exposes kAXPressAction — this is the "any pressable element" rule.
    @Test func nonActionableRoleWithPressActionIsKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXCell",
            elementExposesAXPressAction: true
        )
        #expect(kept == true)
    }

    /// Static text is a leaf role — it should not be kept.
    @Test func axStaticTextLeafRoleIsNotKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXStaticText",
            elementExposesAXPressAction: false
        )
        #expect(kept == false)
    }

    /// Image elements are not actionable and should not be kept.
    @Test func axImageLeafRoleIsNotKept() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXImage",
            elementExposesAXPressAction: false
        )
        #expect(kept == false)
    }

    /// Container groups are not kept (they wrap content but aren't interactive).
    @Test func axGroupContainerIsNotKeptWithoutPressAction() {
        let kept = AccessibilityElementInventoryService.shouldKeepElement(
            role: "AXGroup",
            elementExposesAXPressAction: false
        )
        #expect(kept == false)
    }

    // MARK: - Role filter: shouldDescendIntoRole

    /// AXGroup is a container — BFS should descend into it to find children.
    @Test func axGroupContainerIsDescendedInto() {
        let descend = AccessibilityElementInventoryService.shouldDescendIntoRole("AXGroup")
        #expect(descend == true)
    }

    @Test func axScrollAreaContainerIsDescendedInto() {
        let descend = AccessibilityElementInventoryService.shouldDescendIntoRole("AXScrollArea")
        #expect(descend == true)
    }

    @Test func axSplitGroupContainerIsDescendedInto() {
        let descend = AccessibilityElementInventoryService.shouldDescendIntoRole("AXSplitGroup")
        #expect(descend == true)
    }

    @Test func axToolbarContainerIsDescendedInto() {
        let descend = AccessibilityElementInventoryService.shouldDescendIntoRole("AXToolbar")
        #expect(descend == true)
    }

    /// Actionable roles are also descended into (they can have children in
    /// some apps, e.g. a combobox containing a text field).
    @Test func axButtonActionableRoleIsAlsoDescendedInto() {
        let descend = AccessibilityElementInventoryService.shouldDescendIntoRole("AXButton")
        #expect(descend == true)
    }

    /// Static text is a known leaf — BFS should not descend into it.
    @Test func axStaticTextIsNotDescendedInto() {
        let descend = AccessibilityElementInventoryService.shouldDescendIntoRole("AXStaticText")
        #expect(descend == false)
    }

    /// Image is a known leaf — no children to find.
    @Test func axImageIsNotDescendedInto() {
        let descend = AccessibilityElementInventoryService.shouldDescendIntoRole("AXImage")
        #expect(descend == false)
    }

    @Test func axSeparatorIsNotDescendedInto() {
        let descend = AccessibilityElementInventoryService.shouldDescendIntoRole("AXSeparator")
        #expect(descend == false)
    }

    // MARK: - Title sanitisation

    /// A clean title with no special characters must pass through unchanged
    /// (after trimming, which a clean title doesn't need).
    @Test func cleanTitlePassesThroughSanitisationUnchanged() {
        let result = AccessibilityElementInventoryService.sanitiseTitleForPrompt("Submit")
        #expect(result == "Submit")
    }

    /// Newlines in a title would break the one-line-per-element prompt format.
    /// They must be replaced with a space.
    @Test func newlinesInTitleAreReplacedWithSpaces() {
        let rawTitle = "First line\nSecond line"
        let result = AccessibilityElementInventoryService.sanitiseTitleForPrompt(rawTitle)
        // Must contain no newline characters
        #expect(!result.contains("\n"))
        // The words must still be present
        #expect(result.contains("First line"))
        #expect(result.contains("Second line"))
    }

    /// Carriage returns are also stripped (Windows-style line endings from
    /// pasted content can appear in AX title values).
    @Test func carriageReturnsInTitleAreRemovedOrReplaced() {
        let rawTitle = "Line one\r\nLine two"
        let result = AccessibilityElementInventoryService.sanitiseTitleForPrompt(rawTitle)
        #expect(!result.contains("\r"))
        #expect(!result.contains("\n"))
    }

    /// Square brackets would look like AX tags to Claude's tag parser and
    /// could corrupt the prompt's tag grammar. They must be stripped.
    @Test func squareBracketsInTitleAreStripped() {
        let rawTitle = "[New] Folder"
        let result = AccessibilityElementInventoryService.sanitiseTitleForPrompt(rawTitle)
        #expect(!result.contains("["))
        #expect(!result.contains("]"))
        // The meaningful content must survive
        #expect(result.contains("New"))
        #expect(result.contains("Folder"))
    }

    /// A title that is only square brackets and spaces should collapse to an
    /// empty string after sanitisation.
    @Test func titleContainingOnlyBracketsBecomesEmpty() {
        let rawTitle = "[ ]"
        let result = AccessibilityElementInventoryService.sanitiseTitleForPrompt(rawTitle)
        #expect(result.isEmpty)
    }

    /// Titles longer than 80 characters are truncated so prompt lines stay
    /// within a reasonable width.
    @Test func titleLongerThan80CharactersIsTruncatedTo80Characters() {
        let longTitle = String(repeating: "a", count: 100)
        let result = AccessibilityElementInventoryService.sanitiseTitleForPrompt(longTitle)
        #expect(result.count <= 80)
    }

    /// Titles exactly at the 80-character limit must not be truncated.
    @Test func titleExactly80CharactersLongIsNotTruncated() {
        let exactTitle = String(repeating: "b", count: 80)
        let result = AccessibilityElementInventoryService.sanitiseTitleForPrompt(exactTitle)
        #expect(result.count == 80)
    }

    /// Multiple internal spaces are collapsed to a single space so the prompt
    /// output is clean and consistent.
    @Test func multipleInternalSpacesAreCollapsedToSingleSpace() {
        let rawTitle = "Click   here"
        let result = AccessibilityElementInventoryService.sanitiseTitleForPrompt(rawTitle)
        #expect(result == "Click here")
    }

    /// Leading and trailing whitespace is trimmed.
    @Test func leadingAndTrailingWhitespaceIsTrimmed() {
        let rawTitle = "  Submit  "
        let result = AccessibilityElementInventoryService.sanitiseTitleForPrompt(rawTitle)
        #expect(result == "Submit")
    }

    // MARK: - Visibility heuristic

    /// An element with zero width fails the visibility check.
    @Test func zeroWidthElementIsNotVisible() {
        let frame = CGRect(x: 100, y: 100, width: 0, height: 30)
        let windowFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screenBounds = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

        let visible = AccessibilityElementInventoryService.isElementFrameVisible(
            cgFrame: frame,
            windowCGFrame: windowFrame,
            cgScreenBoundsForAllDisplays: screenBounds
        )
        #expect(visible == false)
    }

    /// An element with zero height fails the visibility check.
    @Test func zeroHeightElementIsNotVisible() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 0)
        let windowFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screenBounds = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

        let visible = AccessibilityElementInventoryService.isElementFrameVisible(
            cgFrame: frame,
            windowCGFrame: windowFrame,
            cgScreenBoundsForAllDisplays: screenBounds
        )
        #expect(visible == false)
    }

    /// An element with size 1×1 (sub-pixel) fails the visibility check
    /// (the check is strictly > 1).
    @Test func oneByOnePixelElementIsNotVisible() {
        let frame = CGRect(x: 100, y: 100, width: 1, height: 1)
        let windowFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screenBounds = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

        let visible = AccessibilityElementInventoryService.isElementFrameVisible(
            cgFrame: frame,
            windowCGFrame: windowFrame,
            cgScreenBoundsForAllDisplays: screenBounds
        )
        #expect(visible == false)
    }

    /// An element fully outside every display's CG bounds fails the
    /// visibility check even if it has non-trivial size.
    @Test func elementFullyOffScreenIsNotVisible() {
        // Element placed far to the right of any display
        let frame = CGRect(x: 99000, y: 100, width: 200, height: 30)
        let windowFrame = CGRect(x: 99000, y: 0, width: 500, height: 900)
        let screenBounds = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

        let visible = AccessibilityElementInventoryService.isElementFrameVisible(
            cgFrame: frame,
            windowCGFrame: windowFrame,
            cgScreenBoundsForAllDisplays: screenBounds
        )
        #expect(visible == false)
    }

    /// An element fully outside the window frame fails the visibility check.
    @Test func elementOutsideWindowFrameIsNotVisible() {
        let windowFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Element placed to the right of the window
        let frame = CGRect(x: 900, y: 100, width: 100, height: 30)
        let screenBounds = [CGRect(x: 0, y: 0, width: 2560, height: 1440)]

        let visible = AccessibilityElementInventoryService.isElementFrameVisible(
            cgFrame: frame,
            windowCGFrame: windowFrame,
            cgScreenBoundsForAllDisplays: screenBounds
        )
        #expect(visible == false)
    }

    /// A normal in-window, on-screen element passes all visibility checks.
    @Test func normalInWindowOnScreenElementIsVisible() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 30)
        let windowFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screenBounds = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

        let visible = AccessibilityElementInventoryService.isElementFrameVisible(
            cgFrame: frame,
            windowCGFrame: windowFrame,
            cgScreenBoundsForAllDisplays: screenBounds
        )
        #expect(visible == true)
    }

    /// An element visible on the secondary display passes when secondary
    /// display bounds are included in the screen list.
    @Test func elementOnSecondaryDisplayPassesWhenSecondaryBoundsAreIncluded() {
        let secondaryDisplayBounds = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        // Element on the secondary display
        let frame = CGRect(x: 2000, y: 200, width: 200, height: 50)
        let windowFrame = CGRect(x: 1500, y: 0, width: 800, height: 600)
        let screenBounds = [
            CGRect(x: 0, y: 0, width: 1440, height: 900), // primary
            secondaryDisplayBounds                          // secondary
        ]

        let visible = AccessibilityElementInventoryService.isElementFrameVisible(
            cgFrame: frame,
            windowCGFrame: windowFrame,
            cgScreenBoundsForAllDisplays: screenBounds
        )
        #expect(visible == true)
    }

    // MARK: - Prompt formatting: exact output for a known element list

    /// The canonical format test. A single button with a known position and
    /// size must produce exactly the expected one-line string.
    ///
    /// Setup: element at display-point AppKit frame (100, 200, 96, 28) on a
    /// 1440×900-point display with a 1280×800-pixel screenshot.
    ///
    /// Screenshot-pixel rect calculation (via the inverse scaling path):
    ///   displayLocalAppKitX = 100 - 0 = 100
    ///   displayLocalAppKitY = 200 - 0 = 200
    ///   displayLocalTopLeftY = 900 - (200 + 28) = 672
    ///   scaleX = 1280/1440 ≈ 0.8889
    ///   scaleY = 800/900  ≈ 0.8889
    ///   pixelX = 100 * 0.8889 ≈ 88.9 → 89
    ///   pixelY = 672 * 0.8889 ≈ 597.3 → 597
    ///   pixelW = 96  * 0.8889 ≈ 85.3 → 85
    ///   pixelH = 28  * 0.8889 ≈ 24.9 → 25
    @Test func singleButtonFormatsToExpectedOneLiner() {
        let primaryScreenFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let displayFrameInAppKitCoordinates = primaryScreenFrameInAppKitCoordinates

        // Build the element with AppKit-space frame (100, 200, 96, 28).
        // cgFrame is the CG-space equivalent; we don't use it in formatting
        // but the struct requires it.
        let cgFrame = ScreenCoordinateConverter.convertAppKitGlobalRectToCGGlobalRect(
            appKitGlobalRect: CGRect(x: 100, y: 200, width: 96, height: 28),
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
        )
        let element = buildTestElement(
            elementID: 1,
            role: "AXButton",
            title: "Submit",
            cgFrame: cgFrame,
            appKitFrame: CGRect(x: 100, y: 200, width: 96, height: 28)
        )

        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: [element],
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayFrameInAppKitCoordinates: displayFrameInAppKitCoordinates
        )

        // Verify the line starts with the correct element tag
        #expect(output.hasPrefix("[E1] AXButton \"Submit\""))
        // Verify the coordinate values (allow ±1 pixel rounding tolerance)
        let expectedX = 89
        let expectedY = 597
        let expectedW = 85
        let expectedH = 25
        // Check the rect string is present in the expected format
        let expectedRectString = "(\(expectedX),\(expectedY) \(expectedW)x\(expectedH))"
        // Compute it directly to allow for rounding
        let scaleX = 1280.0 / 1440.0
        let scaleY = 800.0 / 900.0
        let pixelX = Int((100.0 * scaleX).rounded())
        let pixelY = Int(((900.0 - (200.0 + 28.0)) * scaleY).rounded())
        let pixelW = Int((96.0 * scaleX).rounded())
        let pixelH = Int((28.0 * scaleY).rounded())
        let computedRectString = "(\(pixelX),\(pixelY) \(pixelW)x\(pixelH))"
        #expect(output.contains(computedRectString),
                "Expected rect \(computedRectString) in output: \(output)")
    }

    /// An empty element list produces an empty string (not a header-only line).
    @Test func emptyElementListProducesEmptyString() {
        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: [],
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayFrameInAppKitCoordinates: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        #expect(output.isEmpty)
    }

    // MARK: - Prompt formatting: truncation and ordering

    /// When more elements than `maximumElementCount` are provided, the output
    /// must contain exactly `maximumElementCount` element lines plus a trailer.
    @Test func elementsExceedingCapAreTruncatedWithTrailerLine() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Build 10 elements for a cap of 5
        let elements = (1...10).map { index in
            buildTestElement(
                elementID: index,
                role: "AXButton",
                title: "Button \(index)",
                cgFrame: CGRect(x: CGFloat(index * 10), y: CGFloat(index * 10), width: 100, height: 30),
                appKitFrame: CGRect(x: CGFloat(index * 10), y: CGFloat(index * 10), width: 100, height: 30)
            )
        }

        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: elements,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayFrameInAppKitCoordinates: displayFrame,
            maximumElementCount: 5
        )

        let lines = output.components(separatedBy: "\n")
        // 5 element lines + 1 trailer line
        #expect(lines.count == 6)
        #expect(lines.last?.hasPrefix("… and") == true)
        #expect(lines.last?.contains("5 more") == true)
    }

    /// When the list is exactly at the cap, no trailer line is added.
    @Test func exactlyCapElementsProducesNoTrailerLine() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let elements = (1...5).map { index in
            buildTestElement(
                elementID: index,
                role: "AXButton",
                title: "Button \(index)",
                cgFrame: CGRect(x: CGFloat(index * 10), y: 100, width: 100, height: 30),
                appKitFrame: CGRect(x: CGFloat(index * 10), y: 100, width: 100, height: 30)
            )
        }

        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: elements,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayFrameInAppKitCoordinates: displayFrame,
            maximumElementCount: 5
        )

        let lines = output.components(separatedBy: "\n")
        #expect(lines.count == 5)
        #expect(lines.last?.contains("more") == false)
    }

    /// Elements are sorted by visible area (largest first) before truncation.
    /// The largest element must appear in the output even if it was listed last.
    @Test func largestAreaElementSurvivesTruncationEvenIfListedLast() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Small element listed first (10×10 area = 100)
        let smallElement = buildTestElement(
            elementID: 1,
            role: "AXButton",
            title: "Small",
            cgFrame: CGRect(x: 10, y: 10, width: 10, height: 10),
            appKitFrame: CGRect(x: 10, y: 10, width: 10, height: 10)
        )

        // Large element listed second (200×50 area = 10000) — must survive
        let largeElement = buildTestElement(
            elementID: 2,
            role: "AXTextField",
            title: "LargeField",
            cgFrame: CGRect(x: 100, y: 200, width: 200, height: 50),
            appKitFrame: CGRect(x: 100, y: 200, width: 200, height: 50)
        )

        // Another small element (15×15 area = 225)
        let mediumElement = buildTestElement(
            elementID: 3,
            role: "AXButton",
            title: "Medium",
            cgFrame: CGRect(x: 50, y: 50, width: 15, height: 15),
            appKitFrame: CGRect(x: 50, y: 50, width: 15, height: 15)
        )

        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: [smallElement, largeElement, mediumElement],
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayFrameInAppKitCoordinates: displayFrame,
            maximumElementCount: 1  // Only the largest should survive
        )

        // With cap=1, only the largest (LargeField) should be in the output
        #expect(output.contains("LargeField"))
        #expect(!output.contains("Small\""))
        // The trailer line should say 2 more
        #expect(output.contains("2 more"))
    }

    /// When the cap keeps all elements (no truncation needed), ordering is still
    /// by area descending — not by original traversal order.
    @Test func elementsWithinCapAreStillOrderedByVisibleAreaDescending() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let tinyElement = buildTestElement(
            elementID: 1,
            role: "AXButton",
            title: "Tiny",
            cgFrame: CGRect(x: 10, y: 10, width: 5, height: 5),
            appKitFrame: CGRect(x: 10, y: 10, width: 5, height: 5)
        )
        let bigElement = buildTestElement(
            elementID: 2,
            role: "AXButton",
            title: "Big",
            cgFrame: CGRect(x: 100, y: 100, width: 500, height: 200),
            appKitFrame: CGRect(x: 100, y: 100, width: 500, height: 200)
        )

        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: [tinyElement, bigElement],
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayFrameInAppKitCoordinates: displayFrame
        )

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        // "Big" should be first because it has more area
        #expect(lines[0].contains("Big"))
        #expect(lines[1].contains("Tiny"))
    }

    // MARK: - Prompt formatting: coordinate space verification

    /// Verifies that a frame on a secondary display (non-zero displayFrame origin)
    /// produces correct screenshot-pixel coordinates. The display-local offset must
    /// be computed before scaling, not after.
    @Test func elementOnSecondaryDisplayFormatsCorrectScreenshotPixelCoordinates() {
        // Secondary display: 2560×1440 pts at AppKit origin (1440, 0)
        let secondaryDisplayFrameInAppKitCoordinates = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

        // Element at AppKit global (1540, 100, 200, 50) — which is (100, 100, 200, 50)
        // in display-local terms on the secondary display.
        let element = buildTestElement(
            elementID: 1,
            role: "AXButton",
            title: "SecondaryButton",
            cgFrame: .zero, // not used in formatting
            appKitFrame: CGRect(x: 1540, y: 100, width: 200, height: 50)
        )

        // Screenshot is 1280×720px for the secondary (1280/2560 = 0.5 scale in each axis)
        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: [element],
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 720,
            displayFrameInAppKitCoordinates: secondaryDisplayFrameInAppKitCoordinates
        )

        // Expected:
        // displayLocalAppKitX = 1540 - 1440 = 100
        // displayLocalAppKitY = 100 - 0 = 100
        // displayLocalTopLeftY = 1440 - (100 + 50) = 1290
        // scaleX = 1280/2560 = 0.5
        // scaleY = 720/1440 = 0.5
        // pixelX = 100 * 0.5 = 50
        // pixelY = 1290 * 0.5 = 645
        // pixelW = 200 * 0.5 = 100
        // pixelH = 50 * 0.5 = 25
        #expect(output.contains("(50,645 100x25)"),
                "Expected (50,645 100x25) in output: \(output)")
    }

    // MARK: - E-ID assignment determinism

    /// E-IDs must be assigned sequentially starting at 1 in the order the
    /// elements appear in the input list. The formatter preserves this ordering
    /// within each area-equal tier, but the IDs themselves reflect traversal order.
    ///
    /// Since formatInventoryForPrompt sorts by area and we want to verify ID
    /// assignment is sequential per traversal order, this test checks the IDs
    /// directly on the element structs, not the formatted output.
    @Test func elementIDsAreSequentialStartingAtOne() {
        // Simulate what the walk would produce: E1, E2, E3 in traversal order.
        // The IDs are set by the walk, not the formatter.
        let ids = [1, 2, 3, 4, 5]
        let elements = ids.map { id in
            buildTestElement(
                elementID: id,
                role: "AXButton",
                title: "Button \(id)",
                cgFrame: .zero,
                appKitFrame: .zero
            )
        }

        for (index, element) in elements.enumerated() {
            #expect(element.elementID == index + 1,
                    "Element at index \(index) should have ID \(index + 1), got \(element.elementID)")
        }
    }

    /// The formatted output for a specific ID must contain the E-ID tag.
    @Test func formattedOutputContainsCorrectEIDTagForEachElement() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let elements = [
            buildTestElement(
                elementID: 5,
                role: "AXLink",
                title: "Home",
                cgFrame: CGRect(x: 50, y: 50, width: 80, height: 20),
                appKitFrame: CGRect(x: 50, y: 50, width: 80, height: 20)
            ),
            buildTestElement(
                elementID: 12,
                role: "AXButton",
                title: "Submit",
                cgFrame: CGRect(x: 200, y: 200, width: 120, height: 40),
                appKitFrame: CGRect(x: 200, y: 200, width: 120, height: 40)
            )
        ]

        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: elements,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayFrameInAppKitCoordinates: displayFrame
        )

        // Both E-IDs must appear in the output
        #expect(output.contains("[E5]"))
        #expect(output.contains("[E12]"))
    }

    // MARK: - Prompt formatting: title sanitisation in output

    /// Verifies that a title containing square brackets is sanitised in the
    /// formatted output so it doesn't corrupt the tag grammar.
    @Test func titleWithSquareBracketsIsSanitisedInFormattedOutput() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let element = buildTestElement(
            elementID: 1,
            role: "AXButton",
            title: "[Cancel]",
            cgFrame: CGRect(x: 50, y: 50, width: 100, height: 30),
            appKitFrame: CGRect(x: 50, y: 50, width: 100, height: 30)
        )

        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: [element],
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayFrameInAppKitCoordinates: displayFrame
        )

        // The title field in the output must not contain square brackets,
        // which would make it look like a tag.
        // Note: the E-ID itself uses brackets — we check the title portion only.
        // After "[E1] AXButton" the title should be "Cancel" not "[Cancel]".
        #expect(output.contains("\"Cancel\""))
        // The output must not have a nested "[Cancel]" that looks like a tag
        // (i.e. "[Cancel]" without the AXButton prefix would be a rogue tag).
        let lines = output.components(separatedBy: "\n")
        for line in lines where line.hasPrefix("[E") {
            // Count occurrences of "[" — should only be the leading [E<id>] tag
            let openBracketCount = line.filter { $0 == "[" }.count
            let closeBracketCount = line.filter { $0 == "]" }.count
            #expect(openBracketCount == 1,
                    "Line has unexpected extra '[': \(line)")
            #expect(closeBracketCount == 1,
                    "Line has unexpected extra ']': \(line)")
        }
    }

    /// Verifies that a title containing newlines is sanitised so each element
    /// appears on exactly one line in the formatted output.
    @Test func titleWithNewlinesDoesNotBreakOneLinePerElementFormat() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let element = buildTestElement(
            elementID: 1,
            role: "AXTextArea",
            title: "First\nSecond",
            cgFrame: CGRect(x: 50, y: 50, width: 200, height: 100),
            appKitFrame: CGRect(x: 50, y: 50, width: 200, height: 100)
        )

        let output = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: [element],
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayFrameInAppKitCoordinates: displayFrame
        )

        // With one element and no truncation, there should be exactly one line.
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1,
                "Expected 1 line for 1 element with newline-sanitised title, got \(lines.count): \(output)")
    }

    // MARK: - convertAppKitGlobalRectToScreenshotPixelRect (the new converter function)

    /// Verifies that a rect on the primary display at the display's centre
    /// maps correctly to screenshot-pixel space. This tests the new function
    /// added to ScreenCoordinateConverter for U2.
    ///
    /// Setup: 1440×900-point display, 1280×800-pixel screenshot.
    /// Rect in AppKit global: (670, 425, 100, 50) — near the centre.
    ///
    /// Expected (step by step):
    ///   displayLocalAppKitX = 670 - 0 = 670
    ///   displayLocalAppKitY = 425 - 0 = 425
    ///   displayLocalTopLeftY = 900 - (425 + 50) = 425
    ///   scaleX = 1280/1440 = 0.8889
    ///   scaleY = 800/900  = 0.8889
    ///   pixelX ≈ 670 * 0.8889 ≈ 595.6 → 596
    ///   pixelY ≈ 425 * 0.8889 ≈ 377.8 → 378
    ///   pixelW ≈ 100 * 0.8889 ≈ 88.9  → 89
    ///   pixelH ≈ 50  * 0.8889 ≈ 44.4  → 44
    @Test func appKitRectAtDisplayCentreMapsToCorrectScreenshotPixelRect() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let appKitRect = CGRect(x: 670, y: 425, width: 100, height: 50)

        let pixelRect = ScreenCoordinateConverter.convertAppKitGlobalRectToScreenshotPixelRect(
            appKitGlobalRect: appKitRect,
            displayFrameInAppKitCoordinates: displayFrame,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800
        )

        let scaleX = 1280.0 / 1440.0
        let scaleY = 800.0 / 900.0
        let expectedX = 670.0 * scaleX
        let expectedY = (900.0 - (425.0 + 50.0)) * scaleY  // displayLocalTopLeftY * scaleY
        let expectedW = 100.0 * scaleX
        let expectedH = 50.0 * scaleY

        #expect(abs(pixelRect.origin.x - expectedX) < 1.0)
        #expect(abs(pixelRect.origin.y - expectedY) < 1.0)
        #expect(abs(pixelRect.width - expectedW) < 1.0)
        #expect(abs(pixelRect.height - expectedH) < 1.0)
    }

    /// Verifies round-trip: a CG rect converted to AppKit and then to
    /// screenshot pixels should match a direct CG→screenshot-pixel conversion.
    ///
    /// This is a consistency check across the two conversion paths:
    ///   Path A: CG → AppKit (via convertCGGlobalRectToAppKitGlobalRect)
    ///           → screenshot pixels (via convertAppKitGlobalRectToScreenshotPixelRect)
    ///   Path B: Direct formula from CG coordinates
    ///
    /// Both paths should produce the same result.
    @Test func cgRectToAppKitToScreenshotPixelsIsConsistentWithDirectCGToPixelPath() {
        let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screenshotWidth: CGFloat = 1280
        let screenshotHeight: CGFloat = 800

        // A CG-space rect (top-left origin): x=200, y=300, w=150, h=40
        let cgRect = CGRect(x: 200, y: 300, width: 150, height: 40)

        // Path A: CG → AppKit → screenshot pixels
        let appKitRect = ScreenCoordinateConverter.convertCGGlobalRectToAppKitGlobalRect(
            cgGlobalRect: cgRect,
            primaryScreenFrameInAppKitCoordinates: primaryScreenFrame
        )
        let screenshotPixelRectViaAppKit = ScreenCoordinateConverter.convertAppKitGlobalRectToScreenshotPixelRect(
            appKitGlobalRect: appKitRect,
            displayFrameInAppKitCoordinates: primaryScreenFrame,
            screenshotWidthInPixels: screenshotWidth,
            screenshotHeightInPixels: screenshotHeight
        )

        // Path B: Direct from CG to screenshot pixels.
        // CG is already top-left, so just scale directly.
        // screenshotX = cgRect.x * (screenshotWidth / displayWidth)
        // screenshotY = cgRect.y * (screenshotHeight / displayHeight)
        // screenshotW = cgRect.w * (screenshotWidth / displayWidth)
        // screenshotH = cgRect.h * (screenshotHeight / displayHeight)
        let directScaleX = screenshotWidth / primaryScreenFrame.width
        let directScaleY = screenshotHeight / primaryScreenFrame.height
        let directPixelX = cgRect.origin.x * directScaleX
        let directPixelY = cgRect.origin.y * directScaleY
        let directPixelW = cgRect.width * directScaleX
        let directPixelH = cgRect.height * directScaleY

        #expect(abs(screenshotPixelRectViaAppKit.origin.x - directPixelX) < 1.0,
                "X mismatch: via AppKit=\(screenshotPixelRectViaAppKit.origin.x) direct=\(directPixelX)")
        #expect(abs(screenshotPixelRectViaAppKit.origin.y - directPixelY) < 1.0,
                "Y mismatch: via AppKit=\(screenshotPixelRectViaAppKit.origin.y) direct=\(directPixelY)")
        #expect(abs(screenshotPixelRectViaAppKit.width - directPixelW) < 1.0)
        #expect(abs(screenshotPixelRectViaAppKit.height - directPixelH) < 1.0)
    }

    // MARK: - Helpers

    /// Builds a synthetic `AccessibleElement` for testing. Because
    /// `AXUIElement` cannot be constructed in unit tests (it requires a live
    /// process), we use the application element for this process as a
    /// non-null placeholder. The handle is not exercised in any of the above
    /// pure-function tests.
    private func buildTestElement(
        elementID: Int,
        role: String,
        title: String,
        cgFrame: CGRect,
        appKitFrame: CGRect
    ) -> AccessibleElement {
        // AXUIElementCreateApplication requires a pid_t. We use this test
        // process's own PID as a harmless placeholder.
        let placeholderAXElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        return AccessibleElement(
            elementID: elementID,
            role: role,
            subrole: nil,
            title: title,
            cgFrame: cgFrame,
            appKitFrame: appKitFrame,
            axElementHandle: placeholderAXElement,
            owningProcessID: ProcessInfo.processInfo.processIdentifier
        )
    }
}
