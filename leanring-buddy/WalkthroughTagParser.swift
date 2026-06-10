//
//  WalkthroughTagParser.swift
//  leanring-buddy
//
//  Pure static parser for walkthrough protocol tags. Claude emits these to
//  declare multi-step walkthroughs, present individual steps, and signal
//  verification verdicts. This parser is the counterpart to AnnotationTagParser:
//  it follows the same pure-static, scanning-parser style and is directly
//  unit-testable without a display or TCC grants.
//
//  GRAMMAR
//  ─────────────────────────────────────────────────────────────────────────────
//  Declaration tag (once per walkthrough, in the first step's response):
//    [WALKTHROUGH:<total>]
//    where <total> is a positive integer — the total number of steps declared.
//    Example: [WALKTHROUGH:4]
//
//  Step tag (once per turn presenting a step):
//    [STEP:<n>:<instruction>]
//    where <n> is the 1-based step number and <instruction> is the step text.
//    The instruction is the FINAL segment and is greedy — it may contain colons,
//    because a natural step instruction often has them (e.g. "Open Settings:
//    General tab"). Everything after the second colon up to the closing bracket
//    is treated as the instruction verbatim.
//    Example: [STEP:1:Open System Settings]
//    Example: [STEP:2:Open Settings: General tab]  ← colon inside instruction
//
//  Verification verdict tag (in verification-turn responses only):
//    [VERIFY:done]
//    [VERIFY:retry:<hint>]
//    The hint is greedy like the step instruction — it may contain colons.
//    Example: [VERIFY:done]
//    Example: [VERIFY:retry:You clicked Sharing, go back and pick General]
//
//  PARSE ORDER CONTRACT
//  ─────────────────────────────────────────────────────────────────────────────
//  WalkthroughTagParser is called AFTER AnnotationTagParser in the response
//  pipeline so that annotation tags are already stripped by the time walkthrough
//  tags are parsed. The call site in CompanionManager therefore runs:
//
//    1. AnnotationTagParser.parseAnnotationTags(from: fullResponseText)
//    2. WalkthroughTagParser.parseWalkthroughTags(from: annotationStrippedText)
//    3. CompanionManager.parsePointingCoordinates(from: walkthroughStrippedText)
//
//  This preserves the end-anchored POINT parser's contract: it must see a clean
//  tail free of inline tags.
//
//  MALFORMED TAGS
//  ─────────────────────────────────────────────────────────────────────────────
//  Tags whose inner content cannot be parsed are stripped from the text but
//  produce nil results. Callers must always handle nil gracefully (graceful
//  degradation — no crash, no silent advance).
//
//  WHITESPACE AFTER STRIPPING
//  ─────────────────────────────────────────────────────────────────────────────
//  After all walkthrough tags are removed, the stripped text is trimmed of
//  leading/trailing whitespace. Double spaces from removed inline tags are
//  collapsed, mirroring AnnotationTagParser.
//

import Foundation

// MARK: - Public Result Types

/// A parsed [WALKTHROUGH:<total>] declaration tag.
struct ParsedWalkthroughDeclaration: Equatable {
    /// The total number of steps declared in this walkthrough.
    /// Corresponds to the integer in [WALKTHROUGH:<total>].
    let totalStepCount: Int
}

/// A parsed [STEP:<n>:<instruction>] tag.
struct ParsedWalkthroughStep: Equatable {
    /// 1-based step number as declared in the tag (e.g. 1 for [STEP:1:...]).
    let stepNumber: Int
    /// The natural-language instruction for this step. May contain colons —
    /// the grammar is greedy from the second colon to the closing bracket.
    let instruction: String
}

/// The result of parsing a [VERIFY:...] tag.
enum ParsedVerificationVerdict: Equatable {
    /// The step was completed correctly. Claude is done with this step.
    /// Corresponds to [VERIFY:done].
    case done

    /// The step was not completed correctly. The hint is corrective guidance
    /// Claude provides to help the user retry.
    /// Corresponds to [VERIFY:retry:<hint>].
    /// The hint is greedy and may contain colons.
    case retry(hint: String)
}

// MARK: - Parser

/// Pure static parser for multi-step walkthrough protocol tags.
///
/// No AppKit imports — this parser only uses Foundation (NSRegularExpression, String).
/// It is directly unit-testable without a display or TCC grants. Mirrors
/// AnnotationTagParser's style: scanning matches, reverse-order removal for
/// safe string mutation, whitespace collapse on the stripped result.
enum WalkthroughTagParser {

    // MARK: - Public API: walkthrough and step tags

    /// Parses a [WALKTHROUGH:<total>] declaration and a [STEP:<n>:<instruction>]
    /// step tag from the response text, returning both parsed results and the text
    /// with all walkthrough and step tags stripped.
    ///
    /// Both the declaration and the step tag are optional in the return — either
    /// can be absent from a given response without error. Callers must handle nil
    /// gracefully (no crash, no silent advance) per the graceful-degradation policy.
    ///
    /// POINT tags and annotation tags are deliberately left untouched. This parser
    /// only removes [WALKTHROUGH:...] and [STEP:...] tags from the text.
    ///
    /// - Parameter responseText: The response text after annotation tags have
    ///   been stripped (AnnotationTagParser runs first in the pipeline).
    /// - Returns: A tuple of:
    ///   - `declaration`: The parsed declaration, or nil if no [WALKTHROUGH:] tag found.
    ///   - `step`: The parsed step, or nil if no [STEP:] tag found or if the tag is malformed.
    ///   - `strippedText`: The response text with all [WALKTHROUGH:] and [STEP:] tags removed.
    static func parseWalkthroughTags(
        from responseText: String
    ) -> (declaration: ParsedWalkthroughDeclaration?, step: ParsedWalkthroughStep?, strippedText: String) {

        var workingText = responseText
        var parsedDeclaration: ParsedWalkthroughDeclaration? = nil
        var parsedStep: ParsedWalkthroughStep? = nil

        // --- Parse [WALKTHROUGH:<total>] ---
        // FIX 7: Strip ALL occurrences, not just the first. Previously, extra
        // [WALKTHROUGH:] tags in a response were left in the text, spoken aloud by
        // TTS and broken the end-anchored POINT parser (which matches at the true end).
        // We keep only the FIRST parsed declaration as the semantic result; all
        // occurrences are stripped from the spoken text. Removal is done in reverse
        // order (largest range first) — the same safe-mutation approach as
        // AnnotationTagParser — so earlier range indices remain valid after each removal.
        //
        // Matches [WALKTHROUGH:] followed by one or more digits and a closing bracket.
        let declarationPattern = #"\[WALKTHROUGH:(\d+)\]"#
        if let declarationRegex = try? NSRegularExpression(pattern: declarationPattern, options: []) {
            let fullRange = NSRange(workingText.startIndex..., in: workingText)
            let allDeclarationMatches = declarationRegex.matches(in: workingText, range: fullRange)

            // Semantic result: parse only the FIRST occurrence.
            if let firstMatch = allDeclarationMatches.first {
                if let digitRange = Range(firstMatch.range(at: 1), in: workingText),
                   let totalStepCount = Int(workingText[digitRange]),
                   totalStepCount > 0 {
                    parsedDeclaration = ParsedWalkthroughDeclaration(totalStepCount: totalStepCount)
                }
            }

            // Strip ALL occurrences in reverse order so earlier indices stay valid.
            for match in allDeclarationMatches.reversed() {
                if let tagRange = Range(match.range, in: workingText) {
                    workingText.replaceSubrange(tagRange, with: "")
                }
            }
        }

        // --- Parse [STEP:<n>:<instruction>] ---
        // FIX 7: Strip ALL occurrences. Extra [STEP:] tags in a response (e.g. Claude
        // emitting two steps in one turn) were previously left in the text and spoken
        // by TTS. Keep only the FIRST parsed step as the semantic result; remove all.
        //
        // The instruction is greedy: [STEP:<digits>:<everything up to ]>]
        // We capture the digit group and the rest-of-body separately so the
        // instruction can contain colons without splitting incorrectly.
        //
        // Pattern: \[STEP:(\d+):([^\]]+)\]
        //   Group 1: step number digits
        //   Group 2: instruction (greedy, everything up to the first unescaped ])
        //
        // A [STEP:] tag without an instruction (e.g. [STEP:1:]) is malformed —
        // the [^\]]+ requires at least one character in the instruction body.
        let stepPattern = #"\[STEP:(\d+):([^\]]+)\]"#
        if let stepRegex = try? NSRegularExpression(pattern: stepPattern, options: []) {
            // Re-calculate range after potential declaration removal above.
            let fullRange = NSRange(workingText.startIndex..., in: workingText)
            let allStepMatches = stepRegex.matches(in: workingText, range: fullRange)

            // Semantic result: parse only the FIRST occurrence.
            if let firstMatch = allStepMatches.first {
                if let numberRange = Range(firstMatch.range(at: 1), in: workingText),
                   let instructionRange = Range(firstMatch.range(at: 2), in: workingText),
                   let stepNumber = Int(workingText[numberRange]) {
                    let instruction = String(workingText[instructionRange])
                        .trimmingCharacters(in: .whitespaces)
                    if !instruction.isEmpty {
                        parsedStep = ParsedWalkthroughStep(
                            stepNumber: stepNumber,
                            instruction: instruction
                        )
                    }
                }
            }

            // Strip ALL occurrences in reverse order so earlier indices stay valid.
            for match in allStepMatches.reversed() {
                if let tagRange = Range(match.range, in: workingText) {
                    workingText.replaceSubrange(tagRange, with: "")
                }
            }
        }

        // --- Strip all [VERIFY:...] tags from the spoken text ---
        // FIX 7: [VERIFY:] tags that appear in a response parsed by parseWalkthroughTags
        // (rather than parseVerificationVerdict) would otherwise be left in the text
        // and spoken aloud. Strip them all here so TTS never hears them and the POINT
        // end-anchor still fires correctly. We do NOT parse a semantic result here —
        // the verification verdict is only consumed by parseVerificationVerdict, which
        // is called on a different text path (the verification-turn response).
        let verifyPattern = #"\[VERIFY:[^\]]*\]"#
        if let verifyRegex = try? NSRegularExpression(pattern: verifyPattern, options: []) {
            let fullRange = NSRange(workingText.startIndex..., in: workingText)
            let allVerifyMatches = verifyRegex.matches(in: workingText, range: fullRange)
            for match in allVerifyMatches.reversed() {
                if let tagRange = Range(match.range, in: workingText) {
                    workingText.replaceSubrange(tagRange, with: "")
                }
            }
        }

        // Clean up any double spaces left behind by removed tags.
        let strippedText = collapseExtraWhitespace(in: workingText)

        return (declaration: parsedDeclaration, step: parsedStep, strippedText: strippedText)
    }

    // MARK: - Public API: verification verdict

    /// Parses a [VERIFY:done] or [VERIFY:retry:<hint>] tag from a verification-turn
    /// response, returning the verdict and the text with the verification tag stripped.
    ///
    /// Nil verdict means no recognisable [VERIFY:...] tag was found. This is the
    /// graceful-degradation path: the caller should treat the response as a hint
    /// (speak the text, apply .turnInterrupted to return from verifying to
    /// awaitingUserAction) rather than crashing or silently advancing.
    ///
    /// The hint in [VERIFY:retry:<hint>] is greedy — everything after the second
    /// colon up to the closing bracket. Hints may contain colons and commas.
    ///
    /// - Parameter responseText: The full response text from a verification turn,
    ///   after annotation tags have already been stripped.
    /// - Returns: A tuple of:
    ///   - `verdict`: The parsed verdict, or nil when no [VERIFY:...] tag is found.
    ///   - `strippedText`: The text with the [VERIFY:...] tag removed (or unchanged
    ///     when no tag was found — nil verdict, original text returned as-is).
    static func parseVerificationVerdict(
        from responseText: String
    ) -> (verdict: ParsedVerificationVerdict?, strippedText: String) {

        // --- Try [VERIFY:done] first (simple, no further content) ---
        // End-anchored check is NOT required here — the tag can appear anywhere
        // in a verification response (Claude may precede it with a congratulatory
        // line, or follow it with the next step tag).
        let donePattern = #"\[VERIFY:done\]"#
        if let doneRegex = try? NSRegularExpression(pattern: donePattern, options: []) {
            let fullRange = NSRange(responseText.startIndex..., in: responseText)
            if let match = doneRegex.firstMatch(in: responseText, range: fullRange) {
                var workingText = responseText
                if let tagRange = Range(match.range, in: workingText) {
                    workingText.replaceSubrange(tagRange, with: "")
                }
                let strippedText = collapseExtraWhitespace(in: workingText)
                return (verdict: .done, strippedText: strippedText)
            }
        }

        // --- Try [VERIFY:retry:<hint>] ---
        // The hint is greedy: [VERIFY:retry:<everything up to ]>]
        // Pattern: \[VERIFY:retry:([^\]]+)\]
        //   Group 1: hint text (may contain colons and commas)
        let retryPattern = #"\[VERIFY:retry:([^\]]+)\]"#
        if let retryRegex = try? NSRegularExpression(pattern: retryPattern, options: []) {
            let fullRange = NSRange(responseText.startIndex..., in: responseText)
            if let match = retryRegex.firstMatch(in: responseText, range: fullRange) {
                var workingText = responseText
                var parsedHint: String? = nil
                if let hintRange = Range(match.range(at: 1), in: workingText) {
                    let hint = String(workingText[hintRange])
                        .trimmingCharacters(in: .whitespaces)
                    parsedHint = hint.isEmpty ? nil : hint
                }
                // Strip the tag whether or not the hint parsed cleanly.
                if let tagRange = Range(match.range, in: workingText) {
                    workingText.replaceSubrange(tagRange, with: "")
                }
                let strippedText = collapseExtraWhitespace(in: workingText)
                // A retry tag with an empty hint degrades to nil verdict (malformed).
                if let hint = parsedHint {
                    return (verdict: .retry(hint: hint), strippedText: strippedText)
                } else {
                    // Malformed retry (no hint text) — treat as no verdict found.
                    return (verdict: nil, strippedText: strippedText)
                }
            }
        }

        // No recognisable VERIFY tag found — nil verdict, text unchanged.
        return (verdict: nil, strippedText: responseText)
    }

    // MARK: - Public API: done-signal classifier

    /// Returns true when a transcript looks like a user signalling that they
    /// completed the current walkthrough step — "I did it", "done", "ok done",
    /// "next", and a small set of natural variants.
    ///
    /// This is a heuristic v1 classifier. It is intentionally narrow: the set
    /// covers the most common completion signals without accidentally capturing
    /// help questions ("what does that mean?") or conversational utterances.
    /// False negatives (missed done-signals) are benign — the user can tap the
    /// panel "I did it" button instead. False positives (triggering verification
    /// on a help question) are more disruptive, so the set errs on the narrow side.
    ///
    /// The set is case-insensitive and strips leading/trailing whitespace and
    /// common terminal punctuation before matching.
    ///
    /// Done-signal words (documented here so the classifier is easy to extend):
    ///   "done", "ok done", "okay done", "i did it", "i did that", "next",
    ///   "got it", "i'm done", "im done", "finished", "all done", "step done"
    ///
    /// - Parameter transcript: The finalised push-to-talk transcript.
    /// - Returns: True when the transcript matches a known done-signal; false otherwise.
    static func transcriptMatchesDoneSignal(_ transcript: String) -> Bool {
        // Normalise: lowercase, strip leading/trailing whitespace, strip terminal
        // punctuation (period, exclamation, question mark) so "Done." and "DONE!"
        // both match.
        let trimmed = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalised = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespaces)

        let doneSignals: Set<String> = [
            "done",
            "ok done",
            "okay done",
            "i did it",
            "i did that",
            "next",
            "got it",
            "i'm done",
            "im done",
            "finished",
            "all done",
            "step done",
        ]

        return doneSignals.contains(normalised)
    }

    // MARK: - Private helpers

    /// Collapses runs of two or more spaces into a single space and trims
    /// leading/trailing whitespace. Mirrors AnnotationTagParser's behaviour
    /// exactly so tag removal never leaves double spaces in the spoken text.
    private static func collapseExtraWhitespace(in text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
