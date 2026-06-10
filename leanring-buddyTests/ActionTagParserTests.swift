//
//  ActionTagParserTests.swift
//  leanring-buddyTests
//
//  Tests for ActionTagParser.parseActionTags(from:) — the pure static function
//  that scans Claude's response text for CLICK and TYPE action tags, extracts
//  their element IDs, text payloads, and descriptions, and strips all action
//  tags from the spoken text.
//
//  GRAMMAR SUMMARY
//  ─────────────────────────────────────────────────────────────────────────────
//  Click:  [CLICK:E<id>:<description>]
//  Type:   [TYPE:E<id>:<text to type>:<description>]
//
//  DESCRIPTION IS THE LAST COLON-SEGMENT for TYPE.
//  Everything between E<id> and the final segment is the text to type.
//
//  Pixel-form CLICK/TYPE (e.g. [CLICK:100,200:desc]) → rejected, no action.
//  This is the deliberate safety floor documented in ActionTagParser.swift.
//
//  PENDING-ACTION STATE MACHINE TESTS
//  ─────────────────────────────────────────────────────────────────────────────
//  These tests cover the pure static state-transition helpers in
//  PendingActionStateMachine (defined in CompanionManager+PendingAction.swift).
//  They verify that:
//    - Confirm executes exactly once.
//    - Cancel clears the queue.
//    - A second action only confirms after the first resolves.
//    - PTT-press aborts all pending actions.
//    - Expiry cancels silently.
//    - Act-mode-off produces zero pending actions + the notice flag.
//
//  ARMING DELAY TESTS
//  ─────────────────────────────────────────────────────────────────────────────
//  The arming-delay pure function `ActionConfirmationPanelController
//  .isConfirmationArmed(panelShownAt:eventAt:armingDelay:)` is tested
//  directly so the 750ms boundary behaviour is verifiable without timers.
//

import Testing
import CoreGraphics
@testable import leanring_buddy

struct ActionTagParserTests {

    // MARK: - CLICK tag parsing

    /// Basic CLICK tag: element-ID form with description.
    @Test func clickTagWithElementIDAndDescriptionParsesCorrectly() {
        let response = "click the button [CLICK:E7:Click the Submit button]"

        let result = ActionTagParser.parseActionTags(from: response)

        #expect(result.actions.count == 1)
        let action = result.actions[0]
        #expect(action.kind == .click)
        #expect(action.elementID == 7)
        #expect(action.textToType == nil)
        #expect(action.claudeDescription == "Click the Submit button")
        // Tag must be stripped from spoken text.
        #expect(!result.strippedText.contains("[CLICK:"))
    }

    /// CLICK tag with a larger element ID.
    @Test func clickTagWithLargeElementIDParsesCorrectly() {
        let response = "open that menu [CLICK:E42:open the File menu]"

        let result = ActionTagParser.parseActionTags(from: response)

        #expect(result.actions.count == 1)
        #expect(result.actions[0].elementID == 42)
    }

    // MARK: - TYPE tag parsing

    /// Basic TYPE tag: element-ID, text, description.
    @Test func typeTagWithSimpleTextParsesCorrectly() {
        let response = "fill in the field [TYPE:E3:hello@example.com:Fill the email field]"

        let result = ActionTagParser.parseActionTags(from: response)

        #expect(result.actions.count == 1)
        let action = result.actions[0]
        #expect(action.kind == .type)
        #expect(action.elementID == 3)
        #expect(action.textToType == "hello@example.com")
        #expect(action.claudeDescription == "Fill the email field")
        #expect(!result.strippedText.contains("[TYPE:"))
    }

    /// TYPE text containing colons: the LAST segment is the description.
    ///
    /// Split rule: description = LAST colon-segment; everything between the
    /// element-ID segment and the last segment is joined with ":" as the text.
    ///
    ///   [TYPE:E3:see: this works:Fill it]
    ///     → elementID 3, text "see: this works", description "Fill it"
    @Test func typeTagWithColonsInTextParsesWithLastSegmentAsDescription() {
        let response = "[TYPE:E3:see: this works:Fill it]"

        let result = ActionTagParser.parseActionTags(from: response)

        #expect(result.actions.count == 1)
        let action = result.actions[0]
        #expect(action.elementID == 3)
        #expect(action.textToType == "see: this works")
        #expect(action.claudeDescription == "Fill it")
    }

    /// TYPE text with a URL containing multiple colons.
    ///
    ///   [TYPE:E2:https://example.com/path:enter the URL]
    ///     → elementID 2, text "https://example.com/path", description "enter the URL"
    @Test func typeTagWithURLContainingMultipleColonsParsesCorrectly() {
        let response = "[TYPE:E2:https://example.com/path:enter the URL]"

        let result = ActionTagParser.parseActionTags(from: response)

        #expect(result.actions.count == 1)
        let action = result.actions[0]
        #expect(action.elementID == 2)
        #expect(action.textToType == "https://example.com/path")
        #expect(action.claudeDescription == "enter the URL")
    }

    // MARK: - Pixel-form rejection (safety floor)

    /// Pixel-form CLICK is rejected — no action produced, tag still stripped.
    ///
    /// This is the deliberate safety floor: acting requires an AX-grounded
    /// element ID. A pixel-coordinate click bypasses pre-stage re-validation.
    @Test func pixelFormClickIsRejectedAndStrippedWithNoAction() {
        let response = "click here [CLICK:100,200:click this spot]"

        let result = ActionTagParser.parseActionTags(from: response)

        // No action produced (safety floor).
        #expect(result.actions.count == 0)
        // Tag is still stripped from spoken text.
        #expect(!result.strippedText.contains("[CLICK:"))
        // The surrounding text is preserved.
        #expect(result.strippedText.contains("click here"))
    }

    /// Pixel-form TYPE is also rejected.
    @Test func pixelFormTypeIsRejectedAndStrippedWithNoAction() {
        let response = "type here [TYPE:100,200:some text:description]"

        let result = ActionTagParser.parseActionTags(from: response)

        #expect(result.actions.count == 0)
        #expect(!result.strippedText.contains("[TYPE:"))
    }

    // MARK: - Malformed tags

    /// A CLICK tag with no description is malformed — no action, stripped.
    @Test func clickTagWithNoDescriptionIsStrippedWithNoAction() {
        let response = "broken tag [CLICK:E7]"

        let result = ActionTagParser.parseActionTags(from: response)

        #expect(result.actions.count == 0)
        #expect(!result.strippedText.contains("[CLICK:"))
    }

    /// A TYPE tag with only two segments (element ID + description, missing the
    /// text-to-type segment) is malformed.
    @Test func typeTagWithOnlyTwoSegmentsIsStrippedWithNoAction() {
        let response = "[TYPE:E5:description only]"

        let result = ActionTagParser.parseActionTags(from: response)

        // Two segments: "E5" and "description only" — ambiguous which is text
        // and which is description. Parser requires at least 3.
        #expect(result.actions.count == 0)
        #expect(!result.strippedText.contains("[TYPE:"))
    }

    /// An unknown tag kind is ignored (unknown tags are stripped).
    @Test func unknownTagKindIsStrippedWithNoAction() {
        let response = "do something [HOVER:E3:hover the thing]"

        // HOVER is not CLICK or TYPE — ActionTagParser should not match it
        // (its regex pattern only scans for CLICK and TYPE).
        let result = ActionTagParser.parseActionTags(from: response)

        // HOVER is not in the scan pattern, so the original text is preserved.
        #expect(result.actions.count == 0)
        // The HOVER tag should still be in the text (not stripped) since it
        // is not in the scan pattern.
        #expect(result.strippedText.contains("[HOVER:"))
    }

    // MARK: - Multiple actions

    /// Multiple action tags in one response are parsed in document order.
    @Test func multipleActionTagsParsedInDocumentOrder() {
        let response = "first [CLICK:E1:click first button] then [TYPE:E2:some text:type in field]"

        let result = ActionTagParser.parseActionTags(from: response)

        #expect(result.actions.count == 2)
        #expect(result.actions[0].kind == .click)
        #expect(result.actions[0].elementID == 1)
        #expect(result.actions[1].kind == .type)
        #expect(result.actions[1].elementID == 2)
        #expect(result.actions[1].textToType == "some text")
    }

    // MARK: - Text stripping and whitespace

    /// Tags stripped from middle of sentence collapse doubled spaces.
    @Test func strippedTagsCollapseDoubledSpaces() {
        let response = "click  [CLICK:E3:click it]  the button"

        let result = ActionTagParser.parseActionTags(from: response)

        // After stripping and collapsing, no doubled spaces.
        #expect(!result.strippedText.contains("  "))
    }

    /// Response with no action tags returns the original text unchanged.
    @Test func responseWithNoActionTagsReturnsOriginalText() {
        let response = "here is some text with no action tags [POINT:E1:something]"

        let result = ActionTagParser.parseActionTags(from: response)

        #expect(result.actions.isEmpty)
        // POINT is not in the action tag scan pattern — it must be untouched.
        #expect(result.strippedText.contains("[POINT:"))
    }
}

// MARK: - Arming delay pure function tests

struct ActionConfirmationArmingDelayTests {

    /// Event 200ms after panel shown — NOT armed (under 750ms threshold).
    @Test func eventAt200msIsNotArmed() {
        let panelShownAt = Date()
        let eventAt = panelShownAt.addingTimeInterval(0.200)

        let armed = ActionConfirmationPanelController.isConfirmationArmed(
            panelShownAt: panelShownAt,
            eventAt: eventAt,
            armingDelay: 0.750
        )

        #expect(!armed)
    }

    /// Event 800ms after panel shown — IS armed (over 750ms threshold).
    @Test func eventAt800msIsArmed() {
        let panelShownAt = Date()
        let eventAt = panelShownAt.addingTimeInterval(0.800)

        let armed = ActionConfirmationPanelController.isConfirmationArmed(
            panelShownAt: panelShownAt,
            eventAt: eventAt,
            armingDelay: 0.750
        )

        #expect(armed)
    }

    /// Event at EXACTLY 750ms — IS armed (boundary is inclusive: >= armingDelay).
    ///
    /// The spec says "Return is ignored for an arming delay (~750ms)". The
    /// implementation uses >= so the boundary is armed, matching user expectation
    /// that after exactly 750ms the button becomes active.
    @Test func eventAtExactlyArmingDelayBoundaryIsArmed() {
        let panelShownAt = Date()
        let eventAt = panelShownAt.addingTimeInterval(0.750)

        let armed = ActionConfirmationPanelController.isConfirmationArmed(
            panelShownAt: panelShownAt,
            eventAt: eventAt,
            armingDelay: 0.750
        )

        #expect(armed)
    }

    /// Event 749ms after panel shown — NOT armed (just under the boundary).
    @Test func eventAtJustUnderArmingDelayBoundaryIsNotArmed() {
        let panelShownAt = Date()
        let eventAt = panelShownAt.addingTimeInterval(0.749)

        let armed = ActionConfirmationPanelController.isConfirmationArmed(
            panelShownAt: panelShownAt,
            eventAt: eventAt,
            armingDelay: 0.750
        )

        #expect(!armed)
    }

    /// Custom arming delay parameter is respected.
    @Test func customArmingDelayParameterIsRespected() {
        let panelShownAt = Date()
        let eventAt = panelShownAt.addingTimeInterval(0.500)

        // With 1.0s arming delay, 500ms should NOT be armed.
        let notArmed = ActionConfirmationPanelController.isConfirmationArmed(
            panelShownAt: panelShownAt,
            eventAt: eventAt,
            armingDelay: 1.0
        )
        #expect(!notArmed)

        // With 0.4s arming delay, 500ms should be armed.
        let isArmed = ActionConfirmationPanelController.isConfirmationArmed(
            panelShownAt: panelShownAt,
            eventAt: eventAt,
            armingDelay: 0.4
        )
        #expect(isArmed)
    }
}

// MARK: - Pending action state machine tests

struct ActionConfirmationStateTests {

    // MARK: - Confirm executes exactly once

    /// Confirming a single pending action records one execution and produces
    /// no remaining actions.
    @Test func confirmingASinglePendingActionExecutesExactlyOnce() {
        let singleAction = ParsedElementAction(
            kind: .click,
            elementID: 1,
            textToType: nil,
            claudeDescription: "click something"
        )
        var queue = [singleAction]

        // Simulate confirm: dequeue the head and execute.
        let actionToExecute = PendingActionStateMachine.confirmHead(queue: queue)
        queue = PendingActionStateMachine.queueAfterConfirmingHead(queue: queue)

        #expect(actionToExecute?.elementID == 1)
        // After confirming the only item, queue is empty.
        #expect(queue.isEmpty)
        // Calling confirm again on the empty queue returns nil (executes nothing).
        let secondConfirm = PendingActionStateMachine.confirmHead(queue: queue)
        #expect(secondConfirm == nil)
    }

    // MARK: - Cancel clears the queue

    /// Cancelling the pending confirmation clears the entire action queue.
    @Test func cancellingClearsTheEntireQueue() {
        let actions = [
            ParsedElementAction(kind: .click, elementID: 1, textToType: nil, claudeDescription: "first"),
            ParsedElementAction(kind: .click, elementID: 2, textToType: nil, claudeDescription: "second"),
            ParsedElementAction(kind: .type, elementID: 3, textToType: "hello", claudeDescription: "third")
        ]

        let clearedQueue = PendingActionStateMachine.cancelAllPendingActions(queue: actions)

        #expect(clearedQueue.isEmpty)
    }

    // MARK: - Second action waits for first to resolve

    /// The confirmation panel should only show the HEAD of the queue.
    /// After the head is confirmed (and execution requested), the next action
    /// becomes the new head and awaits its own confirmation.
    @Test func secondActionBecomesActiveOnlyAfterFirstResolves() {
        let firstAction = ParsedElementAction(
            kind: .click, elementID: 1, textToType: nil, claudeDescription: "first"
        )
        let secondAction = ParsedElementAction(
            kind: .type, elementID: 2, textToType: "text", claudeDescription: "second"
        )
        var queue = [firstAction, secondAction]

        // Only the head (first action) should be presented.
        let currentHead = PendingActionStateMachine.currentPendingAction(queue: queue)
        #expect(currentHead?.elementID == 1)

        // After confirming the first action, the second becomes the new head.
        queue = PendingActionStateMachine.queueAfterConfirmingHead(queue: queue)
        let newHead = PendingActionStateMachine.currentPendingAction(queue: queue)
        #expect(newHead?.elementID == 2)
        #expect(queue.count == 1)
    }

    // MARK: - PTT press aborts all pending actions

    /// A PTT-press event (kill switch) aborts the entire queue — same as cancel.
    @Test func pttPressAbortsAllPendingActions() {
        let actions = [
            ParsedElementAction(kind: .click, elementID: 5, textToType: nil, claudeDescription: "five"),
            ParsedElementAction(kind: .click, elementID: 6, textToType: nil, claudeDescription: "six")
        ]

        // PTT abort uses the same queue-clearing logic as cancel.
        let queueAfterAbort = PendingActionStateMachine.abortAllPendingActionsOnKillSwitch(queue: actions)

        #expect(queueAfterAbort.isEmpty)
    }

    // MARK: - Expiry cancels silently (no error, empty result)

    /// Expiry timer firing clears the queue — same clearing behaviour as cancel.
    @Test func expiryTimerClearsTheQueue() {
        let actions = [
            ParsedElementAction(kind: .click, elementID: 10, textToType: nil, claudeDescription: "ten")
        ]

        let queueAfterExpiry = PendingActionStateMachine.expireCurrentPendingAction(queue: actions)

        #expect(queueAfterExpiry.isEmpty)
    }

    // MARK: - Empty queue edge cases

    /// Confirming the head of an empty queue returns nil and leaves the queue empty.
    @Test func confirmHeadOnEmptyQueueReturnsNil() {
        let emptyQueue: [ParsedElementAction] = []

        let action = PendingActionStateMachine.confirmHead(queue: emptyQueue)
        #expect(action == nil)

        let resultQueue = PendingActionStateMachine.queueAfterConfirmingHead(queue: emptyQueue)
        #expect(resultQueue.isEmpty)
    }

    /// Cancelling an empty queue returns an empty queue (no crash).
    @Test func cancellingEmptyQueueIsIdempotent() {
        let result = PendingActionStateMachine.cancelAllPendingActions(queue: [])
        #expect(result.isEmpty)
    }
}

// MARK: - Act-mode-off tests

struct ActModeOffBehaviourTests {

    /// When act mode is off, parseActionTags still parses the tags (they get
    /// stripped) but the caller (CompanionManager) must check `actModeEnabled`
    /// before enqueueing actions. The parser itself is mode-agnostic.
    ///
    /// This test verifies the parser returns parsed actions regardless — the
    /// mode gate lives in CompanionManager, not in the parser.
    @Test func parserIsAgnosticToActModeFlag() {
        let response = "[CLICK:E1:click the button]"

        // The parser always parses — mode gating is in CompanionManager.
        let result = ActionTagParser.parseActionTags(from: response)

        // Parser produces the action regardless of any mode flag.
        #expect(result.actions.count == 1)
        #expect(!result.strippedText.contains("[CLICK:"))
    }

    /// Act-mode-off gate in CompanionManager should suppress enqueueing.
    /// We test the pure gating function directly.
    @Test func actModeOffGateSuppressesEnqueueing() {
        let parsedActions = [
            ParsedElementAction(kind: .click, elementID: 1, textToType: nil, claudeDescription: "click")
        ]

        // When act mode is off, the gate returns an empty list (no actions enqueued).
        let actionsToEnqueue = PendingActionStateMachine.filterActionsForEnqueuing(
            parsedActions: parsedActions,
            isActModeEnabled: false
        )

        #expect(actionsToEnqueue.isEmpty)
    }

    /// Act-mode-on gate in CompanionManager passes actions through unchanged.
    @Test func actModeOnGatePassesActionsThroughUnchanged() {
        let parsedActions = [
            ParsedElementAction(kind: .click, elementID: 1, textToType: nil, claudeDescription: "click"),
            ParsedElementAction(kind: .type, elementID: 2, textToType: "text", claudeDescription: "type")
        ]

        let actionsToEnqueue = PendingActionStateMachine.filterActionsForEnqueuing(
            parsedActions: parsedActions,
            isActModeEnabled: true
        )

        #expect(actionsToEnqueue.count == 2)
    }

    /// When act mode is off and actions were dropped, the notice flag is set.
    @Test func actModeOffSetsNoticeFlagWhenActionsWereDropped() {
        let parsedActions = [
            ParsedElementAction(kind: .click, elementID: 1, textToType: nil, claudeDescription: "click")
        ]

        let shouldShowNotice = PendingActionStateMachine.shouldShowActModeOffNotice(
            parsedActions: parsedActions,
            isActModeEnabled: false
        )

        #expect(shouldShowNotice == true)
    }

    /// When act mode is off but no actions were present, no notice is needed.
    @Test func actModeOffWithNoActionsSetsNoNoticeFlag() {
        let shouldShowNotice = PendingActionStateMachine.shouldShowActModeOffNotice(
            parsedActions: [],
            isActModeEnabled: false
        )

        #expect(shouldShowNotice == false)
    }

    /// When act mode is on, no notice is shown regardless of parsed actions.
    @Test func actModeOnNeverSetsNoticeFlag() {
        let parsedActions = [
            ParsedElementAction(kind: .type, elementID: 5, textToType: "hello", claudeDescription: "type")
        ]

        let shouldShowNotice = PendingActionStateMachine.shouldShowActModeOffNotice(
            parsedActions: parsedActions,
            isActModeEnabled: true
        )

        #expect(shouldShowNotice == false)
    }
}
