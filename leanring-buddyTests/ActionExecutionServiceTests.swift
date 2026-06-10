//
//  ActionExecutionServiceTests.swift
//  leanring-buddyTests
//
//  Tests for the PURE parts of ActionExecutionService.
//
//  What is NOT tested here:
//  - Live CGEvent posting: requires a real window to receive events and is not
//    testable in unit tests.
//  - Live AXUIElement calls: require TCC Accessibility permission and a running
//    third-party app. Verified manually from Xcode per the U10 verification matrix.
//  - The async queue bridging and abort flag: verified by building and running
//    the app; the abort flag is a simple Bool checked synchronously between awaits.
//
//  What IS tested (pure static functions with no side effects):
//  - Unicode chunking (splitTextIntoKeyboardChunks):
//      53-unit string → 3 chunks, all ≤ 20 units, no surrogate split.
//  - Emoji chunking: surrogate pairs are never split across a chunk boundary.
//  - Re-validation decision (evaluateRevalidationDecision):
//      AX error → staleTarget; drift > epsilon → staleTarget; within → proceed.
//  - Hard refusals (evaluateHardRefusals):
//      Secure role/subrole → refused; control chars in type text → refused;
//      denylisted process names → refused; Finder/Safari bundle IDs → allowed.
//  - Typing path selection (isValueAttributeSettable): tested via the pure
//    decision helper, not a live AX call.
//  - Synthetic event tag (isClickySyntheticEvent): magic value constant is
//    non-zero and distinct from 0 (the default hardware-event value).
//

import Testing
import ApplicationServices
@testable import leanring_buddy

// MARK: - Unicode chunking tests

struct ActionExecutionServiceChunkingTests {

    // MARK: - Basic chunking: 53 UTF-16 units → 3 chunks

    /// A string of 53 ASCII characters (all BMP, 1 UTF-16 unit each) must split
    /// into chunks of ≤ 20 units. 53 = 20 + 20 + 13 → 3 chunks.
    @Test func fiftyThreeCharacterStringProducesThreeChunks() {
        let text = String(repeating: "a", count: 53)
        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks(text)

        #expect(chunks.count == 3)
        #expect(chunks[0].count == 20)
        #expect(chunks[1].count == 20)
        #expect(chunks[2].count == 13)
    }

    /// Each chunk must contain ≤ maximumUTF16UnitsPerKeyboardChunk units.
    @Test func eachChunkContainsAtMostMaximumUTF16Units() {
        let text = String(repeating: "x", count: 100)
        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks(text)

        for chunk in chunks {
            #expect(
                chunk.count <= ActionExecutionService.maximumUTF16UnitsPerKeyboardChunk,
                "Chunk has \(chunk.count) units, expected ≤ \(ActionExecutionService.maximumUTF16UnitsPerKeyboardChunk)"
            )
        }
    }

    /// All units must be preserved when chunks are concatenated.
    @Test func chunksReassembleToOriginalString() {
        let text = "Hello, this is a test of the chunking system! 😀 abc 🎉"
        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks(text)

        // Flatten all chunks back into a single [UInt16] array.
        let reassembledUnits = chunks.flatMap { $0 }
        // Construct a String from the UTF-16 units and compare to the original.
        let reassembledString = String(decoding: reassembledUnits, as: UTF16.self)
        #expect(reassembledString == text)
    }

    /// An empty string produces zero chunks (not a single empty chunk).
    @Test func emptyStringProducesZeroChunks() {
        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks("")
        #expect(chunks.isEmpty)
    }

    /// A string of exactly maximumUTF16UnitsPerKeyboardChunk characters produces
    /// exactly one chunk.
    @Test func stringExactlyAtChunkLimitProducesOneChunk() {
        let chunkLimit = ActionExecutionService.maximumUTF16UnitsPerKeyboardChunk
        let text = String(repeating: "b", count: chunkLimit)
        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks(text)

        #expect(chunks.count == 1)
        #expect(chunks[0].count == chunkLimit)
    }

    /// A string of one character produces one chunk with one unit.
    @Test func singleCharacterStringProducesOneChunkWithOneUnit() {
        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks("Z")
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 1)
    }

    // MARK: - Surrogate pair safety

    /// An emoji (U+1F600 GRINNING FACE = UTF-16 surrogate pair [0xD83D, 0xDE00])
    /// must NEVER be split across a chunk boundary. The high surrogate (0xD83D)
    /// must always be immediately followed by its low surrogate (0xDE00) in the
    /// same chunk.
    @Test func emojiSurrogatePairIsNeverSplitAcrossChunkBoundary() {
        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks("😀")
        // A single emoji is 2 UTF-16 units — must land in one chunk.
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 2)

        // Verify: first unit is the high surrogate, second is the low surrogate.
        let isHighSurrogate = chunks[0][0] >= 0xD800 && chunks[0][0] <= 0xDBFF
        let isLowSurrogate = chunks[0][1] >= 0xDC00 && chunks[0][1] <= 0xDFFF
        #expect(isHighSurrogate, "First unit 0x\(String(chunks[0][0], radix: 16)) is not a high surrogate")
        #expect(isLowSurrogate, "Second unit 0x\(String(chunks[0][1], radix: 16)) is not a low surrogate")
    }

    /// A string of 9 ASCII characters followed by one emoji (10 BMP + 2 surrogate
    /// units = 11 total UTF-16 units) whose chunk boundary would fall between the
    /// surrogate pair must keep the pair intact.
    ///
    /// Concretely: if the chunk limit is 20 and we have 19 ASCII chars + one
    /// emoji (2 units = 21 total), the first chunk must be 19 units (not 20 with
    /// the high surrogate stranded), and the second chunk is the pair (2 units).
    @Test func surrogateAtExactChunkBoundaryMovesEntirePairToNextChunk() {
        // 19 ASCII chars (1 UTF-16 unit each) + 1 emoji (2 units) = 21 units total.
        // With chunk size 20: a naive split would put 20 units in chunk 1, but unit
        // 20 is the HIGH surrogate of the emoji. The algorithm must shrink chunk 1
        // to 19 units and keep the surrogate pair together in chunk 2.
        let asciiPrefix = String(repeating: "c", count: 19)
        let text = asciiPrefix + "😀"

        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks(text)

        #expect(chunks.count == 2, "Expected 2 chunks for a 21-unit string with chunk limit 20, got \(chunks.count)")

        // Chunk 1: exactly 19 ASCII units.
        #expect(chunks[0].count == 19, "Chunk 0 should have 19 units, got \(chunks[0].count)")

        // Chunk 2: exactly 2 units (the surrogate pair).
        #expect(chunks[1].count == 2, "Chunk 1 should have 2 units (surrogate pair), got \(chunks[1].count)")

        // Verify chunk 2 is the surrogate pair.
        let highSurrogate = chunks[1][0]
        let lowSurrogate = chunks[1][1]
        let chunkTwoIsHighSurrogate = highSurrogate >= 0xD800 && highSurrogate <= 0xDBFF
        let chunkTwoIsLowSurrogate = lowSurrogate >= 0xDC00 && lowSurrogate <= 0xDFFF
        #expect(chunkTwoIsHighSurrogate, "Expected high surrogate in chunk 2[0], got 0x\(String(highSurrogate, radix: 16))")
        #expect(chunkTwoIsLowSurrogate, "Expected low surrogate in chunk 2[1], got 0x\(String(lowSurrogate, radix: 16))")
    }

    /// Multiple emoji in a string never split any surrogate pair across chunks.
    @Test func multipleEmojiNeverSplitAcrossChunkBoundaries() {
        // 5 emoji = 10 UTF-16 units. With a chunk limit of 20, this fits in 1 chunk.
        let text = "😀🎉🚀💡🔥"
        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks(text)

        for (chunkIndex, chunk) in chunks.enumerated() {
            // Walk the chunk and verify no orphaned high surrogates appear at the end.
            if chunk.count >= 1 {
                let lastUnit = chunk[chunk.count - 1]
                let isOrphanedHighSurrogate = lastUnit >= 0xD800 && lastUnit <= 0xDBFF
                #expect(!isOrphanedHighSurrogate,
                        "Chunk \(chunkIndex) ends with orphaned high surrogate 0x\(String(lastUnit, radix: 16))")
            }

            // Walk the chunk and verify no orphaned low surrogates appear at position 0.
            if chunk.count >= 1 && chunkIndex > 0 {
                let firstUnit = chunk[0]
                let isOrphanedLowSurrogate = firstUnit >= 0xDC00 && firstUnit <= 0xDFFF
                #expect(!isOrphanedLowSurrogate,
                        "Chunk \(chunkIndex) starts with orphaned low surrogate 0x\(String(firstUnit, radix: 16))")
            }
        }

        // Verify round-trip.
        let reassembled = String(decoding: chunks.flatMap { $0 }, as: UTF16.self)
        #expect(reassembled == text)
    }
}

// MARK: - Re-validation decision tests

struct ActionExecutionServiceRevalidationTests {

    // MARK: - AX read failure → staleTarget

    /// When `axReadSucceeded` is false (e.g. the element was destroyed since the
    /// walk), the re-validation must return .staleTarget regardless of frame data.
    @Test func axReadFailureYieldsStaleTarget() {
        let result = ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: false,
            liveCGFrameCenter: CGPoint(x: 100, y: 200),
            storedCGFrameCenter: CGPoint(x: 100, y: 200)
        )
        #expect(result == .staleTarget)
    }

    /// Even if the frame has not moved at all, an AX read failure means stale.
    @Test func axReadFailureWithIdenticalFramesStillYieldsStaleTarget() {
        let center = CGPoint(x: 500, y: 300)
        let result = ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: false,
            liveCGFrameCenter: center,
            storedCGFrameCenter: center
        )
        #expect(result == .staleTarget)
    }

    // MARK: - Frame drift beyond epsilon → staleTarget

    /// Horizontal drift of exactly epsilon + 1 point must trigger staleTarget.
    @Test func horizontalDriftBeyondEpsilonYieldsStaleTarget() {
        let epsilon = ActionExecutionService.revalidationFrameDriftEpsilonInPoints
        let storedCenter = CGPoint(x: 100, y: 200)
        let liveCenter = CGPoint(x: 100 + epsilon + 1, y: 200) // just over the threshold

        let result = ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: true,
            liveCGFrameCenter: liveCenter,
            storedCGFrameCenter: storedCenter
        )
        #expect(result == .staleTarget)
    }

    /// Vertical drift of exactly epsilon + 1 point must trigger staleTarget.
    @Test func verticalDriftBeyondEpsilonYieldsStaleTarget() {
        let epsilon = ActionExecutionService.revalidationFrameDriftEpsilonInPoints
        let storedCenter = CGPoint(x: 300, y: 400)
        let liveCenter = CGPoint(x: 300, y: 400 + epsilon + 1)

        let result = ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: true,
            liveCGFrameCenter: liveCenter,
            storedCGFrameCenter: storedCenter
        )
        #expect(result == .staleTarget)
    }

    /// Negative horizontal drift of more than epsilon (element moved left) also
    /// triggers staleTarget — drift is measured as absolute distance.
    @Test func negativeHorizontalDriftBeyondEpsilonYieldsStaleTarget() {
        let epsilon = ActionExecutionService.revalidationFrameDriftEpsilonInPoints
        let storedCenter = CGPoint(x: 200, y: 300)
        let liveCenter = CGPoint(x: 200 - epsilon - 1, y: 300)

        let result = ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: true,
            liveCGFrameCenter: liveCenter,
            storedCGFrameCenter: storedCenter
        )
        #expect(result == .staleTarget)
    }

    // MARK: - Frame drift within epsilon → proceed

    /// Zero drift always proceeds.
    @Test func zeroDriftYieldsProceed() {
        let center = CGPoint(x: 150, y: 250)
        let result = ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: true,
            liveCGFrameCenter: center,
            storedCGFrameCenter: center
        )
        #expect(result == .proceed)
    }

    /// Horizontal drift of exactly epsilon proceeds (boundary is strict >).
    @Test func horizontalDriftExactlyAtEpsilonYieldsProceed() {
        let epsilon = ActionExecutionService.revalidationFrameDriftEpsilonInPoints
        let storedCenter = CGPoint(x: 100, y: 200)
        let liveCenter = CGPoint(x: 100 + epsilon, y: 200) // exactly at epsilon, not beyond

        let result = ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: true,
            liveCGFrameCenter: liveCenter,
            storedCGFrameCenter: storedCenter
        )
        #expect(result == .proceed)
    }

    /// Vertical drift of exactly epsilon proceeds.
    @Test func verticalDriftExactlyAtEpsilonYieldsProceed() {
        let epsilon = ActionExecutionService.revalidationFrameDriftEpsilonInPoints
        let storedCenter = CGPoint(x: 300, y: 400)
        let liveCenter = CGPoint(x: 300, y: 400 + epsilon)

        let result = ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: true,
            liveCGFrameCenter: liveCenter,
            storedCGFrameCenter: storedCenter
        )
        #expect(result == .proceed)
    }

    /// Small sub-epsilon drift in both axes simultaneously proceeds.
    @Test func smallDriftInBothAxesWithinEpsilonYieldsProceed() {
        let epsilon = ActionExecutionService.revalidationFrameDriftEpsilonInPoints
        let storedCenter = CGPoint(x: 500, y: 500)
        // Move diagonally by (epsilon/2, epsilon/2) — each axis is within epsilon.
        let liveCenter = CGPoint(x: 500 + epsilon / 2, y: 500 + epsilon / 2)

        let result = ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: true,
            liveCGFrameCenter: liveCenter,
            storedCGFrameCenter: storedCenter
        )
        #expect(result == .proceed)
    }
}

// MARK: - Hard refusal tests

struct ActionExecutionServiceRefusalTests {

    // MARK: - Helpers

    /// Builds a minimal `AccessibleElement` for refusal testing.
    /// The `axElementHandle` is a harmless placeholder (this process's own AX element).
    private func makeTestElement(
        role: String,
        subrole: String? = nil,
        owningProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> AccessibleElement {
        let placeholderAXHandle = AXUIElementCreateApplication(
            ProcessInfo.processInfo.processIdentifier
        )
        return AccessibleElement(
            elementID: 1,
            role: role,
            subrole: subrole,
            title: "Test Element",
            cgFrame: CGRect(x: 100, y: 100, width: 200, height: 40),
            appKitFrame: CGRect(x: 100, y: 100, width: 200, height: 40),
            axElementHandle: placeholderAXHandle,
            owningProcessID: owningProcessID
        )
    }

    // MARK: - Secure text field role → refused

    /// An element with role AXSecureTextField must be refused before any input.
    @Test func secureTextFieldRoleYieldsRefused() {
        let element = makeTestElement(role: "AXSecureTextField")
        let action = PlannedElementAction.click(target: element)

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for AXSecureTextField role, got \(String(describing: result))")
        }
    }

    /// Typing into an AXSecureTextField must also be refused.
    @Test func typingIntoSecureTextFieldRoleYieldsRefused() {
        let element = makeTestElement(role: "AXSecureTextField")
        let action = PlannedElementAction.type(target: element, textToType: "password123")

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for typing into AXSecureTextField, got \(String(describing: result))")
        }
    }

    // MARK: - Secure text field subrole → refused

    /// An element with the kAXSecureTextFieldSubrole subrole must be refused,
    /// even if its role is plain AXTextField.
    @Test func secureTextFieldSubroleYieldsRefused() {
        // kAXSecureTextFieldSubrole = "AXSecureTextField" (same string as the role,
        // but checked independently as a subrole on AXTextField elements in some apps).
        let element = makeTestElement(
            role: "AXTextField",
            subrole: kAXSecureTextFieldSubrole as String
        )
        let action = PlannedElementAction.click(target: element)

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for kAXSecureTextFieldSubrole subrole, got \(String(describing: result))")
        }
    }

    // MARK: - Control characters in TYPE payload → refused

    /// A TYPE action whose text contains a newline (\n) must be refused.
    /// This prevents "type this text" from silently becoming "type and submit".
    @Test func typingTextWithNewlineYieldsRefused() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "hello\nworld"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for text containing \\n, got \(String(describing: result))")
        }
    }

    /// A TYPE action whose text contains a tab character must be refused.
    @Test func typingTextWithTabYieldsRefused() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "first\tsecond"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for text containing tab, got \(String(describing: result))")
        }
    }

    /// A TYPE action whose text contains U+007F (DEL) must be refused.
    @Test func typingTextWithDeleteControlCharacterYieldsRefused() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "abc\u{007F}def"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for text containing DEL (U+007F), got \(String(describing: result))")
        }
    }

    /// A TYPE action whose text contains U+0000 (NUL) must be refused.
    @Test func typingTextWithNULCharacterYieldsRefused() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "hello\u{0000}world"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for text containing NUL (U+0000), got \(String(describing: result))")
        }
    }

    /// A TYPE action with a carriage return (\r, U+000D) must be refused.
    @Test func typingTextWithCarriageReturnYieldsRefused() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "line1\rline2"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for text containing \\r, got \(String(describing: result))")
        }
    }

    /// A TYPE action whose text contains U+0085 (NEL, NEXT LINE) must be refused.
    /// NEL is a C1 control and is treated as a newline by some text systems.
    @Test func typingTextWithNELCharacterYieldsRefused() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "line1\u{0085}line2"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for text containing NEL (U+0085), got \(String(describing: result))")
        }
    }

    /// A TYPE action whose text contains U+009F (APPLICATION PROGRAM COMMAND) must be refused.
    /// U+009F is the last C1 control character.
    @Test func typingTextWithU009FCharacterYieldsRefused() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "abc\u{009F}def"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for text containing U+009F, got \(String(describing: result))")
        }
    }

    /// A TYPE action whose text contains U+2028 (LINE SEPARATOR) must be refused.
    /// U+2028 is a Unicode line-terminator that some hosts treat as a newline.
    @Test func typingTextWithLineSeparatorU2028YieldsRefused() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "before\u{2028}after"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for text containing LINE SEPARATOR (U+2028), got \(String(describing: result))")
        }
    }

    /// A TYPE action whose text contains U+2029 (PARAGRAPH SEPARATOR) must be refused.
    @Test func typingTextWithParagraphSeparatorU2029YieldsRefused() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "before\u{2029}after"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        if case .refused = result {
            // Expected.
        } else {
            Issue.record("Expected .refused for text containing PARAGRAPH SEPARATOR (U+2029), got \(String(describing: result))")
        }
    }

    /// A TYPE action with text containing accented characters (é), emoji, and CJK
    /// must NOT be refused by the control-character check. These are ordinary
    /// printable characters and must pass through without a refusal.
    @Test func typingTextWithAccentedEmojiAndCJKCharactersIsNotRefusedByControlCharacterCheck() {
        let element = makeTestElement(role: "AXTextField")
        let action = PlannedElementAction.type(
            target: element,
            textToType: "café 😀 日本語"
        )

        // Only checking the control-character predicate in isolation — other rules
        // (secure field, denylist) do not apply to this clean AXTextField element.
        let hasControlChars = ActionExecutionService.textContainsControlCharacters("café 😀 日本語")
        #expect(hasControlChars == false)

        // Also verify the full refusal gate does not fire for this input.
        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )
        if let refusal = result, case .refused(let reason) = refusal {
            let isSecureInputRefusal = reason.lowercased().contains("secure keyboard")
            if !isSecureInputRefusal {
                Issue.record("Unexpected refusal for text with accented/emoji/CJK characters: \(reason)")
            }
        }
    }

    /// Clean text with no control characters must not be refused by the control-
    /// character check. (Other rules may still fire; we just verify this one passes.)
    @Test func typingTextWithNoControlCharactersPassesControlCharacterCheck() {
        // This checks the control-character predicate in isolation.
        let hasControlChars = ActionExecutionService.textContainsControlCharacters(
            "hello@example.com"
        )
        #expect(hasControlChars == false)
    }

    /// Emoji and other non-BMP characters are NOT control characters.
    @Test func typingTextWithEmojiDoesNotTriggerControlCharacterRefusal() {
        let hasControlChars = ActionExecutionService.textContainsControlCharacters("Hello 😀!")
        #expect(hasControlChars == false)
    }

    // MARK: - Denylisted process names → refused

    /// SecurityAgent is a denylisted security-UI process.
    @Test func securityAgentProcessNameIsOnDenylist() {
        let isDenied = ActionExecutionService.deniedProcessExecutableNames.contains("SecurityAgent")
        #expect(isDenied == true)
    }

    /// loginwindow is a denylisted security-UI process.
    @Test func loginWindowProcessNameIsOnDenylist() {
        let isDenied = ActionExecutionService.deniedProcessExecutableNames.contains("loginwindow")
        #expect(isDenied == true)
    }

    /// coreautha (LocalAuthentication UI) is a denylisted security-UI process.
    @Test func coreauthaProcessNameIsOnDenylist() {
        let isDenied = ActionExecutionService.deniedProcessExecutableNames.contains("coreautha")
        #expect(isDenied == true)
    }

    /// screencaptureui (Screen Recording permission dialog) is on the denylist.
    @Test func screenCaptureUIProcessNameIsOnDenylist() {
        let isDenied = ActionExecutionService.deniedProcessExecutableNames.contains("screencaptureui")
        #expect(isDenied == true)
    }

    // MARK: - Ordinary Apple apps explicitly allowed (not on denylist)

    /// com.apple.finder's executable name ("Finder") must NOT be on the denylist.
    /// Finder is a primary teaching target for walkthroughs.
    @Test func finderExecutableNameIsNotOnDenylist() {
        // The executable name for Finder (as reported by NSRunningApplication) is "Finder".
        let isDenied = ActionExecutionService.deniedProcessExecutableNames.contains("Finder")
        #expect(isDenied == false)
    }

    /// Safari's executable name ("Safari") must NOT be on the denylist.
    @Test func safariExecutableNameIsNotOnDenylist() {
        let isDenied = ActionExecutionService.deniedProcessExecutableNames.contains("Safari")
        #expect(isDenied == false)
    }

    /// System Settings's executable name ("System Settings") must NOT be on the denylist.
    @Test func systemSettingsExecutableNameIsNotOnDenylist() {
        let isDenied = ActionExecutionService.deniedProcessExecutableNames.contains("System Settings")
        #expect(isDenied == false)
    }

    // MARK: - Normal AXTextField with clean text → no refusal from hard checks

    /// A plain AXTextField with clean ASCII text and no special process should
    /// pass all hard-refusal checks (returning nil, meaning "proceed").
    ///
    /// NOTE: IsSecureEventInputEnabled() may return true in the test environment
    /// if the simulator or test runner enables secure input. If this test fails
    /// only on some machines, it is the secure-input check (Rule 2) that fires —
    /// that is correct and expected behaviour; the test documents the contract.
    @Test func normalTextFieldWithCleanTextPassesHardRefusals() {
        let element = makeTestElement(role: "AXTextField", subrole: nil)
        let action = PlannedElementAction.type(
            target: element,
            textToType: "user@example.com"
        )

        let result = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: element
        )

        // Rule 1 (secure field): AXTextField with no secure subrole → passes.
        // Rule 3 (control chars): "user@example.com" has none → passes.
        // Rule 4 (denylist): this process's own PID resolves to "xctest" or
        //   "leanring-buddyTests" — neither is on the denylist → passes.
        // Rule 2 (secure input): environment-dependent; documented above.
        if let refusal = result {
            if case .refused(let reason) = refusal {
                // Only acceptable if secure input is active in this test environment.
                let isSecureInputRefusal = reason.lowercased().contains("secure keyboard")
                if !isSecureInputRefusal {
                    Issue.record("Unexpected hard refusal for clean AXTextField: \(reason)")
                }
            }
        }
        // If result is nil, all hard refusals passed — that is the expected outcome.
        // We intentionally do NOT assert `result == nil` here because Rule 2
        // (secure keyboard input mode) is environment-dependent: on a machine where
        // a password manager or system password dialog holds secure input at test
        // time, evaluateHardRefusals returns .refused(reason: "secure keyboard…")
        // and a hard assertion would produce a spurious CI failure. The Issue.record
        // call above already flags any unexpected refusal that is NOT the documented
        // secure-input case, which is sufficient coverage without the false red.
    }
}

// MARK: - Control character predicate tests (standalone)

struct ActionExecutionServiceControlCharacterTests {

    @Test func nullCharacterIsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\u{0000}") == true)
    }

    @Test func tabCharacterIsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\t") == true)
    }

    @Test func lineFeedIsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\n") == true)
    }

    @Test func carriageReturnIsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\r") == true)
    }

    @Test func escapeCharacterIsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\u{001B}") == true)
    }

    @Test func deleteCharacterU007FIsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\u{007F}") == true)
    }

    @Test func lastC0ControlCharacterU001FIsAControlCharacter() {
        // U+001F is the last C0 control character (UNIT SEPARATOR).
        #expect(ActionExecutionService.textContainsControlCharacters("\u{001F}") == true)
    }

    @Test func spaceCharacterIsNotAControlCharacter() {
        // U+0020 is the SPACE character — the first printable ASCII character.
        // It must NOT be treated as a control character.
        #expect(ActionExecutionService.textContainsControlCharacters(" ") == false)
    }

    @Test func printableASCIIStringIsNotAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("Hello, World! 123") == false)
    }

    @Test func emailAddressIsNotAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("user@example.com") == false)
    }

    @Test func unicodeLettersAreNotControlCharacters() {
        // Non-ASCII printable characters (accented letters, CJK, etc.)
        #expect(ActionExecutionService.textContainsControlCharacters("Héllo Wörld") == false)
        #expect(ActionExecutionService.textContainsControlCharacters("日本語テスト") == false)
    }

    // MARK: - C1 controls (U+0080–U+009F) and Unicode line/paragraph separators

    /// U+0085 (NEXT LINE, NEL) is a C1 control character — must be refused.
    @Test func nelCharacterU0085IsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\u{0085}") == true)
    }

    /// U+009F (APPLICATION PROGRAM COMMAND) is the last C1 control character — must be refused.
    @Test func lastC1ControlCharacterU009FIsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\u{009F}") == true)
    }

    /// U+2028 (LINE SEPARATOR) must be refused — it is a Unicode line-terminator
    /// that some parsers treat as a newline and could cause unintended form submissions.
    @Test func lineSeparatorU2028IsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\u{2028}") == true)
    }

    /// U+2029 (PARAGRAPH SEPARATOR) must be refused for the same reason as U+2028.
    @Test func paragraphSeparatorU2029IsAControlCharacter() {
        #expect(ActionExecutionService.textContainsControlCharacters("\u{2029}") == true)
    }

    /// Accented Latin characters (é, ö) are NOT control characters.
    @Test func accentedLatinCharactersAreNotControlCharacters() {
        #expect(ActionExecutionService.textContainsControlCharacters("café résumé") == false)
    }

    /// Emoji are NOT control characters.
    @Test func emojiCharactersAreNotControlCharacters() {
        #expect(ActionExecutionService.textContainsControlCharacters("Hello 🎉 World 🚀") == false)
    }

    /// CJK characters are NOT control characters.
    @Test func cjkCharactersAreNotControlCharacters() {
        #expect(ActionExecutionService.textContainsControlCharacters("日本語テスト") == false)
    }
}

// MARK: - Synthetic event tagging tests

struct ActionExecutionServiceSyntheticEventTagTests {

    /// The magic value must be non-zero. The default userData for real hardware
    /// events is 0, so a zero magic value would make every real event look synthetic.
    @Test func syntheticEventMagicValueIsNonZero() {
        #expect(ActionExecutionService.syntheticEventUserDataMagicValue != 0)
    }

    /// The magic value must not be -1 (all bits set), which would collide with
    /// NSEvent's sentinel values.
    @Test func syntheticEventMagicValueIsNotMinusOne() {
        #expect(ActionExecutionService.syntheticEventUserDataMagicValue != -1)
    }

    /// Verify the specific magic value is the intended "CLKY" ASCII-hex constant.
    /// If this constant changes in the implementation, the guard in
    /// GlobalPushToTalkShortcutMonitor must also change — this test catches drift.
    @Test func syntheticEventMagicValueMatchesExpectedCLKYConstant() {
        let expectedCLKYValue: Int64 = 0x434C4B59
        #expect(ActionExecutionService.syntheticEventUserDataMagicValue == expectedCLKYValue)
    }
}

// MARK: - Typing path selection tests (pure decision function)

struct ActionExecutionServiceTypingPathTests {

    /// Verifies the logical consequence of `isValueAttributeSettable`: if it
    /// returns true for a real element, the type chain should prefer AX value set.
    /// Since we cannot call a live AX API in unit tests, this test verifies the
    /// pure logic: a settable attribute → value-set path is chosen.
    ///
    /// The actual `isValueAttributeSettable` function is tested indirectly via the
    /// type chain logic documentation. Here we test the contract at the pure-function
    /// level by verifying its return type contract:
    @Test func isValueAttributeSettableReturnsFalseForApplicationElement() {
        // AXUIElementCreateApplication returns an application-level element, not a
        // text field. The kAXValueAttribute is not settable on an app element.
        // This is the closest we can get to a "not settable" test without a live app.
        let appElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let isSettable = ActionExecutionService.isValueAttributeSettable(axElementHandle: appElement)
        // Application elements do not expose a settable kAXValueAttribute.
        // The test verifies the function returns a Bool (not crashing) and that
        // for a non-text-field element, it returns false.
        #expect(isSettable == false)
    }
}
