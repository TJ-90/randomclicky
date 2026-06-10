//
//  InventoryPipelineTests.swift
//  leanring-buddyTests
//
//  Tests for U4's pure static functions:
//
//    1. CompanionManager.buildSupplementalInventoryTextBlock —
//       given (inventory, cursorScreenCapture) → the correct text block or nil.
//
//    2. ClaudeAPI.buildContentBlocks —
//       given (images, supplementalContextText, userPrompt) → correct block
//       array shape, with or without the supplemental block.
//
//  What is NOT tested here:
//  - The AX walk itself (requires TCC and a running app — verified manually).
//  - The timeout race (wraps async infrastructure — verified by integration).
//  - Analytics wiring (verified manually via PostHog event stream).
//
//  All functions under test are pure static functions that take explicit value-
//  type parameters, matching the codebase's established testable-decision shape.
//

import Testing
import CoreGraphics
import Foundation
@testable import leanring_buddy

// MARK: - buildSupplementalInventoryTextBlock tests

struct BuildSupplementalInventoryTextBlockTests {

    // MARK: - nil / empty cases

    /// When the inventory is nil, the function must return nil so no extra
    /// content block is added to the Claude message (message shape unchanged).
    @Test func nilInventoryReturnsNil() {
        let result = CompanionManager.buildSupplementalInventoryTextBlock(
            inventory: nil,
            cursorScreenCapture: makeTestScreenCapture()
        )
        #expect(result == nil)
    }

    /// When the inventory has zero elements, return nil — an empty-tree inventory
    /// carries no useful grounding information for Claude.
    @Test func emptyElementListReturnsNil() {
        let inventory = AccessibilityElementInventory(
            elements: [],
            frontmostAppName: "Finder",
            frontmostAppBundleID: "com.apple.finder",
            captureOutcome: .emptyTree
        )
        let result = CompanionManager.buildSupplementalInventoryTextBlock(
            inventory: inventory,
            cursorScreenCapture: makeTestScreenCapture()
        )
        #expect(result == nil)
    }

    /// When the cursor screen capture is nil, return nil — without pixel dimensions
    /// we cannot guarantee the coordinate spaces match.
    @Test func nilCursorScreenCaptureReturnsNil() {
        let inventory = makeMinimalInventoryForPipelineTests(
            appName: "Safari",
            elements: [
                makeAccessibleElementForPipelineTests(elementID: 1, appKitFrame: CGRect(x: 100, y: 200, width: 80, height: 30))
            ]
        )
        let result = CompanionManager.buildSupplementalInventoryTextBlock(
            inventory: inventory,
            cursorScreenCapture: nil
        )
        #expect(result == nil)
    }

    // MARK: - Non-nil / content verification

    /// When a valid inventory and screen capture are supplied, the result must
    /// be non-nil and begin with the expected header line naming the frontmost app.
    @Test func resultContainsAppNameHeader() {
        let appName = "Finder"
        let inventory = makeMinimalInventoryForPipelineTests(
            appName: appName,
            elements: [
                makeAccessibleElementForPipelineTests(elementID: 1, appKitFrame: CGRect(x: 100, y: 200, width: 80, height: 30))
            ]
        )

        let result = CompanionManager.buildSupplementalInventoryTextBlock(
            inventory: inventory,
            cursorScreenCapture: makeTestScreenCapture()
        )

        #expect(result != nil)
        // The header must contain the app name so Claude knows which app it
        // refers to, and must mention the coordinate space ("pixel coordinate space").
        let resultText = result!
        #expect(resultText.contains(appName))
        #expect(resultText.contains("pixel coordinate space"))
        #expect(resultText.hasPrefix("Interactive elements of the frontmost app (\(appName))"))
    }

    /// The result must contain element lines after the header — separated by a
    /// newline so the header is the first line and element lines follow.
    @Test func resultContainsElementLinesAfterHeader() {
        let inventory = makeMinimalInventoryForPipelineTests(
            appName: "Safari",
            elements: [
                makeAccessibleElementForPipelineTests(elementID: 3, appKitFrame: CGRect(x: 200, y: 300, width: 100, height: 40))
            ]
        )

        let result = CompanionManager.buildSupplementalInventoryTextBlock(
            inventory: inventory,
            cursorScreenCapture: makeTestScreenCapture()
        )

        #expect(result != nil)
        let lines = result!.split(separator: "\n", omittingEmptySubsequences: false)
        // First line is the header
        #expect(lines.count >= 2)
        // The second line should contain the element ID in [E3] form
        #expect(lines[1].contains("[E3]"))
    }

    /// The header format must exactly match:
    ///   "Interactive elements of the frontmost app (<AppName>), frames in the screenshot's pixel coordinate space:"
    /// This is the form the system prompt teaches Claude to recognise.
    @Test func headerMatchesExactExpectedFormat() {
        let appName = "VS Code"
        let inventory = makeMinimalInventoryForPipelineTests(
            appName: appName,
            elements: [
                makeAccessibleElementForPipelineTests(elementID: 1, appKitFrame: CGRect(x: 10, y: 10, width: 60, height: 20))
            ]
        )

        let result = CompanionManager.buildSupplementalInventoryTextBlock(
            inventory: inventory,
            cursorScreenCapture: makeTestScreenCapture()
        )

        #expect(result != nil)
        let firstLine = result!.split(separator: "\n").first.map(String.init)
        let expectedHeader = "Interactive elements of the frontmost app (\(appName)), frames in the screenshot's pixel coordinate space:"
        #expect(firstLine == expectedHeader)
    }
}

// MARK: - ClaudeAPI.buildContentBlocks tests

struct BuildContentBlocksTests {

    /// When supplementalContextText is nil, the content blocks must be identical
    /// to the pre-U4 shape: image blocks (image + label alternating) + user prompt.
    /// This is the regression guard ensuring nil → no change.
    @Test func nilSupplementalTextProducesPreU4MessageShape() {
        let fakeImageData = Data([0xFF, 0xD8, 0xFF]) // JPEG magic bytes
        let images: [(data: Data, label: String)] = [
            (data: fakeImageData, label: "Screen 1 (1280x800 pixels)")
        ]
        let userPrompt = "what should I click to make a new folder?"

        let blocks = ClaudeAPI.buildContentBlocks(
            images: images,
            supplementalContextText: nil,
            userPrompt: userPrompt
        )

        // Shape: [image, label, userPrompt] — 3 blocks total
        #expect(blocks.count == 3)

        // Block 0: image
        #expect((blocks[0]["type"] as? String) == "image")

        // Block 1: image label text
        #expect((blocks[1]["type"] as? String) == "text")
        #expect((blocks[1]["text"] as? String) == "Screen 1 (1280x800 pixels)")

        // Block 2: user prompt
        #expect((blocks[2]["type"] as? String) == "text")
        #expect((blocks[2]["text"] as? String) == userPrompt)
    }

    /// When supplementalContextText is non-nil, a text block containing the inventory
    /// must appear AFTER the image blocks and BEFORE the user prompt.
    @Test func nonNilSupplementalTextIsInsertedAfterImagesBeforePrompt() {
        let fakeImageData = Data([0xFF, 0xD8, 0xFF]) // JPEG magic bytes
        let images: [(data: Data, label: String)] = [
            (data: fakeImageData, label: "Screen 1 (1280x800 pixels)")
        ]
        let inventoryText = "Interactive elements of the frontmost app (Finder), frames in the screenshot's pixel coordinate space:\n[E1] AXButton \"New Folder\" (400,300 80x28)"
        let userPrompt = "what should I click to make a new folder?"

        let blocks = ClaudeAPI.buildContentBlocks(
            images: images,
            supplementalContextText: inventoryText,
            userPrompt: userPrompt
        )

        // Shape: [image, label, inventoryBlock, userPrompt] — 4 blocks total
        #expect(blocks.count == 4)

        // Block 0: image
        #expect((blocks[0]["type"] as? String) == "image")

        // Block 1: image label text
        #expect((blocks[1]["type"] as? String) == "text")
        #expect((blocks[1]["text"] as? String) == "Screen 1 (1280x800 pixels)")

        // Block 2: supplemental inventory text (must appear after images)
        #expect((blocks[2]["type"] as? String) == "text")
        #expect((blocks[2]["text"] as? String) == inventoryText)

        // Block 3: user prompt (must come last)
        #expect((blocks[3]["type"] as? String) == "text")
        #expect((blocks[3]["text"] as? String) == userPrompt)
    }

    /// Two screenshots produce the correct interleaved image+label shape, with
    /// the inventory block after both screenshots and the prompt last.
    @Test func twoScreenshotsWithInventoryProducesCorrectBlockOrder() {
        let fakeJpegData = Data([0xFF, 0xD8, 0xFF])
        let images: [(data: Data, label: String)] = [
            (data: fakeJpegData, label: "primary focus (1512x982 pixels)"),
            (data: fakeJpegData, label: "screen2 (2560x1440 pixels)")
        ]
        let inventoryText = "Interactive elements of the frontmost app (Safari), frames in the screenshot's pixel coordinate space:\n[E5] AXButton \"Download\" (812,440 96x28)"
        let userPrompt = "where do I download this?"

        let blocks = ClaudeAPI.buildContentBlocks(
            images: images,
            supplementalContextText: inventoryText,
            userPrompt: userPrompt
        )

        // Shape: [img1, lbl1, img2, lbl2, inventory, prompt] — 6 blocks
        #expect(blocks.count == 6)

        #expect((blocks[0]["type"] as? String) == "image")
        #expect((blocks[1]["type"] as? String) == "text")  // label for img1
        #expect((blocks[2]["type"] as? String) == "image")
        #expect((blocks[3]["type"] as? String) == "text")  // label for img2
        #expect((blocks[4]["type"] as? String) == "text")  // inventory
        #expect((blocks[4]["text"] as? String) == inventoryText)
        #expect((blocks[5]["type"] as? String) == "text")  // user prompt
        #expect((blocks[5]["text"] as? String) == userPrompt)
    }

    /// PNG image data is detected correctly — the media_type in the image source
    /// block must be "image/png" not "image/jpeg".
    @Test func pngImageDataIsDetectedAsPNG() {
        // PNG magic bytes: 89 50 4E 47
        let fakePNGData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00])
        let images: [(data: Data, label: String)] = [
            (data: fakePNGData, label: "screen1")
        ]

        let blocks = ClaudeAPI.buildContentBlocks(
            images: images,
            supplementalContextText: nil,
            userPrompt: "test"
        )

        guard let imageBlock = blocks.first,
              let source = imageBlock["source"] as? [String: Any] else {
            Issue.record("Expected image block with source")
            return
        }
        #expect((source["media_type"] as? String) == "image/png")
    }

    /// JPEG image data is detected correctly.
    @Test func jpegImageDataIsDetectedAsJPEG() {
        // JPEG magic bytes: FF D8 FF
        let fakeJPEGData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let images: [(data: Data, label: String)] = [
            (data: fakeJPEGData, label: "screen1")
        ]

        let blocks = ClaudeAPI.buildContentBlocks(
            images: images,
            supplementalContextText: nil,
            userPrompt: "test"
        )

        guard let imageBlock = blocks.first,
              let source = imageBlock["source"] as? [String: Any] else {
            Issue.record("Expected image block with source")
            return
        }
        #expect((source["media_type"] as? String) == "image/jpeg")
    }
}

// MARK: - Test helpers

/// Creates a minimal AccessibilityElementInventory for pipeline tests.
private func makeMinimalInventoryForPipelineTests(
    appName: String,
    elements: [AccessibleElement],
    captureOutcome: AccessibilityInventoryCaptureOutcome = .captured
) -> AccessibilityElementInventory {
    return AccessibilityElementInventory(
        elements: elements,
        frontmostAppName: appName,
        frontmostAppBundleID: "com.test.\(appName.lowercased().replacingOccurrences(of: " ", with: ""))",
        captureOutcome: captureOutcome
    )
}

/// Creates an AccessibleElement with just enough fields set for pipeline tests.
/// AXUIElementCreateApplication(0) provides a non-nil handle without real AX access.
private func makeAccessibleElementForPipelineTests(
    elementID: Int,
    appKitFrame: CGRect
) -> AccessibleElement {
    return AccessibleElement(
        elementID: elementID,
        role: "AXButton",
        subrole: nil,
        title: "Test Element \(elementID)",
        cgFrame: .zero,
        appKitFrame: appKitFrame,
        axElementHandle: AXUIElementCreateApplication(0),
        owningProcessID: 0
    )
}

/// Creates a minimal CompanionScreenCapture for use in text block builder tests.
/// The display frame spans 0,0→1440×900 in AppKit coords; screenshot is 1280×800px.
/// These values are consistent so coordinate conversions produce deterministic output.
private func makeTestScreenCapture() -> CompanionScreenCapture {
    return CompanionScreenCapture(
        imageData: Data([0xFF, 0xD8, 0xFF]),  // minimal JPEG magic bytes
        label: "primary focus (1280x800 pixels)",
        isCursorScreen: true,
        displayWidthInPoints: 1440,
        displayHeightInPoints: 900,
        displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        screenshotWidthInPixels: 1280,
        screenshotHeightInPixels: 800
    )
}
