//
//  AnnotationTagParser.swift
//  leanring-buddy
//
//  Pure static parser for screen annotation tags that Claude can emit to draw
//  multi-shape overlays on the user's screen. This parser handles Phase B
//  annotation tags (BOX, CIRCLE, ARROW, HIGHLIGHT) and is intentionally
//  separate from the end-anchored POINT parser in CompanionManager.
//
//  PARSE ORDER CONTRACT
//  ─────────────────────────────────────────────────────────────────────────────
//  Annotation tags are stripped BEFORE the POINT parser runs. This matters
//  because POINT is end-anchored — it must see a clean tail with no dangling
//  annotation tags that could push the POINT tag away from the true end of the
//  response. Callers in CompanionManager must therefore:
//
//    1. Call AnnotationTagParser.parseAnnotationTags(from: fullResponseText)
//       to get (annotations, textAfterAnnotationsStripped)
//    2. Call CompanionManager.parsePointingCoordinates(from: textAfterAnnotationsStripped)
//       on the already-stripped text so POINT remains end-anchored.
//
//  POINT tags are NOT this parser's business — they are left untouched in the
//  text for the existing end-anchored parser to handle.
//
//  GRAMMAR (implemented below)
//  ─────────────────────────────────────────────────────────────────────────────
//  Annotation tags appear ANYWHERE in the response text (scanning, not
//  end-anchored). Each tag has one of two target forms:
//
//    Element-ID form:   [BOX:E<id>:label]
//    Pixel-rect form:   [BOX:x,y,w,h:label]       (screenshot pixel space)
//                       [BOX:x,y,w,h:label:screenN]
//
//  The label is optional in both forms:
//    [HIGHLIGHT:E7]
//    [CIRCLE:100,200,50,40]
//
//  The four tag kinds are BOX, CIRCLE, ARROW, and HIGHLIGHT.
//
//  MALFORMED TAGS
//  ─────────────────────────────────────────────────────────────────────────────
//  A tag whose inner content cannot be parsed (bad pixel rect, unknown kind,
//  etc.) is stripped from the text but produces NO annotation entry. It is
//  silently discarded — never spoken, never crashes.
//
//  LABEL BOUNDARY RULE
//  ─────────────────────────────────────────────────────────────────────────────
//  Labels are parsed greedily: everything between the last colon-delimited
//  field and the closing ']' is the label. This means a label can contain
//  colons, which is necessary because screen-inventory titles may include them.
//  The screenN suffix is parsed as a fixed pattern BEFORE the label so that
//  a ":screen2" suffix on a pixel-rect form is recognised correctly even when
//  the label is absent.
//
//  WHITESPACE AFTER STRIPPING
//  ─────────────────────────────────────────────────────────────────────────────
//  After all annotation tags are removed, runs of two or more spaces (left
//  behind when a tag was surrounded by spaces) are collapsed to a single space.
//  Leading and trailing whitespace on the resulting string is trimmed.
//

import CoreGraphics
import Foundation

// MARK: - Public types

/// The visual shape of a screen annotation.
enum ScreenAnnotationKind {
    /// A rectangular outline around a region.
    case box
    /// A circular (or elliptical) outline around a region.
    case circle
    /// A directional arrow pointing at a region.
    case arrow
    /// A filled, semi-transparent highlight over a region.
    case highlight
}

/// The resolved target of an annotation — either an element from the AX
/// inventory (resolved to an exact frame by the overlay layer in U6) or a
/// pixel-space rectangle from the screenshot coordinate space.
///
/// Pixel-rect coordinates are in screenshot pixel space, consistent with the
/// coordinate space Claude uses for POINT tags. U6 converts them to AppKit
/// global space using ScreenCoordinateConverter, identical to how pixel-form
/// POINT coordinates are converted in the main pipeline.
enum ParsedAnnotationTarget {
    /// An element from the AX inventory for the current interaction.
    /// The integer is the element ID (e.g. 12 for E12).
    /// U6 looks this up against `inventoryForCurrentInteraction` to get the
    /// actual AppKit frame; if the ID is not found the annotation is dropped.
    case elementID(Int)

    /// A rectangle in screenshot pixel space (top-left origin, pixels).
    /// `screenNumber` is 1-based and refers to the screen labels in Claude's
    /// prompt (e.g. "screen2"). nil means the cursor's screen (screen 1).
    case pixelRect(rect: CGRect, screenNumber: Int?)
}

/// A single parsed annotation from Claude's response, ready for the overlay
/// layer (U6) to render.
struct ParsedScreenAnnotation {
    /// The visual shape to draw.
    let kind: ScreenAnnotationKind
    /// Where to draw the annotation.
    let target: ParsedAnnotationTarget
    /// Optional short label to display near the annotation (e.g. "Submit button").
    /// nil when Claude omitted the label.
    let label: String?
}

// MARK: - Parser

/// Pure static parser for multi-shape screen annotation tags.
///
/// No AppKit imports — this parser only uses CoreGraphics (CGRect, CGFloat)
/// and Foundation (NSRegularExpression, String). It is directly unit-testable
/// without a display or TCC grants.
enum AnnotationTagParser {

    // MARK: - Public API

    /// Parses all annotation tags from `responseText`, returning the
    /// annotations in order of appearance and the text with all annotation
    /// tags removed.
    ///
    /// POINT tags are deliberately left untouched so the caller can pass
    /// the returned `strippedText` straight into
    /// `CompanionManager.parsePointingCoordinates(from:)`.
    ///
    /// Malformed annotation tags (unrecognised inner content) are stripped
    /// from the text but produce no annotation in the returned array.
    ///
    /// - Parameter responseText: The full raw text of Claude's response,
    ///   including any embedded tags.
    /// - Returns: A tuple of (annotations in document order, text with all
    ///   annotation tags removed and whitespace collapsed).
    static func parseAnnotationTags(
        from responseText: String
    ) -> (annotations: [ParsedScreenAnnotation], strippedText: String) {

        // The scanning regex matches the tag opener and captures everything
        // between the brackets so we can attempt detailed parsing per match.
        //
        // Pattern: \[(BOX|CIRCLE|ARROW|HIGHLIGHT):([^\]]+)\]
        //
        // We capture the kind word and the entire inner body separately so
        // the body parser can work on just the content without re-splitting.
        //
        // We deliberately do NOT use a tighter inner pattern here because we
        // want to collect every candidate tag — including malformed ones — so
        // we can strip them from the spoken text even when they produce no
        // annotation.
        let scanningPattern = #"\[(BOX|CIRCLE|ARROW|HIGHLIGHT):([^\]]+)\]"#

        guard let scanningRegex = try? NSRegularExpression(
            pattern: scanningPattern,
            options: []
        ) else {
            // This should never happen — the pattern is a compile-time constant.
            // If it somehow does, return the original text unchanged.
            return (annotations: [], strippedText: responseText)
        }

        let nsResponseText = responseText as NSString
        let fullRange = NSRange(location: 0, length: nsResponseText.length)
        let allMatches = scanningRegex.matches(in: responseText, range: fullRange)

        // If no annotation tags were found at all, return early without any
        // allocation or string mutation.
        guard !allMatches.isEmpty else {
            return (annotations: [], strippedText: responseText)
        }

        var parsedAnnotations: [ParsedScreenAnnotation] = []
        var strippedText = responseText

        // Process matches in REVERSE order so that the string indices of
        // earlier matches remain valid after we mutate the string by removing
        // later matches. (Removing a range at the end does not shift earlier
        // byte offsets.)
        for match in allMatches.reversed() {
            guard
                let kindRange = Range(match.range(at: 1), in: strippedText),
                let bodyRange = Range(match.range(at: 2), in: strippedText),
                let fullTagRange = Range(match.range, in: strippedText)
            else {
                // Safety: skip if index mapping fails (shouldn't happen).
                continue
            }

            let kindString = String(strippedText[kindRange])
            let bodyString = String(strippedText[bodyRange])

            // Remove the full tag from the text unconditionally — even a
            // malformed tag must not be spoken.
            strippedText.replaceSubrange(fullTagRange, with: "")

            // Parse the kind and body. If either fails, the tag is dropped
            // (stripped from text above but no annotation added).
            guard
                let kind = parseAnnotationKind(from: kindString),
                let target = parseAnnotationTarget(from: bodyString),
                let labelOrNil = parseAnnotationLabel(from: bodyString, target: target)
            else {
                // Malformed — already stripped, no annotation added.
                continue
            }

            // Annotations are collected in reversed order here; we reverse
            // the final array to restore document order.
            parsedAnnotations.append(ParsedScreenAnnotation(
                kind: kind,
                target: target,
                label: labelOrNil
            ))
        }

        // Restore document order (we iterated in reverse for safe string mutation).
        parsedAnnotations.reverse()

        // Collapse doubled whitespace left behind by removed tags. A tag
        // surrounded by spaces like "click [BOX:E1:field] and then" becomes
        // "click  and then" after removal — we collapse the double space.
        let collapsedText = collapseExtraWhitespace(in: strippedText)

        return (annotations: parsedAnnotations, strippedText: collapsedText)
    }

    // MARK: - Private: Kind parsing

    /// Maps the kind string from the regex capture to the `ScreenAnnotationKind`
    /// enum. Returns nil for unrecognised kind strings (future-proofing against
    /// Claude emitting unknown tag names).
    private static func parseAnnotationKind(from kindString: String) -> ScreenAnnotationKind? {
        switch kindString {
        case "BOX":       return .box
        case "CIRCLE":    return .circle
        case "ARROW":     return .arrow
        case "HIGHLIGHT": return .highlight
        default:          return nil
        }
    }

    // MARK: - Private: Target parsing

    /// Parses the target from the tag body. The body is everything between
    /// the kind colon and the closing bracket, e.g.:
    ///
    ///   "E12:label"          → .elementID(12)
    ///   "E7"                 → .elementID(7)          (no label)
    ///   "100,200,50,40"      → .pixelRect(...)         (no label, no screen)
    ///   "100,200,50,40:label"→ .pixelRect(...)         (with label)
    ///   "100,200,50,40:label:screen2" → .pixelRect(..., screenNumber: 2)
    ///
    /// Returns nil when the body cannot be parsed into any known target form.
    /// The caller treats nil as a malformed tag and discards it.
    private static func parseAnnotationTarget(from bodyString: String) -> ParsedAnnotationTarget? {
        // --- Element-ID form: starts with "E" followed by digits ---
        if bodyString.hasPrefix("E") {
            return parseElementIDTarget(from: bodyString)
        }

        // --- Pixel-rect form: starts with a digit ---
        if let firstCharacter = bodyString.first, firstCharacter.isNumber {
            return parsePixelRectTarget(from: bodyString)
        }

        // Body starts with something else — malformed.
        return nil
    }

    /// Parses the element-ID target from a body that starts with "E".
    ///
    /// Accepted forms (body is everything after the kind colon):
    ///   "E12"            → .elementID(12)
    ///   "E12:some label" → .elementID(12)  (label parsed separately)
    ///
    /// The integer is extracted from the leading "E<digits>" prefix. Everything
    /// after the first colon is the label region and is ignored here (the label
    /// parser handles it).
    private static func parseElementIDTarget(from bodyString: String) -> ParsedAnnotationTarget? {
        // Extract the numeric part of "E<digits>". Stop at the first colon
        // (which would begin the label) or at end of string.
        let afterE = bodyString.dropFirst() // Remove leading "E"
        let digitsString: String
        if let colonIndex = afterE.firstIndex(of: ":") {
            digitsString = String(afterE[afterE.startIndex..<colonIndex])
        } else {
            digitsString = String(afterE)
        }

        guard !digitsString.isEmpty, let elementID = Int(digitsString) else {
            // "E" with no digits, or non-numeric digits — malformed.
            return nil
        }

        return .elementID(elementID)
    }

    /// Parses the pixel-rect target from a body that begins with a digit.
    ///
    /// Accepted forms:
    ///   "100,200,50,40"               → .pixelRect(CGRect(100,200,50,40), nil)
    ///   "100,200,50,40:label"         → .pixelRect(CGRect(100,200,50,40), nil)
    ///   "100,200,50,40:label:screen2" → .pixelRect(CGRect(100,200,50,40), 2)
    ///   "100,200,50,40::screen2"      → .pixelRect(CGRect(100,200,50,40), 2)  (empty label)
    ///
    /// The screen-number suffix is parsed BEFORE the label so that it is
    /// recognised regardless of whether a label is present.
    private static func parsePixelRectTarget(from bodyString: String) -> ParsedAnnotationTarget? {
        // Split the body on ":" to isolate the coordinate segment from optional
        // label and optional screen-number segments.
        let colonSeparatedSegments = bodyString.split(
            separator: ":",
            maxSplits: Int.max,
            omittingEmptySubsequences: false
        ).map(String.init)

        // The first segment must be the "x,y,w,h" quadruple.
        guard let coordinateSegment = colonSeparatedSegments.first else {
            return nil
        }

        // Parse the four comma-separated numbers.
        let coordinateComponents = coordinateSegment
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard coordinateComponents.count == 4,
              let xValue = CGFloat(coordinateComponents[0]),
              let yValue = CGFloat(coordinateComponents[1]),
              let widthValue = CGFloat(coordinateComponents[2]),
              let heightValue = CGFloat(coordinateComponents[3]) else {
            // Not four valid numbers — malformed.
            return nil
        }

        let pixelRect = CGRect(x: xValue, y: yValue, width: widthValue, height: heightValue)

        // Check whether the LAST segment is a screen-number suffix "screenN".
        // We check the last segment so the label (middle segments) can contain
        // arbitrary text without interfering with screen-number detection.
        var screenNumber: Int? = nil
        if colonSeparatedSegments.count >= 2 {
            let lastSegment = colonSeparatedSegments[colonSeparatedSegments.count - 1]
            if lastSegment.hasPrefix("screen"),
               let parsedScreenNumber = Int(lastSegment.dropFirst("screen".count)) {
                screenNumber = parsedScreenNumber
            }
        }

        return .pixelRect(rect: pixelRect, screenNumber: screenNumber)
    }

    // MARK: - Private: Label parsing

    /// Extracts the optional label from the tag body, given the already-parsed
    /// target. Returns the label string (possibly empty → treated as nil), or
    /// nil to indicate the tag is malformed.
    ///
    /// Note: this function returns an Optional<Optional<String>> conceptually —
    /// the outer nil signals "malformed, discard the whole annotation", while
    /// returning .some(nil) would mean "no label, annotation is still valid".
    /// We use a helper type to keep the signature readable: returning nil from
    /// here always means "keep the annotation but set label to nil" — the
    /// malformed signal for targets is handled in parseAnnotationTarget. The
    /// only way this function returns nil is if internal assumptions are violated.
    ///
    /// Label extraction rules:
    ///   - Element-ID form "E12:my label" → label is "my label"
    ///   - Element-ID form "E12"          → label is nil
    ///   - Pixel-rect form "x,y,w,h:label:screen2" → label is "label"
    ///   - Pixel-rect form "x,y,w,h:label"         → label is "label"
    ///   - Pixel-rect form "x,y,w,h"               → label is nil
    ///   - Pixel-rect form "x,y,w,h::screen2"      → label is nil (empty segment)
    ///
    /// The "greedy" rule: for pixel-rect forms with multiple colon-separated
    /// middle segments (rare but possible if the label itself contains a colon),
    /// all middle segments are joined back with ":" to form the full label.
    /// This matches the plan's documented greedy/lazy choice.
    private static func parseAnnotationLabel(
        from bodyString: String,
        target: ParsedAnnotationTarget
    ) -> String?? {
        // This function always returns .some(...) — either .some(nil) for no label
        // or .some("label text"). We use String?? so the outer optional signals
        // success/failure of the overall parse (nil = discard), but here we never
        // discard, so we always return non-nil outer.

        switch target {
        case .elementID:
            // Body form: "E<id>" or "E<id>:label text"
            // The label is everything after the first colon.
            if let colonIndex = bodyString.firstIndex(of: ":") {
                let labelText = String(bodyString[bodyString.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                return labelText.isEmpty ? .some(nil) : .some(labelText)
            }
            // No colon → no label.
            return .some(nil)

        case .pixelRect(_, let screenNumber):
            // Body form: "x,y,w,h" or "x,y,w,h:label" or "x,y,w,h:label:screenN"
            // The first colon-separated segment is the coordinate quad. Everything
            // after the first colon and before the last ":screenN" (if present) is
            // the label. We join middle segments with ":" to handle labels with colons.
            let colonSeparatedSegments = bodyString.split(
                separator: ":",
                maxSplits: Int.max,
                omittingEmptySubsequences: false
            ).map(String.init)

            // If there's only the coordinate segment, there's no label.
            guard colonSeparatedSegments.count >= 2 else {
                return .some(nil)
            }

            // Determine how many trailing segments to exclude.
            // If a screen number was parsed, the last segment was the screen suffix.
            let trailingSegmentsToExclude = screenNumber != nil ? 1 : 0
            let labelSegmentEndIndex = colonSeparatedSegments.count - trailingSegmentsToExclude

            // Segments that form the label are from index 1 to labelSegmentEndIndex (exclusive).
            let labelSegments = colonSeparatedSegments[1..<labelSegmentEndIndex]
            let labelText = labelSegments.joined(separator: ":").trimmingCharacters(in: .whitespaces)

            return labelText.isEmpty ? .some(nil) : .some(labelText)
        }
    }

    // MARK: - Private: Whitespace cleanup

    /// Collapses runs of two or more spaces into a single space and trims
    /// leading/trailing whitespace. This cleans up the gaps left when annotation
    /// tags are removed from the middle of a sentence.
    ///
    /// Example: "click  the button" → "click the button"
    /// Example: "  leading space"   → "leading space"
    private static func collapseExtraWhitespace(in text: String) -> String {
        // Replace any run of 2+ horizontal spaces with a single space.
        // We explicitly do NOT collapse newlines — those are structural.
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - CGFloat from String extension (local, private)

/// Allows CGFloat values to be parsed directly from substrings produced by
/// the coordinate parser. Using CGFloat(string) avoids an intermediate Double
/// conversion, keeping coordinate precision intact.
private extension CGFloat {
    init?(_ string: String) {
        guard let doubleValue = Double(string) else { return nil }
        self = CGFloat(doubleValue)
    }
}
