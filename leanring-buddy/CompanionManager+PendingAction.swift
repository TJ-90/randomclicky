//
//  CompanionManager+PendingAction.swift
//  leanring-buddy
//
//  Phase D (act mode) wiring for CompanionManager — Unit 11.
//
//  This extension adds the pending-action queue, confirmation panel lifecycle,
//  kill-switch observation, act-mode flag, and walkthrough integration to the
//  existing CompanionManager.
//
//  ARCHITECTURE: EXTENSION, NOT EMBEDDED IN CompanionManager.swift
//  ─────────────────────────────────────────────────────────────────────────────
//  CompanionManager.swift is already ~2400 lines. This extension file contains
//  only Phase D additions so the diff between U10 and this unit is isolated and
//  reviewable. The extension is @MainActor to match the base class.
//
//  ACT-MODE FLAG (UserDefaults)
//  ─────────────────────────────────────────────────────────────────────────────
//  The act-mode toggle UI lives in U12 (CompanionPanelView). We define the
//  UserDefaults key and a computed property here so the gate is available to
//  U11 without waiting for U12. U12 will add the toggle button that writes
//  the same key.
//
//  The flag defaults to FALSE (act mode off by default, per R14). A first-time
//  user will never encounter action proposals until they explicitly enable the
//  toggle in the panel.
//
//  PENDING-ACTION QUEUE LIFECYCLE
//  ─────────────────────────────────────────────────────────────────────────────
//  1. Claude response arrives in sendTranscriptToClaudeWithScreenshot.
//  2. ActionTagParser strips CLICK/TYPE tags → [ParsedElementAction].
//  3. PendingActionStateMachine.filterActionsForEnqueuing enforces the mode gate.
//  4. Each action's element ID is resolved against inventoryForCurrentInteraction.
//     Unknown IDs are dropped (with a spoken note if ALL drop).
//  5. Actions are appended to pendingActionQueue.
//  6. If no confirmation is currently showing, presentNextPendingActionIfNeeded()
//     shows the confirmation panel for the head of the queue.
//  7. User confirms → ActionExecutionService.execute → result spoken →
//     queue advances to the next action.
//  8. User cancels / Esc / PTT / expiry → queue cleared.
//
//  WALKTHROUGH INTEGRATION
//  ─────────────────────────────────────────────────────────────────────────────
//  If a walkthrough is active when an action is confirmed and executed, the
//  executed action counts as the user performing the step. After the execution
//  result is spoken, CompanionManager calls runWalkthroughVerificationTurn()
//  so the walkthrough advances exactly as if the user had pressed "I did it".
//
//  KILL SWITCH
//  ─────────────────────────────────────────────────────────────────────────────
//  Two channels trigger the kill switch:
//    a. globalPushToTalkShortcutMonitor.escKeyObservedPublisher (Esc via CGEvent tap)
//    b. globalPushToTalkShortcutMonitor.shortcutTransitionPublisher (.pressed)
//
//  Both dismiss the confirmation panel (if showing), clear the queue, and call
//  ActionExecutionService.shared.abortCurrentAction() for in-flight chains.
//  The existing PTT-pressed handler in bindShortcutTransitions() already deals
//  with cancelling the current response task — the kill switch additions here
//  are purely additive.
//

import Combine
import Foundation
import SwiftUI

// MARK: - UserDefaults key constant

extension CompanionManager {

    // MARK: - Act-mode flag

    /// The UserDefaults key that stores whether act mode is enabled.
    ///
    /// U12 will write this key from the panel toggle. This constant is defined
    /// here so U11's gate logic can use it before U12 is implemented.
    static let actModeEnabledUserDefaultsKey = "actModeEnabled"

    /// Whether act mode is currently enabled.
    ///
    /// Act mode is OFF by default (R14). The toggle UI lives in U12;
    /// this computed property is the single read path for all U11 gate checks.
    ///
    /// Reading directly from UserDefaults (not a @Published wrapper) because:
    ///   - The gate is checked once per response, not continuously observed.
    ///   - We want U12 to own the @Published state without a second source of truth.
    var isActModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.actModeEnabledUserDefaultsKey)
    }
}

// MARK: - Pending-action state (stored in CompanionManager via associated object)

// Swift extensions cannot add stored properties. We use a small companion
// object (`PendingActionState`) held via objc_setAssociatedObject so the
// queue and controller reference live alongside CompanionManager without
// touching CompanionManager.swift.
//
// This is a well-established pattern for adding mutable state in extensions
// when you cannot modify the base file. The associated object lifetime matches
// the CompanionManager instance.

private enum AssociatedObjectKeys {
    // Use a static var address as the key — avoids string hashing.
    static var pendingActionState: UInt8 = 0
    static var killSwitchCancellables: UInt8 = 1
}

private final class PendingActionStateStorage {
    /// The queue of parsed actions awaiting confirmation. Index 0 is the head
    /// (currently showing confirmation panel). The rest wait invisibly.
    var pendingActionQueue: [ParsedElementAction] = []
    /// The controller managing the currently-visible confirmation panel, or nil
    /// when no panel is showing.
    var currentConfirmationPanelController: ActionConfirmationPanelController?
    /// Whether the "act mode is off" notice has already been spoken for the
    /// current response. Reset at the start of each response.
    var hasSpokenActModeOffNoticeThisResponse: Bool = false
    /// Combine cancellable bag for kill-switch subscriptions.
    var killSwitchCancellables = Set<AnyCancellable>()
    /// The Task spawned by handleActionConfirmed for the currently executing
    /// action. Stored so the kill-switch handler can cancel it alongside
    /// abortCurrentAction(), preventing TTS/queue mutations from racing the
    /// kill-switch cleanup after the abort flag fires.
    var currentActionExecutionTask: Task<Void, Never>?

    /// Backing stored property for the parallel resolved-element queue.
    ///
    /// Swift extensions cannot add stored properties, so we declare the backing
    /// ivar here directly on the class and expose it through a computed wrapper
    /// (`resolvedElementQueue`) in a private extension at the bottom of this file.
    /// Invariant: `_resolvedElementQueue[i]` is the resolved `AccessibleElement`
    /// that corresponds to `pendingActionQueue[i]`.
    var _resolvedElementQueue: [AccessibleElement]? = nil
}

extension CompanionManager {

    // MARK: - Private accessor for associated storage

    private var pendingActionStorage: PendingActionStateStorage {
        if let existing = objc_getAssociatedObject(self, &AssociatedObjectKeys.pendingActionState)
            as? PendingActionStateStorage {
            return existing
        }
        let newStorage = PendingActionStateStorage()
        objc_setAssociatedObject(
            self,
            &AssociatedObjectKeys.pendingActionState,
            newStorage,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return newStorage
    }

    // MARK: - Kill-switch setup

    /// Subscribes to the Esc and PTT kill-switch channels. Call once from
    /// `start()` — the subscriptions are retained for the lifetime of the app.
    ///
    /// This method is safe to call multiple times; the `Set<AnyCancellable>`
    /// de-duplicates subscriptions (SwiftUI's store(in:) pattern).
    func bindActModeKillSwitchObservation() {
        // --- Esc key channel ---
        // escKeyObservedPublisher fires on keyDown for keyCode 53 (Escape).
        // The tap is listen-only; Esc may also reach the target app — accepted.
        globalPushToTalkShortcutMonitor.escKeyObservedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleActModeKillSwitchFired(source: "Esc key")
            }
            .store(in: &pendingActionStorage.killSwitchCancellables)

        // --- PTT pressed channel ---
        // Any PTT press also acts as a kill switch for pending actions, in
        // addition to its existing behaviour (cancels current response task, etc.).
        // We subscribe here in addition to the existing subscription in
        // bindShortcutTransitions() — the two subscriptions are independent
        // and neither interferes with the other.
        globalPushToTalkShortcutMonitor.shortcutTransitionPublisher
            .filter { $0 == .pressed }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Fire the kill switch if there are pending actions OR an action
                // is currently executing. The second condition is necessary because
                // handleActionConfirmed dequeues the head action BEFORE spawning
                // the async Task — so a single-action sequence leaves an empty
                // queue while ActionExecutionService is still in-flight. Without
                // this check, a PTT press during that window would return early
                // here and never call abortCurrentAction, letting the in-flight
                // action complete despite the user pressing the kill switch.
                guard let self,
                      !self.pendingActionStorage.pendingActionQueue.isEmpty
                          || ActionExecutionService.shared.isActionCurrentlyRunning
                else { return }
                self.handleActModeKillSwitchFired(source: "PTT press")
            }
            .store(in: &pendingActionStorage.killSwitchCancellables)
    }

    // MARK: - Response pipeline integration

    /// Called from `sendTranscriptToClaudeWithScreenshot` after the walkthrough
    /// tags have been stripped and before the POINT parser runs.
    ///
    /// This method:
    ///   1. Parses CLICK/TYPE tags from the (annotation+walkthrough-stripped) text.
    ///   2. Applies the act-mode gate.
    ///   3. Resolves element IDs against the current inventory.
    ///   4. Enqueues resolved actions.
    ///   5. Speaks the "act mode is off" notice (at most once per response) if needed.
    ///   6. Returns the action-tag-stripped text for the downstream POINT parser.
    ///
    /// - Parameter textAfterWalkthroughStripping: The response text after
    ///   annotation and walkthrough tags have been removed.
    /// - Returns: The text with CLICK/TYPE tags also removed, ready for the
    ///   POINT parser.
    @MainActor
    func processActionTagsAndEnqueue(
        textAfterWalkthroughStripping: String
    ) -> String {
        // FIX 3: clear any leftover queued actions from a previous turn at the
        // turn boundary. Each call to processActionTagsAndEnqueue represents a
        // new Claude response — actions from a prior response were enqueued
        // against a prior inventory and screen state. If the user triggered a new
        // turn before confirming or cancelling those actions, the old entries must
        // be discarded so they cannot resurface stale against the new inventory.
        // This clear runs unconditionally (before the in-flight guard below) so a
        // new turn always starts with a clean queue regardless of prior state.
        // The in-flight guard below handles the separate case of a mid-execution
        // new turn arriving while execute() is running.
        if !pendingActionStorage.pendingActionQueue.isEmpty {
            pendingActionStorage.pendingActionQueue = []
            pendingActionStorage.resolvedElementQueue = []
            clearPendingActionHighlight()
            print("⚠️ Act mode: stale queue cleared at turn boundary")
        }

        // Guard: if an action is currently executing, discard any new actions
        // that arrive (e.g. from a PTT turn the user initiated before the
        // previous action finished). Silently enqueueing new actions on top of
        // an in-flight execution would create a race — the in-flight action's
        // queue-advance logic (presentNextPendingActionIfNeeded) runs after the
        // async Task completes, so new items appended here could be presented
        // twice or executed out of order. A brief spoken notice tells the user
        // to wait and try again.
        if ActionExecutionService.shared.isActionCurrentlyRunning {
            print("⚠️ Act mode: new action tags arrived while an action is in-flight — discarding")
            // Prepend a brief notice to the spoken text so the user knows why
            // the action was not queued, then return the stripped text normally
            // so the rest of Claude's response is still spoken.
            let actionParseResultForStripping = ActionTagParser.parseActionTags(from: textAfterWalkthroughStripping)
            let stillWorkingNotice = "still working on the previous action — "
            return stillWorkingNotice + actionParseResultForStripping.strippedText
        }

        // Reset the per-response notice flag so this response can emit the
        // notice if appropriate.
        pendingActionStorage.hasSpokenActModeOffNoticeThisResponse = false

        // Step 1: Parse CLICK/TYPE tags.
        let actionParseResult = ActionTagParser.parseActionTags(from: textAfterWalkthroughStripping)

        // Early return if no action tags were found.
        guard !actionParseResult.actions.isEmpty else {
            return actionParseResult.strippedText
        }

        // Step 2: Act-mode gate — determine which actions to enqueue.
        let actionsToEnqueue = PendingActionStateMachine.filterActionsForEnqueuing(
            parsedActions: actionParseResult.actions,
            isActModeEnabled: isActModeEnabled
        )

        // Step 3: Speak the "act mode is off" notice (at most once per response).
        // We check this AFTER parsing so the notice only fires when actions were
        // actually present in the response (Claude tried to do something but can't).
        if PendingActionStateMachine.shouldShowActModeOffNotice(
            parsedActions: actionParseResult.actions,
            isActModeEnabled: isActModeEnabled
        ) && !pendingActionStorage.hasSpokenActModeOffNoticeThisResponse {
            pendingActionStorage.hasSpokenActModeOffNoticeThisResponse = true
            // Prepend the notice to the spoken text by returning it as a prefix.
            // CompanionManager will speak the returned text through TTS; the notice
            // lands naturally before the rest of Claude's response.
            let noticePrefix = "act mode is off, so I can't perform that action. "
            print("🔒 Act mode is off — CLICK/TYPE actions dropped, notice will be spoken")
            // We modify the stripped text to prepend the notice. The strippedText
            // has action tags removed — we inject the notice at the front.
            let textWithNotice = noticePrefix + actionParseResult.strippedText
            return textWithNotice
        }

        // Act mode is on — proceed with enqueueing.
        if actionsToEnqueue.isEmpty {
            return actionParseResult.strippedText
        }

        // Step 4: Resolve element IDs against the current inventory.
        var resolvedActions: [(action: ParsedElementAction, element: AccessibleElement)] = []
        var droppedCount = 0

        for action in actionsToEnqueue {
            if let resolvedElement = PendingActionStateMachine.resolveElementForAction(
                action: action,
                inventory: inventoryForCurrentInteraction
            ) {
                resolvedActions.append((action: action, element: resolvedElement))
            } else {
                droppedCount += 1
                print("⚠️ Act mode: E\(action.elementID) not found in inventory — dropping action \"\(action.claudeDescription)\"")
            }
        }

        // If ALL actions were dropped due to unknown element IDs, speak a note.
        if resolvedActions.isEmpty && droppedCount > 0 {
            print("⚠️ Act mode: all actions dropped (element IDs not in inventory) — will speak note")
            // Inject a spoken note. This is rare (e.g. Claude hallucinated an ID
            // or the inventory was unavailable for this turn).
            let notePrefix = "I couldn't find those elements on screen right now — the app may have changed. "
            return notePrefix + actionParseResult.strippedText
        }

        // Step 5: Enqueue resolved actions.
        // Each entry carries the parsed action (for the confirmation UI) and the
        // resolved AccessibleElement (for ActionExecutionService).
        for (action, element) in resolvedActions {
            enqueueResolvedAction(action: action, resolvedElement: element)
        }

        print("🎬 Act mode: \(resolvedActions.count) action(s) enqueued, \(droppedCount) dropped")

        // Step 6: Return the stripped text (action tags removed).
        return actionParseResult.strippedText
    }

    // MARK: - Queue management

    /// Appends a resolved action to the pending queue and, if no confirmation
    /// panel is currently showing, starts presenting the head of the queue.
    private func enqueueResolvedAction(
        action: ParsedElementAction,
        resolvedElement: AccessibleElement
    ) {
        // Store the action alongside its resolved element so the confirmation
        // panel can show the element's AX role+title and the execution service
        // gets the live handle. We use a lightweight wrapper tuple for this.
        //
        // NOTE: We store these as parallel arrays in `pendingActionStorage`
        // to avoid defining a new struct that would bloat this extension.
        // The invariant is: pendingActionQueue[i] pairs with pendingElementQueue[i].
        pendingActionStorage.pendingActionQueue.append(action)

        // Also store the resolved element in a parallel array for execution.
        if pendingActionStorage.resolvedElementQueue == nil {
            pendingActionStorage.resolvedElementQueue = []
        }
        pendingActionStorage.resolvedElementQueue!.append(resolvedElement)

        // Analytics: action proposed. The target app bundle ID identifies which app
        // is being acted upon (e.g. "com.apple.Safari") — this is not user content.
        // IMPORTANT: the TYPE text payload must NEVER appear in any analytics call.
        // We only log the action kind ("click" or "type") and the bundle ID.
        ClickyAnalytics.trackActionProposed(
            actionKind: action.kind == .click ? "click" : "type",
            targetAppBundleID: resolvedElement.owningProcessID > 0
                ? (NSRunningApplication(processIdentifier: resolvedElement.owningProcessID)?
                    .bundleIdentifier ?? "unknown")
                : "unknown"
        )

        // If no confirmation panel is showing, show the head of the queue now.
        if pendingActionStorage.currentConfirmationPanelController == nil {
            presentNextPendingActionIfNeeded()
        }
    }

    // MARK: - Confirmation panel presentation

    /// Presents the confirmation panel for the head of the pending-action queue,
    /// if the queue is non-empty and no panel is currently showing.
    ///
    /// Also adds a HIGHLIGHT annotation for the target element so the user can
    /// see which element will be acted upon.
    private func presentNextPendingActionIfNeeded() {
        // FIX 4: guard against presenting a second panel while one is already
        // showing or while an action is executing. Without these guards, a second
        // call (e.g. from enqueueResolvedAction racing a slow confirmation
        // dismissal) would create a zombie panel with a leaked key monitor and
        // two active confirmation windows for the same queue head.
        // The post-execution continuation (handleActionConfirmed's success path)
        // calls presentNextPendingActionIfNeeded after the execution Task
        // completes, so the deferred presentation still fires correctly — the
        // guards here only block a premature duplicate presentation, not the
        // intended sequential presentation.
        guard pendingActionStorage.currentConfirmationPanelController == nil else {
            // A confirmation panel is already showing — do not create a second one.
            return
        }
        guard !ActionExecutionService.shared.isActionCurrentlyRunning else {
            // An action is in-flight — the post-execution callback will call
            // presentNextPendingActionIfNeeded again once it completes.
            return
        }

        guard let headAction = PendingActionStateMachine.currentPendingAction(
            queue: pendingActionStorage.pendingActionQueue
        ) else {
            // Queue is empty — nothing to show.
            return
        }

        guard let resolvedElements = pendingActionStorage.resolvedElementQueue,
              !resolvedElements.isEmpty else {
            return
        }

        let headElement = resolvedElements[0]

        // Format the AX element's role and title for the confirmation panel.
        // Example: AXButton "Submit" or AXTextField "Email"
        let axRoleAndTitle = formatAXElementRoleAndTitle(element: headElement)

        // Add a HIGHLIGHT annotation for the target element so it glows on screen
        // while the user decides. This is owned by the pending-action state (not
        // the pointing flight lifecycle), so it persists for the full confirmation
        // window. We synthesise a ResolvedScreenAnnotation directly.
        publishPendingActionHighlight(for: headElement)

        // Create the confirmation panel controller and show it.
        let controller = ActionConfirmationPanelController(
            pendingAction: headAction,
            axElementRoleAndTitle: axRoleAndTitle,
            onOutcome: { [weak self] outcome in
                self?.handleConfirmationOutcome(
                    outcome: outcome,
                    executedAction: headAction,
                    targetElement: headElement
                )
            }
        )

        pendingActionStorage.currentConfirmationPanelController = controller

        // Position the panel near the target element's AppKit frame.
        controller.show(near: headElement.appKitFrame)
    }

    // MARK: - Confirmation outcome handling

    /// Handles the outcome from the confirmation panel — confirmed, cancelled,
    /// or expired.
    private func handleConfirmationOutcome(
        outcome: ActionConfirmationOutcome,
        executedAction: ParsedElementAction,
        targetElement: AccessibleElement
    ) {
        // Clear the controller reference first — it has already dismissed itself.
        pendingActionStorage.currentConfirmationPanelController = nil

        switch outcome {
        case .confirmed:
            handleActionConfirmed(action: executedAction, targetElement: targetElement)

        case .cancelledByUser:
            // Explicit cancel: clear queue, remove highlight, speak brief acknowledgment.
            // Analytics: action cancelled. No text content in payload.
            let cancelledBundleID = (pendingActionStorage.resolvedElementQueue?.first)
                .flatMap { NSRunningApplication(processIdentifier: $0.owningProcessID)?.bundleIdentifier }
                ?? "unknown"
            ClickyAnalytics.trackActionCancelled(
                actionKind: executedAction.kind == .click ? "click" : "type",
                targetAppBundleID: cancelledBundleID
            )
            pendingActionStorage.pendingActionQueue = PendingActionStateMachine.cancelAllPendingActions(
                queue: pendingActionStorage.pendingActionQueue
            )
            pendingActionStorage.resolvedElementQueue = []
            clearPendingActionHighlight()
            // Brief spoken acknowledgment on explicit cancel only (not expiry).
            Task {
                do {
                    try await elevenLabsTTSClient.speakText("cancelled")
                } catch {
                    print("⚠️ Act mode cancel TTS error: \(error)")
                }
            }
            print("🔒 Act mode: action cancelled by user")

        case .expiredWithoutConfirmation:
            // Silent expiry: clear queue and highlight, speak nothing.
            pendingActionStorage.pendingActionQueue = PendingActionStateMachine.expireCurrentPendingAction(
                queue: pendingActionStorage.pendingActionQueue
            )
            pendingActionStorage.resolvedElementQueue = []
            clearPendingActionHighlight()
            print("🔒 Act mode: action expired without confirmation (silent)")
        }
    }

    /// Executes a confirmed action via ActionExecutionService and advances the queue.
    private func handleActionConfirmed(action: ParsedElementAction, targetElement: AccessibleElement) {
        print("🎬 Act mode: executing confirmed action E\(action.elementID) — \"\(action.claudeDescription)\"")

        // Analytics: action confirmed. No text content in payload — see privacy
        // note on trackActionProposed. Bundle ID identifies the target app only.
        let confirmedBundleID = NSRunningApplication(
            processIdentifier: targetElement.owningProcessID
        )?.bundleIdentifier ?? "unknown"
        ClickyAnalytics.trackActionConfirmed(
            actionKind: action.kind == .click ? "click" : "type",
            targetAppBundleID: confirmedBundleID
        )

        // Advance the queue first. If execution fails the queue is already clean
        // and the user is not left with a stale pending-action state.
        pendingActionStorage.pendingActionQueue = PendingActionStateMachine.queueAfterConfirmingHead(
            queue: pendingActionStorage.pendingActionQueue
        )
        // Advance the parallel element queue too.
        if let elements = pendingActionStorage.resolvedElementQueue, !elements.isEmpty {
            pendingActionStorage.resolvedElementQueue = Array(elements.dropFirst())
        }

        // Clear the highlight — the action is in-flight now.
        clearPendingActionHighlight()

        // Remember the walkthrough phase BEFORE execution. If a walkthrough is
        // active, a confirmed action counts as the user performing the step.
        let walkthroughWasActive = (walkthroughController.phase == .awaitingUserAction)

        // Build the PlannedElementAction for ActionExecutionService.
        let plannedAction: PlannedElementAction
        switch action.kind {
        case .click:
            plannedAction = .click(target: targetElement)
        case .type:
            let textToType = action.textToType ?? ""
            plannedAction = .type(target: targetElement, textToType: textToType)
        }

        // Resolve analytics values before entering the Task so they are stable
        // even if the target app exits mid-flight. PRIVACY: bundle ID only —
        // no user content, no TYPE text payload. The TYPE text must never leave
        // this device via any analytics call; it stays between the user and the
        // target app.
        let targetAppBundleIDForAnalytics = NSRunningApplication(
            processIdentifier: targetElement.owningProcessID
        )?.bundleIdentifier ?? "unknown"
        let actionKindStringForAnalytics = action.kind == .click ? "click" : "type"

        // Execute on the service (async, runs the AX safety chain).
        // FIX 5: store the Task so the kill-switch handler can cancel it
        // alongside abortCurrentAction(), preventing TTS/queue mutations from
        // racing kill-switch cleanup after the abort flag fires.
        let executionTask = Task {
            let executionResult = await ActionExecutionService.shared.execute(plannedAction)

            // FIX 5: if the kill switch fired and cancelled this Task while
            // execute() was in flight, do not speak feedback or mutate the queue
            // — the kill-switch handler already cleaned up state. Checking here
            // (after execute() returns) rather than inside execute() is correct
            // because cancellation races the AX chain; the abort flag causes
            // execute() to return .aborted, but Task.isCancelled provides an
            // independent signal that the cancel came from the kill switch itself
            // rather than from normal abort-flag flow.
            if Task.isCancelled {
                return
            }

            // Speak the result honestly.
            let spokenResult = spokenFeedbackForExecutionResult(
                result: executionResult,
                actionDescription: action.claudeDescription
            )
            if !spokenResult.isEmpty {
                try? await elevenLabsTTSClient.speakText(spokenResult)
            }

            // If execution failed or was refused, clear the rest of the queue.
            // We don't attempt the next action after a failure — the screen state
            // is unknown and the user should re-evaluate.
            switch executionResult {
            case .performed, .performedUnverified:
                // On success: if a walkthrough is active, route into verification
                // as though the user had pressed "I did it".
                if walkthroughWasActive {
                    // FIX 3: clear the remaining queue and highlight BEFORE routing
                    // into the walkthrough verification turn. The verification turn
                    // takes a fresh screenshot + inventory, so any queued actions
                    // that were enqueued against the old inventory are now stale —
                    // their element IDs and frames may no longer be valid. Letting
                    // them survive into the post-verification presentNextPendingAction
                    // call would execute stale actions against a changed screen state.
                    pendingActionStorage.pendingActionQueue = []
                    pendingActionStorage.resolvedElementQueue = []
                    clearPendingActionHighlight()
                    print("📋 Act mode: confirmed action completed — clearing stale queue before walkthrough verification")
                    runWalkthroughVerificationTurn()
                } else {
                    // Not in a walkthrough: present the next queued action if any.
                    presentNextPendingActionIfNeeded()
                }

            case .failed(let reason):
                // Analytics: action failed with a machine-readable reason string.
                // `reason` comes from ActionExecutionService — it is an internal
                // description, never user-typed content.
                ClickyAnalytics.trackActionFailed(
                    actionKind: actionKindStringForAnalytics,
                    targetAppBundleID: targetAppBundleIDForAnalytics,
                    failureReason: "failed:\(reason)"
                )
                pendingActionStorage.pendingActionQueue = []
                pendingActionStorage.resolvedElementQueue = []
                clearPendingActionHighlight()
                print("🔒 Act mode: queue cleared after failed result (\(reason))")

            case .refused(let reason):
                ClickyAnalytics.trackActionFailed(
                    actionKind: actionKindStringForAnalytics,
                    targetAppBundleID: targetAppBundleIDForAnalytics,
                    failureReason: "refused:\(reason)"
                )
                pendingActionStorage.pendingActionQueue = []
                pendingActionStorage.resolvedElementQueue = []
                clearPendingActionHighlight()
                print("🔒 Act mode: queue cleared after refused result (\(reason))")

            case .staleTarget:
                ClickyAnalytics.trackActionFailed(
                    actionKind: actionKindStringForAnalytics,
                    targetAppBundleID: targetAppBundleIDForAnalytics,
                    failureReason: "staleTarget"
                )
                pendingActionStorage.pendingActionQueue = []
                pendingActionStorage.resolvedElementQueue = []
                clearPendingActionHighlight()
                print("🔒 Act mode: queue cleared after staleTarget result")

            case .aborted:
                // Abort is user-initiated (kill switch fired). The kill switch
                // handler has already cleared state; this case is a safety net.
                pendingActionStorage.pendingActionQueue = []
                pendingActionStorage.resolvedElementQueue = []
                clearPendingActionHighlight()
                print("🔒 Act mode: queue cleared after aborted result")
            }
        }
        pendingActionStorage.currentActionExecutionTask = executionTask
    }

    // MARK: - Kill-switch handler

    /// Called by both the Esc and PTT kill-switch subscriptions.
    ///
    /// Aborts the in-flight action chain, dismisses the confirmation panel (if
    /// showing), and clears the entire pending queue.
    @MainActor
    func handleActModeKillSwitchFired(source: String) {
        // FIX 1: also fire when the LAST action is in-flight. Once the queue is
        // drained and the panel is dismissed, both the queue-empty and
        // panel-nil checks would early-return here — but ActionExecutionService
        // may still be executing that final confirmed action. Without this guard,
        // pressing Esc/PTT after confirmation but before execution completes is
        // silently ignored and the action runs to completion despite the user's
        // kill-switch intent.
        guard !pendingActionStorage.pendingActionQueue.isEmpty
              || pendingActionStorage.currentConfirmationPanelController != nil
              || ActionExecutionService.shared.isActionCurrentlyRunning else {
            // No pending actions and nothing executing — kill switch is a no-op for act mode.
            return
        }

        print("🔒 Act mode kill switch fired (\(source)) — aborting \(pendingActionStorage.pendingActionQueue.count) pending action(s)")

        // Abort any in-flight action chain in ActionExecutionService.
        // Gate behind isActionCurrentlyRunning so we never set the abort flag
        // when no action is executing — a stale true flag would cause the next
        // execute() call to return .aborted immediately before doing any work.
        if ActionExecutionService.shared.isActionCurrentlyRunning {
            ActionExecutionService.shared.abortCurrentAction()
        }

        // FIX 5: also cancel the stored execution Task so its post-execute body
        // (TTS, queue mutations) cannot race this kill-switch cleanup. The abort
        // flag above stops execute() mid-chain; cancelling the Task stops the
        // surrounding async body (TTS speak, queue writes) after execute() returns.
        pendingActionStorage.currentActionExecutionTask?.cancel()
        pendingActionStorage.currentActionExecutionTask = nil

        // Dismiss the confirmation panel without calling back (the kill switch
        // IS the outcome — we handle everything here).
        pendingActionStorage.currentConfirmationPanelController?.dismissWithoutCallback()
        pendingActionStorage.currentConfirmationPanelController = nil

        // Clear the entire queue.
        pendingActionStorage.pendingActionQueue = PendingActionStateMachine.abortAllPendingActionsOnKillSwitch(
            queue: pendingActionStorage.pendingActionQueue
        )
        pendingActionStorage.resolvedElementQueue = []

        // Remove the highlight annotation.
        clearPendingActionHighlight()
    }

    // MARK: - Highlight management

    /// Publishes a HIGHLIGHT annotation for the target element's AppKit frame.
    ///
    /// This highlights the element on screen while the confirmation panel is
    /// showing so the user can see exactly which element will be acted upon.
    /// The highlight is owned by pending-action state (not the flight lifecycle)
    /// and persists for the full confirmation window.
    private func publishPendingActionHighlight(for element: AccessibleElement) {
        let elementCenter = CGPoint(
            x: element.appKitFrame.midX,
            y: element.appKitFrame.midY
        )
        let targetScreenFrame = Self.findScreenFrameContainingOrNearestToPoint(
            point: elementCenter,
            allScreenFramesInAppKitCoordinates: NSScreen.screens.map { $0.frame }
        )

        // FIX 12: set isPendingActionHighlight: true so clearPendingActionHighlight()
        // can remove this entry by stable identity rather than by kind, preventing
        // it from accidentally deleting Claude-authored HIGHLIGHT annotations that
        // coexist in resolvedScreenAnnotations during a pending-action turn.
        let highlightAnnotation = ResolvedScreenAnnotation(
            kind: .highlight,
            rectInAppKitGlobalCoordinates: element.appKitFrame,
            displayFrameOfTargetScreen: targetScreenFrame,
            label: element.title,
            isPendingActionHighlight: true
        )

        // Append the highlight to the current resolved annotations. This mirrors
        // the approach taken for walkthrough step annotations — we compose rather
        // than replace, so a walkthrough step annotation and a pending-action
        // highlight can coexist on screen simultaneously.
        resolvedScreenAnnotations.append(highlightAnnotation)
    }

    /// Removes the pending-action highlight from the resolved annotations.
    ///
    /// FIX 12: identifies the pending-action highlight by isPendingActionHighlight
    /// rather than kind == .highlight. This prevents accidentally removing a
    /// Claude-authored HIGHLIGHT annotation that coexists in the array during
    /// a pending-action turn — the two are now distinguishable by stable identity.
    private func clearPendingActionHighlight() {
        resolvedScreenAnnotations.removeAll { $0.isPendingActionHighlight }
    }

    // MARK: - Spoken feedback for execution results

    /// Returns a short spoken string describing the result of an action execution.
    ///
    /// These strings are conversational and short — they will be spoken by TTS.
    private func spokenFeedbackForExecutionResult(
        result: ActionExecutionResult,
        actionDescription: String
    ) -> String {
        switch result {
        case .performed:
            // Post-action verification confirmed success — speak nothing extra,
            // the action is visually evident. Silence is the best UX here.
            return ""
        case .performedUnverified:
            // Performed but couldn't verify — brief positive note.
            return "done"
        case .failed(let reason):
            return "that didn't work — \(reason)"
        case .refused(let reason):
            return "I can't do that — \(reason)"
        case .staleTarget:
            return "the screen changed before I could act — try asking me again"
        case .aborted:
            // Abort is always user-initiated (kill switch) — the kill switch handler
            // speaks its own feedback (or is silent). We don't speak here.
            return ""
        }
    }

    // MARK: - AX element formatting

    /// Formats an `AccessibleElement`'s role and title as a short human-readable
    /// string for display in the confirmation panel.
    ///
    /// Examples:
    ///   AXButton "Submit"
    ///   AXTextField "Email"
    ///   AXLink "Learn more"
    ///   AXButton (no title)
    private func formatAXElementRoleAndTitle(element: AccessibleElement) -> String {
        let roleString = element.role.isEmpty ? "AXElement" : element.role
        // element.title is a non-optional String (see AccessibilityElementInventoryService).
        // We still guard for empty so the panel reads clearly when no label is present.
        let title = element.title
        if !title.isEmpty {
            // Truncate very long titles to keep the confirmation panel compact.
            let truncatedTitle = title.count > 50 ? String(title.prefix(47)) + "…" : title
            return "\(roleString) \"\(truncatedTitle)\""
        } else {
            return "\(roleString) (no title)"
        }
    }
}

// MARK: - Extended storage for resolved elements

// We need a second parallel array for the resolved AccessibleElement objects.
// This is added to PendingActionStateStorage here so the storage class is the
// single home for all pending-action mutable state.
private extension PendingActionStateStorage {
    var resolvedElementQueue: [AccessibleElement]? {
        get { _resolvedElementQueue }
        set { _resolvedElementQueue = newValue }
    }
}

// `_resolvedElementQueue` is declared directly on the PendingActionStateStorage
// class body (see the class definition above in this file). The private extension
// exposes it through the computed `resolvedElementQueue` wrapper so call sites use
// a clean property name rather than the underscore-prefixed backing ivar.
// Both the class and the wrapper extension are in this file, so Swift's private
// access rules allow the extension to read and write the stored property.
