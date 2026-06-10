//
//  WalkthroughTagParserTests.swift
//  leanring-buddyTests
//
//  Tests for WalkthroughTagParser — the pure static parser for walkthrough
//  protocol tags ([WALKTHROUGH:], [STEP:], [VERIFY:]).
//
//  All tests call the static functions directly. No MainActor isolation needed
//  — the functions are nonisolated and synchronous, matching the pure-function
//  testing pattern used in AnnotationTagParserTests and WalkthroughControllerTests.
//

import Testing
import Foundation
@testable import leanring_buddy

struct WalkthroughTagParserTests {

    // MARK: - parseWalkthroughTags: declaration + step, both parsed and stripped

    /// [WALKTHROUGH:4] and [STEP:1:Open System Settings] both parsed; spoken
    /// text retains the instruction words but drops both tags.
    @Test func declarationAndStepParsedAndStrippedFromText() {
        let response = "let's do this step by step. [WALKTHROUGH:4] first, open system settings. [STEP:1:Open System Settings] [POINT:E1:System Settings]"

        let (declaration, step, strippedText) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        // Declaration parsed correctly.
        #expect(declaration != nil)
        #expect(declaration?.totalStepCount == 4)

        // Step parsed correctly.
        #expect(step != nil)
        #expect(step?.stepNumber == 1)
        #expect(step?.instruction == "Open System Settings")

        // Both walkthrough tags stripped; POINT tag untouched (not our job).
        #expect(!strippedText.contains("[WALKTHROUGH:"))
        #expect(!strippedText.contains("[STEP:"))
        #expect(strippedText.contains("[POINT:E1:System Settings]"))

        // The instruction words in the natural text survive stripping.
        #expect(strippedText.contains("first, open system settings"))
    }

    /// Declaration without a step tag — step is nil, declaration is parsed.
    @Test func declarationWithoutStepTagReturnsNilStep() {
        let response = "i'll walk you through this. [WALKTHROUGH:3] [POINT:none]"

        let (declaration, step, strippedText) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(declaration?.totalStepCount == 3)
        #expect(step == nil)
        #expect(!strippedText.contains("[WALKTHROUGH:"))
        // POINT tag untouched.
        #expect(strippedText.contains("[POINT:none]"))
    }

    /// Step without a declaration tag — declaration is nil, step is parsed.
    @Test func stepWithoutDeclarationTagReturnsNilDeclaration() {
        let response = "click the button. [STEP:2:Click the General button] [POINT:E5:General]"

        let (declaration, step, strippedText) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(declaration == nil)
        #expect(step?.stepNumber == 2)
        #expect(step?.instruction == "Click the General button")
        #expect(!strippedText.contains("[STEP:"))
        #expect(strippedText.contains("[POINT:E5:General]"))
    }

    /// Neither tag present — both nil, text unchanged (except whitespace normalisation).
    @Test func noWalkthroughTagsReturnsNilsAndUnchangedText() {
        let response = "just a regular response with no walkthrough tags"

        let (declaration, step, strippedText) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(declaration == nil)
        #expect(step == nil)
        #expect(strippedText == response)
    }

    // MARK: - Colon inside instruction (greedy final segment)

    /// [STEP:2:Open Settings: General tab] — instruction contains a colon.
    /// The parser must treat everything after the step-number colon as the
    /// instruction, not split again at the embedded colon.
    @Test func stepInstructionContainingColonParsedGreedily() {
        let response = "now do this. [STEP:2:Open Settings: General tab]"

        let (_, step, strippedText) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(step?.stepNumber == 2)
        // The full instruction including the embedded colon must be preserved.
        #expect(step?.instruction == "Open Settings: General tab")
        #expect(!strippedText.contains("[STEP:"))
    }

    /// [STEP:3:Go to System Settings: Accessibility: Display] — multiple colons.
    @Test func stepInstructionWithMultipleColonsParsedGreedily() {
        let response = "[STEP:3:Go to System Settings: Accessibility: Display]"

        let (_, step, _) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(step?.instruction == "Go to System Settings: Accessibility: Display")
    }

    // MARK: - parseVerificationVerdict: done

    /// [VERIFY:done] → verdict .done, tag stripped from text.
    @Test func verifyDoneTagParsedAsVerdictDoneAndStripped() {
        let response = "great job, you did it! [VERIFY:done] now let's move on."

        let (verdict, strippedText) = WalkthroughTagParser.parseVerificationVerdict(from: response)

        #expect(verdict == .done)
        #expect(!strippedText.contains("[VERIFY:"))
        // Surrounding text preserved.
        #expect(strippedText.contains("great job, you did it!"))
        #expect(strippedText.contains("now let's move on."))
    }

    /// [VERIFY:done] alone in the text.
    @Test func verifyDoneAloneInTextParsedCorrectly() {
        let response = "[VERIFY:done]"

        let (verdict, strippedText) = WalkthroughTagParser.parseVerificationVerdict(from: response)

        #expect(verdict == .done)
        #expect(strippedText.isEmpty)
    }

    // MARK: - parseVerificationVerdict: retry with complex hint

    /// [VERIFY:retry:You clicked Sharing, go back and pick General]
    /// — hint contains a comma and capitals, both preserved verbatim.
    @Test func verifyRetryTagWithCommaAndCapitalsInHintParsedCorrectly() {
        let response = "not quite. [VERIFY:retry:You clicked Sharing, go back and pick General]"

        let (verdict, strippedText) = WalkthroughTagParser.parseVerificationVerdict(from: response)

        if case .retry(let hint) = verdict {
            // Hint must be preserved verbatim — comma and capitals intact.
            #expect(hint == "You clicked Sharing, go back and pick General")
        } else {
            Issue.record("Expected .retry verdict, got \(String(describing: verdict))")
        }
        #expect(!strippedText.contains("[VERIFY:"))
        #expect(strippedText.contains("not quite."))
    }

    /// Hint containing a colon — the greedy rule applies just like step instructions.
    @Test func verifyRetryHintContainingColonParsedGreedily() {
        let response = "[VERIFY:retry:Open the menu: File, not Edit]"

        let (verdict, _) = WalkthroughTagParser.parseVerificationVerdict(from: response)

        if case .retry(let hint) = verdict {
            #expect(hint == "Open the menu: File, not Edit")
        } else {
            Issue.record("Expected .retry verdict")
        }
    }

    // MARK: - parseVerificationVerdict: no tag → nil verdict

    /// No [VERIFY:...] tag in the response — verdict is nil, text unchanged.
    /// This is the graceful-degradation path: caller speaks the text and applies
    /// .turnInterrupted to return from verifying to awaitingUserAction.
    @Test func noVerifyTagInResponseReturnsNilVerdictAndUnchangedText() {
        let response = "hmm, it looks like something went wrong with the screen."

        let (verdict, strippedText) = WalkthroughTagParser.parseVerificationVerdict(from: response)

        #expect(verdict == nil)
        // Text returned unchanged when no tag is found.
        #expect(strippedText == response)
    }

    /// Empty string — no tag, nil verdict, empty stripped text.
    @Test func emptyStringReturnsNilVerdictAndEmptyText() {
        let (verdict, strippedText) = WalkthroughTagParser.parseVerificationVerdict(from: "")

        #expect(verdict == nil)
        #expect(strippedText.isEmpty)
    }

    // MARK: - Walkthrough declaration edge cases

    /// [WALKTHROUGH:1] — single-step walkthrough is valid.
    @Test func singleStepDeclarationParsedCorrectly() {
        let response = "just one step. [WALKTHROUGH:1]"

        let (declaration, _, _) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(declaration?.totalStepCount == 1)
    }

    /// [WALKTHROUGH:0] — zero steps is not meaningful; parser treats it as
    /// malformed (totalStepCount must be > 0) and returns nil declaration.
    @Test func walkthroughDeclarationWithZeroStepsIsNil() {
        let response = "[WALKTHROUGH:0]"

        let (declaration, _, strippedText) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        // Zero-step walkthrough is malformed; nil declaration returned.
        #expect(declaration == nil)
        // Tag still stripped so it is not spoken.
        #expect(!strippedText.contains("[WALKTHROUGH:"))
    }

    /// [WALKTHROUGH:10] — multi-digit total parsed correctly.
    @Test func multiDigitTotalStepCountParsedCorrectly() {
        let response = "[WALKTHROUGH:10] here we go"

        let (declaration, _, _) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(declaration?.totalStepCount == 10)
    }

    // MARK: - Step tag edge cases

    /// [STEP:1:] — empty instruction is malformed; step returns nil.
    /// The tag is still stripped so it is not spoken.
    @Test func stepTagWithEmptyInstructionIsNil() {
        let response = "start here. [STEP:1:]"

        let (_, step, strippedText) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(step == nil)
        #expect(!strippedText.contains("[STEP:"))
    }

    /// Step number greater than 1 parsed correctly (not just step 1).
    @Test func stepNumberGreaterThanOneParsedCorrectly() {
        let response = "[STEP:5:Click the Done button]"

        let (_, step, _) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(step?.stepNumber == 5)
        #expect(step?.instruction == "Click the Done button")
    }

    // MARK: - Whitespace collapse after stripping

    /// A walkthrough tag in the middle of a sentence — double space is collapsed.
    @Test func midSentenceTagRemovalCollapsesDoubledWhitespace() {
        let response = "here's step one [STEP:1:Open Safari] and do it"

        let (_, step, strippedText) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        #expect(step != nil)
        #expect(!strippedText.contains("  "))
        #expect(strippedText == "here's step one and do it")
    }

    // MARK: - Verification prompt builder (pure static)

    /// walkthroughVerificationSystemPrompt(stepList:currentStep:) must contain
    /// the full step list, the current step number, and the current instruction.
    @Test func verificationSystemPromptContainsStepListCurrentStepAndInstruction() {
        let stepList = [
            WalkthroughStep(stepNumber: 1, instruction: "Open System Settings"),
            WalkthroughStep(stepNumber: 2, instruction: "Click General"),
            WalkthroughStep(stepNumber: 3, instruction: "Enable Dark Mode"),
        ]
        let currentStep = WalkthroughStep(stepNumber: 2, instruction: "Click General")

        let prompt = CompanionManager.walkthroughVerificationSystemPrompt(
            stepList: stepList,
            currentStep: currentStep
        )

        // Must list all declared steps.
        #expect(prompt.contains("Open System Settings"))
        #expect(prompt.contains("Click General"))
        #expect(prompt.contains("Enable Dark Mode"))

        // Must identify the current step number and instruction.
        #expect(prompt.contains("step 2"))
        #expect(prompt.contains("Click General"))

        // Must contain the verification tag grammar instructions.
        #expect(prompt.contains("[VERIFY:done]"))
        #expect(prompt.contains("[VERIFY:retry:"))
    }

    // MARK: - Done-signal classifier

    /// Known done-signal strings → true (case-insensitive, with punctuation).
    @Test func knownDoneSignalsReturnTrue() {
        let doneSignals = [
            "done",
            "Done",
            "DONE",
            "DONE.",
            "Done!",
            "i did it",
            "I did it",
            "I Did It",
            "i did that",
            "next",
            "Next",
            "got it",
            "i'm done",
            "im done",
            "finished",
            "all done",
            "step done",
            "ok done",
            "okay done",
        ]

        for signal in doneSignals {
            let result = WalkthroughTagParser.transcriptMatchesDoneSignal(signal)
            #expect(result == true, "Expected '\(signal)' to be a done-signal")
        }
    }

    /// Non-done-signal utterances → false.
    @Test func nonDoneSignalsReturnFalse() {
        let nonSignals = [
            "how do I do that?",
            "what does that mean?",
            "I don't see it",
            "can you explain",
            "where is it",
            "open system settings",
            "help",
            "cancel",
            "",
            "ok",
        ]

        for utterance in nonSignals {
            let result = WalkthroughTagParser.transcriptMatchesDoneSignal(utterance)
            #expect(result == false, "Expected '\(utterance)' to NOT be a done-signal")
        }
    }

    /// Leading/trailing whitespace is stripped before matching.
    @Test func doneSignalMatchingIgnoresLeadingAndTrailingWhitespace() {
        #expect(WalkthroughTagParser.transcriptMatchesDoneSignal("  done  ") == true)
        #expect(WalkthroughTagParser.transcriptMatchesDoneSignal("\tdone\n") == true)
    }

    // MARK: - All tag occurrences stripped (not just the first)

    /// A response containing two [STEP:...] tags and one [WALKTHROUGH:...] tag
    /// must have ALL of them stripped from spokenText. The parsed result is the
    /// first STEP tag; the second STEP tag is silently dropped (only one step
    /// can be active per response). The WALKTHROUGH tag is also stripped entirely.
    ///
    /// This guards against a regression where only the first match was removed
    /// and subsequent occurrences survived into the spoken text.
    @Test func multipleStepAndWalkthroughTagsAreAllStrippedFromSpokenText() {
        // Two STEP tags and one WALKTHROUGH tag — all three must be stripped.
        let response = "okay [WALKTHROUGH:3] first do this [STEP:1:Open Safari] then do that [STEP:2:Click the address bar] and you are ready"

        let (declaration, step, strippedText) = WalkthroughTagParser.parseWalkthroughTags(from: response)

        // Declaration is parsed from the WALKTHROUGH tag.
        #expect(declaration?.totalStepCount == 3)

        // The first STEP tag is the parsed result.
        #expect(step?.stepNumber == 1)
        #expect(step?.instruction == "Open Safari")

        // ALL tag occurrences must be absent from the spoken text.
        #expect(!strippedText.contains("[WALKTHROUGH:"), "WALKTHROUGH tag must be stripped")
        #expect(!strippedText.contains("[STEP:"), "Both STEP tags must be stripped")

        // The surrounding natural-language text must survive stripping.
        #expect(strippedText.contains("first do this"))
        #expect(strippedText.contains("then do that"))
        #expect(strippedText.contains("and you are ready"))
    }
}
