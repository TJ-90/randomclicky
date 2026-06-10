//
//  AnnotationTagParserTests.swift
//  leanring-buddyTests
//
//  Tests for AnnotationTagParser.parseAnnotationTags(from:) — the pure static
//  function that scans Claude's response text for BOX/CIRCLE/ARROW/HIGHLIGHT
//  annotation tags, extracts their targets and labels, and strips the tags
//  from the spoken text.
//
//  PARSE ORDER DOCUMENTED HERE
//  ─────────────────────────────────────────────────────────────────────────────
//  The production call site in CompanionManager.sendTranscriptToClaudeWithScreenshot
//  runs AnnotationTagParser BEFORE CompanionManager.parsePointingCoordinates so
//  that the end-anchored POINT parser sees a clean tail:
//
//    1. annotations, strippedText = AnnotationTagParser.parseAnnotationTags(from: full)
//    2. pointResult = CompanionManager.parsePointingCoordinates(from: strippedText)
//
//  Tests that mix annotation and POINT tags validate that this contract holds.
//
//  GRAMMAR SUMMARY
//  ─────────────────────────────────────────────────────────────────────────────
//  Regex (scanning, not end-anchored):
//    \[(BOX|CIRCLE|ARROW|HIGHLIGHT):([^\]]+)\]
//
//  Two target forms per tag:
//    Element-ID:  [BOX:E12:label]
//    Pixel-rect:  [BOX:x,y,w,h:label]
//                 [BOX:x,y,w,h:label:screenN]
//
//  Label is always optional. Malformed tags are stripped but produce no annotation.
//

import Testing
import CoreGraphics
@testable import leanring_buddy

struct AnnotationTagParserTests {

    // MARK: - Multiple annotations in one response

    /// Two BOX tags and one ARROW in a response body → three annotations
    /// returned in document order; spoken text has all three tags removed.
    @Test func twoBoxesAndOneArrowInResponseProducesThreeAnnotationsInOrder() {
        let response = "fill in [BOX:E1:name field] then [BOX:E2:email field] and submit [ARROW:E3:submit button]"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 3)

        // First annotation: BOX at E1
        if case .elementID(let id) = annotations[0].target {
            #expect(id == 1)
        } else {
            Issue.record("First annotation target should be elementID(1)")
        }
        #expect(annotations[0].kind == .box)
        #expect(annotations[0].label == "name field")

        // Second annotation: BOX at E2
        if case .elementID(let id) = annotations[1].target {
            #expect(id == 2)
        } else {
            Issue.record("Second annotation target should be elementID(2)")
        }
        #expect(annotations[1].kind == .box)
        #expect(annotations[1].label == "email field")

        // Third annotation: ARROW at E3
        if case .elementID(let id) = annotations[2].target {
            #expect(id == 3)
        } else {
            Issue.record("Third annotation target should be elementID(3)")
        }
        #expect(annotations[2].kind == .arrow)
        #expect(annotations[2].label == "submit button")

        // Spoken text must not contain any annotation tags.
        #expect(!strippedText.contains("[BOX:"))
        #expect(!strippedText.contains("[ARROW:"))
        // The instruction words are still present.
        #expect(strippedText.contains("fill in"))
        #expect(strippedText.contains("then"))
        #expect(strippedText.contains("and submit"))
    }

    /// All four annotation kinds parsed from a single response, confirming
    /// the kind enum mapping is complete and in document order.
    @Test func allFourAnnotationKindsParsedCorrectly() {
        let response = "[BOX:E1:b] [CIRCLE:E2:c] [ARROW:E3:a] [HIGHLIGHT:E4:h]"

        let (annotations, _) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 4)
        #expect(annotations[0].kind == .box)
        #expect(annotations[1].kind == .circle)
        #expect(annotations[2].kind == .arrow)
        #expect(annotations[3].kind == .highlight)
    }

    // MARK: - Mixed annotations + POINT tag (parse-order integration)

    /// Annotations earlier in text + trailing [POINT:E3:here] → annotations are
    /// parsed and stripped; POINT tag is left intact for the end-anchored parser.
    ///
    /// This validates the documented parse-order contract: annotation stripping
    /// runs first so POINT remains at the true end of the stripped text.
    @Test func annotationsStrippedAndPointTagLeftIntactForDownstreamParser() {
        let response = "look at [BOX:E1:field] and navigate to [CIRCLE:E2:menu] [POINT:E3:here]"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        // Two annotation tags stripped.
        #expect(annotations.count == 2)

        // POINT tag must survive in the stripped text so the end-anchored parser
        // can find it at the end of the string.
        #expect(strippedText.contains("[POINT:E3:here]"))

        // Annotation tags must be gone.
        #expect(!strippedText.contains("[BOX:"))
        #expect(!strippedText.contains("[CIRCLE:"))

        // Verify downstream POINT parser still works on the stripped text.
        let pointResult = CompanionManager.parsePointingCoordinates(from: strippedText)
        #expect(pointResult.elementID == 3)
        #expect(pointResult.elementLabel == "here")
        // Spoken text produced by the POINT parser must not contain the POINT tag.
        #expect(!pointResult.spokenText.contains("[POINT:"))
    }

    /// Legacy pixel-form POINT tag ([POINT:400,300:terminal:screen2]) is also
    /// preserved through annotation stripping so it can be resolved downstream.
    @Test func legacyPixelPointTagIsPreservedAfterAnnotationStripping() {
        let response = "check [HIGHLIGHT:E5:status bar] and then [POINT:400,300:terminal:screen2]"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 1)
        #expect(strippedText.contains("[POINT:400,300:terminal:screen2]"))
        #expect(!strippedText.contains("[HIGHLIGHT:"))
    }

    // MARK: - Pixel-rect target form

    /// [BOX:100,200,50,40:fields:screen2] → pixelRect target with screenNumber 2
    /// and label "fields".
    @Test func pixelRectTargetWithScreenNumberParsedCorrectly() {
        let response = "fill in these [BOX:100,200,50,40:fields:screen2]"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 1)

        if case .pixelRect(let rect, let screenNumber) = annotations[0].target {
            #expect(rect.origin.x == 100)
            #expect(rect.origin.y == 200)
            #expect(rect.size.width == 50)
            #expect(rect.size.height == 40)
            #expect(screenNumber == 2)
        } else {
            Issue.record("Target should be pixelRect with screenNumber 2")
        }

        #expect(annotations[0].label == "fields")
        #expect(!strippedText.contains("[BOX:"))
    }

    /// Pixel-rect with no label and no screen number.
    @Test func pixelRectTargetWithNoLabelAndNoScreenNumberParsedCorrectly() {
        let response = "[CIRCLE:320,480,80,80] is the area"

        let (annotations, _) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 1)

        if case .pixelRect(let rect, let screenNumber) = annotations[0].target {
            #expect(rect.origin.x == 320)
            #expect(rect.size.width == 80)
            #expect(screenNumber == nil)
        } else {
            Issue.record("Target should be pixelRect with nil screenNumber")
        }
        #expect(annotations[0].label == nil)
    }

    /// Pixel-rect with a label but no screen number.
    @Test func pixelRectTargetWithLabelAndNoScreenNumberParsedCorrectly() {
        let response = "[ARROW:10,20,30,40:my arrow]"

        let (annotations, _) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 1)
        if case .pixelRect(_, let screenNumber) = annotations[0].target {
            #expect(screenNumber == nil)
        }
        #expect(annotations[0].label == "my arrow")
    }

    // MARK: - No-label element-ID annotation

    /// [HIGHLIGHT:E7] with no label → highlight annotation with nil label.
    @Test func highlightWithElementIDAndNoLabelProducesNilLabel() {
        let response = "this area [HIGHLIGHT:E7] is relevant"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 1)
        #expect(annotations[0].kind == .highlight)

        if case .elementID(let id) = annotations[0].target {
            #expect(id == 7)
        } else {
            Issue.record("Target should be elementID(7)")
        }

        #expect(annotations[0].label == nil)

        // Tag must be stripped.
        #expect(!strippedText.contains("[HIGHLIGHT:"))
    }

    // MARK: - Malformed tags

    /// [BOX:nonsense] has a body that is neither an element-ID nor a valid
    /// pixel rect — it is stripped from the spoken text but produces no annotation.
    @Test func malformedTagWithUnparsableBodyIsStrippedButProducesNoAnnotation() {
        let response = "try this [BOX:nonsense] now"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.isEmpty)
        #expect(!strippedText.contains("[BOX:"))
        // Surrounding words survive.
        #expect(strippedText.contains("try this"))
        #expect(strippedText.contains("now"))
    }

    /// A tag with only two coordinate components (not four) is malformed.
    @Test func pixelRectWithOnlyTwoComponentsIsStrippedWithNoAnnotation() {
        let response = "[BOX:100,200] just two numbers"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.isEmpty)
        #expect(!strippedText.contains("[BOX:"))
    }

    /// An element-ID tag where "E" is not followed by any digits is malformed.
    @Test func elementIDTagWithNoDigitsAfterEIsStrippedWithNoAnnotation() {
        let response = "see [CIRCLE:E:no digits] here"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.isEmpty)
        #expect(!strippedText.contains("[CIRCLE:"))
    }

    // MARK: - Labels containing spaces and colons

    /// A label that contains spaces is parsed in its entirety.
    @Test func labelContainingSpacesIsParsedInFull() {
        let response = "[BOX:E5:the save button area]"

        let (annotations, _) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 1)
        #expect(annotations[0].label == "the save button area")
    }

    /// For pixel-rect forms, middle colon-separated segments (other than the
    /// leading coordinate quad and the trailing :screenN) are joined back as
    /// the label. This handles labels that contain colons.
    ///
    /// Grammar note: label = everything between coordinate segment and optional
    /// screenN, joined with ":" — this is the documented greedy behaviour.
    @Test func pixelRectLabelContainingColonIsCapturedGreedily() {
        // Body: "10,20,30,40:opt:in button:screen1"
        // coordinate: "10,20,30,40"
        // screen:     "screen1" (last segment)
        // label:      "opt:in button" (middle segments joined)
        let response = "[HIGHLIGHT:10,20,30,40:opt:in button:screen1]"

        let (annotations, _) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 1)
        if case .pixelRect(_, let screenNumber) = annotations[0].target {
            #expect(screenNumber == 1)
        }
        #expect(annotations[0].label == "opt:in button")
    }

    // MARK: - Text with no annotation tags

    /// A response that contains no annotation tags is returned unchanged
    /// with an empty annotations array.
    @Test func responseWithNoTagsIsReturnedUnchangedWithEmptyAnnotations() {
        let response = "the mitochondria is the powerhouse of the cell"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.isEmpty)
        #expect(strippedText == response)
    }

    /// An empty string input is handled gracefully — empty annotations, empty text.
    @Test func emptyStringInputProducesEmptyAnnotationsAndEmptyStrippedText() {
        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: "")

        #expect(annotations.isEmpty)
        #expect(strippedText.isEmpty)
    }

    // MARK: - Whitespace cleanliness after stripping

    /// A tag in the middle of a sentence leaves a double space which must be
    /// collapsed to a single space in the stripped text.
    @Test func midSentenceTagRemovalCollapsesDoubledWhitespace() {
        // "click [BOX:E1:field] and continue" → after strip: "click  and continue"
        // → after collapse: "click and continue"
        let response = "click [BOX:E1:field] and continue"

        let (_, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(!strippedText.contains("  ")) // No double spaces
        #expect(strippedText == "click and continue")
    }

    /// Multiple adjacent tags leave multiple spaces which are all collapsed.
    @Test func multipleAdjacentTagsCollapseToSingleSpacesBetweenWords() {
        let response = "start [BOX:E1:a] [CIRCLE:E2:b] end"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 2)
        #expect(!strippedText.contains("  "))
        // "start  end" → "start end" after collapse
        #expect(strippedText == "start end")
    }

    /// A tag at the very start of the text leaves no leading whitespace after stripping.
    @Test func tagAtStartOfTextLeavesNoLeadingWhitespaceAfterStripping() {
        let response = "[BOX:E3:first] then some text"

        let (_, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(!strippedText.hasPrefix(" "))
        #expect(strippedText == "then some text")
    }

    /// A tag at the very end of the text leaves no trailing whitespace after stripping.
    @Test func tagAtEndOfTextLeavesNoTrailingWhitespaceAfterStripping() {
        let response = "some text then [ARROW:E4:last]"

        let (_, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(!strippedText.hasSuffix(" "))
        #expect(strippedText == "some text then")
    }

    // MARK: - Edge cases: element IDs at various scales

    /// Single-digit element ID is parsed correctly.
    @Test func singleDigitElementIDParsedCorrectly() {
        let response = "[BOX:E1:a]"

        let (annotations, _) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 1)
        if case .elementID(let id) = annotations[0].target {
            #expect(id == 1)
        }
    }

    /// Three-digit element ID is parsed correctly (larger inventories).
    @Test func threeDigitElementIDParsedCorrectly() {
        let response = "[CIRCLE:E142:settings]"

        let (annotations, _) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.count == 1)
        if case .elementID(let id) = annotations[0].target {
            #expect(id == 142)
        }
    }

    // MARK: - Interaction with POINT tag: POINT is NOT stripped

    /// A response with only a POINT tag (no annotation tags) is returned
    /// completely unchanged — AnnotationTagParser does not touch POINT.
    @Test func responseWithOnlyPointTagIsReturnedWithPointTagIntact() {
        let response = "click the button [POINT:E5:submit]"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.isEmpty)
        // The text is unchanged because no annotation tags were found.
        #expect(strippedText == response)
    }

    /// [POINT:none] at the end is not touched by annotation stripping.
    @Test func pointNoneTagIsNotStrippedByAnnotationParser() {
        let response = "nothing relevant on screen [POINT:none]"

        let (annotations, strippedText) = AnnotationTagParser.parseAnnotationTags(from: response)

        #expect(annotations.isEmpty)
        #expect(strippedText.contains("[POINT:none]"))
    }
}
