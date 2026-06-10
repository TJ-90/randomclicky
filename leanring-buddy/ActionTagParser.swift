//
//  ActionTagParser.swift
//  leanring-buddy
//
//  Pure static parser for act-mode action tags that Claude can emit to
//  perform clicks and text entry on the user's behalf. This is part of
//  Phase D (act mode), Unit 11.
//
//  SAFETY FLOOR: ELEMENT IDs ONLY
//  ─────────────────────────────────────────────────────────────────────────────
//  CLICK and TYPE tags accept ONLY element-ID targets (E<n>). Pixel-coordinate
//  forms such as [CLICK:100,200:description] are deliberately REJECTED — they
//  are parsed as malformed and silently stripped with NO action produced.
//
//  Rationale: acting requires AX grounding. A pixel-form click would bypass
//  the pre-stage re-validation in ActionExecutionService (which checks the
//  live AX handle) and could send input to an element that has moved since
//  the screenshot. Rejecting pixel forms at parse time means the safety chain
//  in ActionExecutionService is the only execution path — there is no shortcut.
//
//  GRAMMAR
//  ─────────────────────────────────────────────────────────────────────────────
//
//  Click:
//    [CLICK:E<id>:<description>]
//
//    Examples:
//      [CLICK:E7:click the Submit button]
//      [CLICK:E12:open the File menu]
//
//  Type:
//    [TYPE:E<id>:<text to type>:<description>]
//
//    The DESCRIPTION is ALWAYS the LAST colon-segment.
//    Everything between the element ID segment and the final segment is the
//    text to type. This "last-segment wins" rule means the text may contain
//    colons without ambiguity.
//
//    Examples:
//      [TYPE:E3:hello@example.com:Fill the email field]
//      [TYPE:E5:see: this works:Fill the notes field]
//        → text = "see: this works", description = "Fill the notes field"
//      [TYPE:E2:https://example.com/path:enter the URL]
//        → text = "https://example.com/path", description = "enter the URL"
//
//  MALFORMED TAGS
//  ─────────────────────────────────────────────────────────────────────────────
//  Any tag that cannot be parsed into a known action is stripped from the
//  text and produces NO action. Specifically:
//    - Pixel-coordinate CLICK/TYPE forms → stripped, no action (safety floor)
//    - Missing element ID → stripped, no action
//    - TYPE with fewer than 3 segments (needs: E<id>, text, description) → stripped
//    - Unknown action kind → stripped
//
//  WHITESPACE AFTER STRIPPING
//  ─────────────────────────────────────────────────────────────────────────────
//  After all action tags are removed, runs of two or more spaces are collapsed
//  to a single space. Leading and trailing whitespace is trimmed. This matches
//  the cleanup contract in AnnotationTagParser and WalkthroughTagParser.
//
//  CALL ORDER (CompanionManager contract)
//  ─────────────────────────────────────────────────────────────────────────────
//  Action tags are parsed AFTER annotation tags and walkthrough tags have been
//  stripped. The caller in CompanionManager should:
//    1. parseAnnotationTags(from: full)         → strip BOX/CIRCLE/ARROW/HIGHLIGHT
//    2. parseWalkthroughTags(from: result)      → strip WALKTHROUGH/STEP/VERIFY
//    3. parseActionTags(from: result)           → strip CLICK/TYPE (this parser)
//    4. parsePointingCoordinates(from: result)  → POINT is end-anchored, needs clean tail
//

import CoreGraphics
import Foundation

// MARK: - Public types

/// The kind of action Claude wants to perform.
enum ParsedElementActionKind: Equatable {
    /// Perform a click on the target element.
    case click
    /// Type a string of text into the target element.
    case type
}

/// A single parsed action from Claude's response, ready for the pending-action
/// queue in CompanionManager (U11) to pick up and present for confirmation.
///
/// Only element-ID targets are valid. Pixel forms are rejected at parse time
/// as a deliberate safety floor (see file header).
struct ParsedElementAction: Equatable {
    /// Whether this is a click or a type action.
    let kind: ParsedElementActionKind
    /// The element ID from the AX inventory (e.g. 7 for E7).
    let elementID: Int
    /// The text to type into the element. `nil` for click actions.
    /// For TYPE actions this is the verbatim string as provided by Claude.
    let textToType: String?
    /// Claude's plain-language description of what this action does.
    /// Displayed in the confirmation panel alongside the element's own role+title
    /// so the user can see both "what the AX tree says" and "what Claude says".
    let claudeDescription: String
}

// MARK: - Parse result

/// The result of running the action tag parser over a full response string.
struct ActionTagParseResult: Equatable {
    /// All actions parsed from the response, in document order.
    /// Empty if no valid action tags were found.
    let actions: [ParsedElementAction]
    /// The response text with all CLICK and TYPE tags removed (including
    /// malformed ones — they must never be spoken aloud).
    let strippedText: String
}

// MARK: - Parser

/// Pure static parser for CLICK and TYPE action tags.
///
/// No AppKit imports — this parser uses only Foundation and CoreGraphics.
/// It is directly unit-testable without a display or TCC grants.
enum ActionTagParser {

    // MARK: - Public API

    /// Parses all CLICK and TYPE action tags from `responseText`.
    ///
    /// Returns the parsed actions in document order and the text with all
    /// action tags (including malformed ones) removed.
    ///
    /// Pixel-form CLICK/TYPE tags are stripped and produce NO action — this
    /// is the deliberate safety floor described in the file header.
    ///
    /// - Parameter responseText: The full raw response text, already stripped
    ///   of annotation and walkthrough tags by their respective parsers.
    /// - Returns: `ActionTagParseResult` with actions in document order and
    ///   whitespace-collapsed stripped text.
    static func parseActionTags(from responseText: String) -> ActionTagParseResult {
        // The scanning regex captures the action kind and the full inner body.
        //
        // Pattern: \[(CLICK|TYPE):([^\]]+)\]
        //
        // We capture the kind word and everything between the first colon and
        // the closing bracket as the body. The body parser handles further
        // splitting into element ID, text-to-type, and description.
        //
        // We intentionally use a broad inner pattern ([^\]]+) to collect every
        // candidate tag, including malformed ones — so we can strip them from
        // spoken text even when they produce no action.
        let scanningPattern = #"\[(CLICK|TYPE):([^\]]+)\]"#

        guard let scanningRegex = try? NSRegularExpression(
            pattern: scanningPattern,
            options: []
        ) else {
            // Pattern is a compile-time constant — this branch is unreachable
            // in production. Return unchanged text as a safe fallback.
            return ActionTagParseResult(actions: [], strippedText: responseText)
        }

        let nsResponseText = responseText as NSString
        let fullRange = NSRange(location: 0, length: nsResponseText.length)
        let allMatches = scanningRegex.matches(in: responseText, range: fullRange)

        guard !allMatches.isEmpty else {
            return ActionTagParseResult(actions: [], strippedText: responseText)
        }

        var parsedActions: [ParsedElementAction] = []
        var strippedText = responseText

        // Process matches in REVERSE order so that removing a later match
        // does not invalidate the string indices of earlier matches.
        for match in allMatches.reversed() {
            guard
                let kindRange = Range(match.range(at: 1), in: strippedText),
                let bodyRange = Range(match.range(at: 2), in: strippedText),
                let fullTagRange = Range(match.range, in: strippedText)
            else {
                continue
            }

            let kindString = String(strippedText[kindRange])
            let bodyString = String(strippedText[bodyRange])

            // Remove the full tag unconditionally — malformed tags must not
            // be spoken aloud, even if we cannot produce an action from them.
            strippedText.replaceSubrange(fullTagRange, with: "")

            // Attempt to parse a valid action from the kind + body.
            // If parsing fails (malformed, pixel form, etc.) we do nothing —
            // the tag has already been stripped above.
            if let action = parseAction(kindString: kindString, bodyString: bodyString) {
                // Collect in reversed order; we reverse the final array to
                // restore document order (same pattern as AnnotationTagParser).
                parsedActions.append(action)
            }
            // else: malformed — stripped but no action produced (safety floor).
        }

        // Restore document order (we iterated in reverse for safe string mutation).
        parsedActions.reverse()

        let collapsedText = collapseExtraWhitespace(in: strippedText)

        return ActionTagParseResult(actions: parsedActions, strippedText: collapsedText)
    }

    // MARK: - Private: Action parsing

    /// Attempts to parse a single action from the kind string and body string.
    ///
    /// Returns `nil` for any malformed or disallowed form (including pixel
    /// coordinate targets — the safety floor).
    private static func parseAction(kindString: String, bodyString: String) -> ParsedElementAction? {
        switch kindString {
        case "CLICK":
            return parseClickAction(from: bodyString)
        case "TYPE":
            return parseTypeAction(from: bodyString)
        default:
            // Unknown kind — future-proofing against Claude emitting novel tags.
            return nil
        }
    }

    /// Parses a CLICK action body.
    ///
    /// Expected forms:
    ///   "E7:click the Submit button"    → elementID 7, description "click the Submit button"
    ///   "E12:open the File menu"        → elementID 12, description "open the File menu"
    ///
    /// Rejected forms (pixel-coordinate safety floor):
    ///   "100,200:description"           → nil (pixel form, no action)
    ///   "100,200:desc:screen2"          → nil (pixel form, no action)
    ///
    /// The body is everything between the "[CLICK:" and the closing "]".
    private static func parseClickAction(from bodyString: String) -> ParsedElementAction? {
        // The body must start with "E" to be a valid element-ID form.
        // Anything starting with a digit is a pixel coordinate and is rejected
        // as the safety floor — no click without an AX-grounded element.
        guard bodyString.hasPrefix("E") else {
            // Pixel-form or other non-element-ID form. Reject.
            return nil
        }

        // Body form: "E<id>:<description>"
        // Split at the first colon to separate the ID from the description.
        guard let firstColonIndex = bodyString.firstIndex(of: ":") else {
            // No colon → no description. We require a description for the
            // confirmation panel. Reject as malformed.
            return nil
        }

        let elementIDSegment = String(bodyString[bodyString.startIndex..<firstColonIndex])
        let descriptionText = String(bodyString[bodyString.index(after: firstColonIndex)...])
            .trimmingCharacters(in: .whitespaces)

        guard let elementID = parseElementID(from: elementIDSegment) else {
            return nil
        }

        guard !descriptionText.isEmpty else {
            // Description is required for the confirmation panel to be useful.
            return nil
        }

        return ParsedElementAction(
            kind: .click,
            elementID: elementID,
            textToType: nil,
            claudeDescription: descriptionText
        )
    }

    /// Parses a TYPE action body.
    ///
    /// Expected form:
    ///   "E<id>:<text to type>:<description>"
    ///
    /// The DESCRIPTION is ALWAYS the LAST colon-segment. This "last-segment
    /// wins" split rule means the text-to-type may contain colons:
    ///
    ///   "E3:hello@example.com:Fill the email field"
    ///     → elementID 3, text "hello@example.com", description "Fill the email field"
    ///
    ///   "E5:see: this works:Fill the notes field"
    ///     → elementID 5, text "see: this works", description "Fill the notes field"
    ///
    /// Minimum segments: E<id>, text, description → at least 3 colon-separated
    /// segments required. Fewer → malformed, rejected.
    ///
    /// Rejected forms (pixel-coordinate safety floor):
    ///   "100,200:text:description"      → nil (starts with digit, rejected)
    private static func parseTypeAction(from bodyString: String) -> ParsedElementAction? {
        // Safety floor: reject pixel-form TYPE.
        guard bodyString.hasPrefix("E") else {
            return nil
        }

        // Split on ":" preserving empty subsequences so we can count segments
        // accurately and apply the last-segment-wins rule correctly.
        let segments = bodyString.split(
            separator: ":",
            maxSplits: Int.max,
            omittingEmptySubsequences: false
        ).map(String.init)

        // Minimum 3 segments: [E<id>, text, description]
        guard segments.count >= 3 else {
            // "E7:description" has only 2 segments — ambiguous which is text
            // and which is description. Reject as malformed.
            return nil
        }

        // First segment is the element ID.
        guard let elementID = parseElementID(from: segments[0]) else {
            return nil
        }

        // The LAST segment is always the description (last-segment-wins rule).
        let descriptionText = segments[segments.count - 1].trimmingCharacters(in: .whitespaces)

        // Everything between the first segment (element ID) and the last
        // segment (description) is the text to type, rejoined with ":".
        // This preserves colons inside the text verbatim.
        let textSegments = segments[1..<(segments.count - 1)]
        let textToType = textSegments.joined(separator: ":")

        guard !descriptionText.isEmpty else {
            return nil
        }

        // textToType may be empty string — e.g. "[TYPE:E3::description]" would
        // produce an empty text. We allow this since an empty type might be
        // intentional (clearing a field). ActionExecutionService will handle
        // the semantics of typing empty text.

        return ParsedElementAction(
            kind: .type,
            elementID: elementID,
            textToType: textToType,
            claudeDescription: descriptionText
        )
    }

    // MARK: - Private: Element ID parsing

    /// Extracts the integer element ID from a segment like "E7" or "E12".
    /// Returns `nil` if the segment is not in the expected "E<digits>" form.
    private static func parseElementID(from segment: String) -> Int? {
        guard segment.hasPrefix("E") else { return nil }

        let digitsString = String(segment.dropFirst()) // Remove leading "E"
        guard !digitsString.isEmpty, let elementID = Int(digitsString) else {
            // "E" with no digits, or non-numeric suffix — malformed.
            return nil
        }

        return elementID
    }

    // MARK: - Private: Whitespace cleanup

    /// Collapses runs of two or more spaces into a single space and trims
    /// leading/trailing whitespace. Mirrors the identical helper in
    /// AnnotationTagParser — we keep separate copies so each parser is
    /// independently importable without creating a cross-file dependency on a
    /// shared utility.
    ///
    /// We do NOT collapse newlines — those are structural in multi-paragraph
    /// responses.
    private static func collapseExtraWhitespace(in text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
