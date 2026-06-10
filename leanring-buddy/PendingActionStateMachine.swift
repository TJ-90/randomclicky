//
//  PendingActionStateMachine.swift
//  leanring-buddy
//
//  Pure static functions encoding the pending-action queue state machine for
//  Phase D (act mode), Unit 11.
//
//  DESIGN: PURE FUNCTIONS FOR TESTABILITY
//  ─────────────────────────────────────────────────────────────────────────────
//  All queue transitions are expressed as pure static functions:
//    input:  current queue + event
//    output: new queue state
//
//  No side effects, no async, no UI. This is the same pattern as
//  WalkthroughController's `transition(from:on:)` static function —
//  the UI/async layer (CompanionManager) calls these and applies the results.
//
//  This design makes every state transition directly unit-testable in
//  ActionTagParserTests.swift without mocking any dependencies.
//
//  QUEUE SEMANTICS
//  ─────────────────────────────────────────────────────────────────────────────
//  The queue is a [ParsedElementAction] where index 0 is the HEAD — the action
//  currently awaiting user confirmation. Only the head is ever shown to the user
//  at a time. The rest of the queue waits invisibly until the head resolves.
//
//  Transitions:
//    confirmHead     → dequeue head, return it for execution; next head becomes pending
//    cancelAll       → clear entire queue (explicit user cancel)
//    abortOnKillSwitch → clear entire queue (Esc / PTT kill switch)
//    expireCurrent   → clear entire queue (15s expiry timer)
//
//  KILL SWITCH CONTRACT
//  ─────────────────────────────────────────────────────────────────────────────
//  Both Esc (observed by the CGEvent listen-only tap) and any PTT press
//  must clear ALL pending actions and call
//  `ActionExecutionService.shared.abortCurrentAction()` for any in-flight chain.
//  The state machine handles only the queue clearing; the abort signal to
//  ActionExecutionService is the caller's responsibility.
//
//  ACT-MODE GATE
//  ─────────────────────────────────────────────────────────────────────────────
//  `filterActionsForEnqueuing` enforces the act-mode flag. Parsed actions that
//  pass through the parser are dropped here when act mode is off. The parser
//  itself is mode-agnostic — mode gating lives here so it is testable in
//  isolation from the parsing step.
//
//  The "at most once per response" notice is signalled by
//  `shouldShowActModeOffNotice` — true only when act mode is off AND at least
//  one action was dropped. CompanionManager calls this once per response and
//  prepends a one-line notice to the TTS text when the flag is true.
//

import Foundation

// MARK: - PendingActionStateMachine

/// Pure static functions for the pending-action queue state machine.
///
/// All functions take the current queue as a parameter and return the resulting
/// queue (or a dequeued action). No mutation of shared state occurs here.
enum PendingActionStateMachine {

    // MARK: - Queue inspection

    /// Returns the action currently awaiting confirmation (the head of the
    /// queue), or nil if the queue is empty.
    ///
    /// The head is always at index 0. CompanionManager shows a confirmation
    /// panel for the head and leaves the rest of the queue invisible until
    /// the head resolves.
    static func currentPendingAction(queue: [ParsedElementAction]) -> ParsedElementAction? {
        return queue.first
    }

    // MARK: - Confirm transition

    /// Returns the head action that should be executed, or nil if the queue
    /// is empty.
    ///
    /// The caller must separately call `queueAfterConfirmingHead` to remove
    /// the head from the queue. The two-step API exists so the caller can
    /// execute the returned action before deciding whether to advance.
    ///
    /// Note: this function does NOT guarantee the action can be executed —
    /// the caller must still pass it to `ActionExecutionService.execute(_:)`.
    /// The name reflects intent, not a guarantee of success.
    static func confirmHead(queue: [ParsedElementAction]) -> ParsedElementAction? {
        return queue.first
    }

    /// Returns the queue with the head action removed. The next action (if any)
    /// becomes the new head and will await its own confirmation.
    ///
    /// Call this AFTER executing the action returned by `confirmHead`.
    static func queueAfterConfirmingHead(queue: [ParsedElementAction]) -> [ParsedElementAction] {
        guard !queue.isEmpty else { return [] }
        return Array(queue.dropFirst())
    }

    // MARK: - Cancel / abort transitions (all return an empty queue)

    /// Explicit user cancellation — clears the entire queue.
    ///
    /// Called when:
    ///   - The user clicks the Cancel button in the confirmation panel.
    ///   - The user presses Esc (in addition to aborting via the kill switch).
    ///
    /// CompanionManager speaks a brief acknowledgment on explicit cancel.
    static func cancelAllPendingActions(queue: [ParsedElementAction]) -> [ParsedElementAction] {
        return []
    }

    /// Kill-switch abort — clears the entire queue.
    ///
    /// Called when:
    ///   - Esc is observed by the listen-only CGEvent tap (global, even when the
    ///     confirmation panel is not key).
    ///   - Any PTT press occurs while actions are pending or in-flight.
    ///
    /// The caller is also responsible for calling
    /// `ActionExecutionService.shared.abortCurrentAction()` to abort any
    /// in-flight execution chain. This function only clears the queue.
    ///
    /// The semantics are identical to `cancelAllPendingActions` — a separate
    /// function name makes the intent (kill switch vs. deliberate cancel)
    /// explicit at the call site, which makes code reviews and debugging easier.
    static func abortAllPendingActionsOnKillSwitch(queue: [ParsedElementAction]) -> [ParsedElementAction] {
        return []
    }

    /// Expiry timeout — clears the entire queue silently.
    ///
    /// Called when the 15s confirmation panel expiry timer fires. The action
    /// is dropped without any spoken acknowledgment (per the plan spec: "silent
    /// expiry" — only explicit cancel speaks).
    static func expireCurrentPendingAction(queue: [ParsedElementAction]) -> [ParsedElementAction] {
        return []
    }

    // MARK: - Act-mode gate

    /// Filters the parsed actions list based on the current act-mode flag.
    ///
    /// When act mode is off: returns an empty array (no actions are enqueued).
    /// When act mode is on:  returns the parsed actions unchanged.
    ///
    /// This is called by CompanionManager after ActionTagParser produces
    /// parsed actions — the gate lives here rather than in the parser so
    /// it is independently testable.
    ///
    /// - Parameters:
    ///   - parsedActions: The actions produced by `ActionTagParser.parseActionTags`.
    ///   - isActModeEnabled: Current value of the act-mode UserDefaults flag.
    /// - Returns: The actions that should actually be enqueued.
    static func filterActionsForEnqueuing(
        parsedActions: [ParsedElementAction],
        isActModeEnabled: Bool
    ) -> [ParsedElementAction] {
        guard isActModeEnabled else {
            // Act mode is off — drop all actions. None should reach the
            // confirmation panel or ActionExecutionService.
            return []
        }
        return parsedActions
    }

    /// Returns `true` when Clicky should speak the "act mode is off" notice.
    ///
    /// The notice fires at most once per response (CallerCompanionManager tracks
    /// this at the call site). It fires only when:
    ///   1. Act mode is currently off, AND
    ///   2. At least one action was parsed (i.e. Claude tried to do something,
    ///      but cannot because the user hasn't enabled act mode).
    ///
    /// We do NOT notice on responses that contain no action tags — there is
    /// nothing to draw attention to.
    ///
    /// - Parameters:
    ///   - parsedActions: The actions produced by `ActionTagParser.parseActionTags`.
    ///   - isActModeEnabled: Current value of the act-mode UserDefaults flag.
    /// - Returns: `true` when a one-line "act mode is off" notice should be
    ///   prepended to the spoken response text.
    static func shouldShowActModeOffNotice(
        parsedActions: [ParsedElementAction],
        isActModeEnabled: Bool
    ) -> Bool {
        // Notice only makes sense if there were actions to drop.
        guard !parsedActions.isEmpty else { return false }
        // Notice only fires when mode is off.
        return !isActModeEnabled
    }

    // MARK: - Validation

    /// Validates that an element ID from a `ParsedElementAction` exists in
    /// the current AX inventory.
    ///
    /// Returns the matching `AccessibleElement` if found, or nil if the ID is
    /// unknown (inventory nil, capped, element disappeared since the walk).
    ///
    /// When nil is returned, CompanionManager should either:
    ///   - Drop the action (if all actions in the response are unresolvable).
    ///   - Speak a brief note: "I couldn't find that element — it may have changed."
    ///
    /// This is a pure function so the validation logic is testable without
    /// constructing a live AX walk.
    static func resolveElementForAction(
        action: ParsedElementAction,
        inventory: AccessibilityElementInventory?
    ) -> AccessibleElement? {
        guard let inventory else { return nil }
        return inventory.elements.first { $0.elementID == action.elementID }
    }
}
