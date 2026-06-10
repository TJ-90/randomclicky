//
//  WalkthroughController.swift
//  leanring-buddy
//
//  Owns the walkthrough step state machine for Phase C (guided walkthroughs).
//  Lives alongside CompanionVoiceState rather than inside it — the 4-case
//  CompanionVoiceState enum is exhaustively matched in OverlayWindow and
//  CompanionPanelView, so adding cases would ripple everywhere. Instead,
//  WalkthroughPhase composes with CompanionVoiceState as a parallel published
//  property.
//
//  ARCHITECTURE
//  ─────────────────────────────────────────────────────────────────────────
//  The heavy lifting is in the pure static `transition(from:on:)` function.
//  It takes explicit value types in, returns value types out, and has no
//  side effects — making it trivially testable without mocking. The
//  @MainActor controller class wraps `transition` with apply(event:), stores
//  the snapshot, and publishes the phase so SwiftUI views observe it.
//
//  The manager (U8) drives the controller by calling apply(event:) as turns
//  complete. The controller owns no timers, no Claude calls, and no TTS.
//
//  RETRY CAP
//  ─────────────────────────────────────────────────────────────────────────
//  A step may be retried up to 2 times (retryCountForCurrentStep reaching 2
//  triggers the cap). On the cap the phase stays awaitingUserAction so the
//  step is still "live" — the manager uses the offerSkipOrCancelAfterRetryCap
//  effect to surface UI that lets the user skip the step or cancel the whole
//  walkthrough. The controller itself does not advance or cancel; it waits
//  for an explicit userCancelled event from the manager.
//

import SwiftUI

// MARK: - WalkthroughPhase

/// The four phases of a guided walkthrough. Published by WalkthroughController
/// and observed by overlay and panel views.
///
/// Composes with CompanionVoiceState as a parallel dimension of state — it
/// is never embedded inside CompanionVoiceState cases.
enum WalkthroughPhase: Equatable {
    /// No walkthrough is in progress. This is both the initial state and the
    /// terminal state after completion or cancellation.
    case inactive

    /// Claude is speaking the current step's instruction and pointing at the
    /// relevant UI element. The manager transitions out of this phase when TTS
    /// finishes (U8 drives this via apply(.stepPresented)).
    case presentingStep

    /// The step instruction has been delivered. Clicky is waiting for the user
    /// to act and then signal completion (via push-to-talk or the panel button).
    /// This phase can persist for minutes — the overlay must not fade during it.
    case awaitingUserAction

    /// The user signalled they completed the step. A fresh Claude turn is running
    /// (new screenshot + AX inventory) to determine whether the step was done
    /// correctly. If the verification turn is cancelled (PTT press), the controller
    /// emits turnInterrupted and returns to awaitingUserAction so it can never
    /// get stranded here.
    case verifying
}

// MARK: - WalkthroughStep

/// A single step in a declared walkthrough. Immutable value type.
struct WalkthroughStep: Equatable {
    /// 1-based step number as declared in the [STEP:n:instruction] tag.
    let stepNumber: Int
    /// The natural-language instruction Claude declared for this step.
    let instruction: String
}

// MARK: - WalkthroughTransitionEvent

/// Events that drive the walkthrough state machine. Fired by CompanionManager
/// (U8) as the turn pipeline and user interactions produce outcomes.
enum WalkthroughTransitionEvent: Equatable {
    /// Claude's response contained a [WALKTHROUGH:totalStepCount] tag.
    /// Carries the total number of declared steps so the controller knows
    /// when the last step is being verified.
    case walkthroughDeclared(totalStepCount: Int)

    /// The manager finished speaking and pointing for a step. The step value
    /// carries the parsed instruction so it can be stored in the snapshot
    /// for display (step chip, panel row) and passed to the verify turn (U8).
    case stepPresented(step: WalkthroughStep)

    /// The user pressed the "I did it" panel button or spoke a completion
    /// utterance that the manager routed into the walkthrough context.
    case userSignaledStepDone

    /// The user asked a help question during awaitingUserAction. The manager
    /// handles the Claude turn; the controller stays in awaitingUserAction —
    /// help is orthogonal to step progress.
    case userAskedForHelp

    /// The verification Claude turn returned [VERIFY:done].
    /// If this is the last step the controller completes the walkthrough;
    /// otherwise it advances to the next step.
    case stepVerifiedDone

    /// The verification Claude turn returned [VERIFY:retry:hint].
    /// Carries the corrective hint string that the manager should speak.
    case stepNeedsRetry(hint: String)

    /// The user pressed push-to-talk while a verification turn was in flight,
    /// cancelling the currentResponseTask. The controller returns to
    /// awaitingUserAction with the retry count preserved — the interrupted
    /// turn is not counted as a retry attempt, and the controller is never
    /// left stranded in verifying.
    case turnInterrupted

    /// Explicit cancellation from the panel cancel button or a spoken intent
    /// that Claude mapped to cancel. Always leads to inactive.
    case userCancelled

    /// The manager detected that the retry cap has been reached (e.g. after
    /// presenting the offer UI and the user asked to retry again anyway).
    /// The controller surfaces the offerSkipOrCancelAfterRetryCap effect
    /// again so the UI can re-present the choice.
    case retryCapReached
}

// MARK: - WalkthroughStateSnapshot

/// Complete, immutable description of the walkthrough state at a point in time.
/// Passed into transition(from:on:) and returned as the result — never mutated
/// in place. The controller holds the authoritative copy; the pure function
/// never does.
struct WalkthroughStateSnapshot: Equatable {
    /// The current phase of the state machine.
    let phase: WalkthroughPhase

    /// Steps that have been presented so far (accumulated as stepPresented
    /// events arrive). Used by the step chip ("Step 2 of 4") and passed in
    /// the verification turn system prompt so truncation cannot lose the list.
    let declaredSteps: [WalkthroughStep]

    /// Zero-based index of the step currently being presented or verified.
    /// Advances by one on each stepVerifiedDone (non-last-step) transition.
    let currentStepIndex: Int

    /// How many times the current step has been retried. Reset to 0 when
    /// the step advances. The retry cap is WalkthroughController.maximumRetriesPerStep.
    let retryCountForCurrentStep: Int

    /// Total number of steps as declared in the [WALKTHROUGH:n] tag.
    /// Used by transition to detect the final step.
    let totalStepCount: Int
}

// MARK: - WalkthroughTransitionEffect

/// What the caller (CompanionManager, U8) should do as a result of a transition.
/// Kept minimal and explicit — only effects that the controller can determine
/// from state alone are here. Side effects that require knowledge of the voice
/// pipeline (TTS, Claude API) are U8's responsibility.
enum WalkthroughTransitionEffect: Equatable {
    /// Nothing extra to do. The phase change (if any) is sufficient.
    case none

    /// Speak the retry hint string to the user (via ElevenLabs TTS).
    /// Emitted when a stepNeedsRetry event arrives and the cap has not been reached.
    case speakRetryHint(String)

    /// Announce that the walkthrough is complete (final step verified).
    /// The manager should speak a congratulations line and clear walkthrough UI.
    case announceCompletion

    /// Announce that the walkthrough was cancelled by the user.
    /// The manager should speak a cancellation acknowledgement and clear walkthrough UI.
    case announceCancellation

    /// The retry cap for the current step has been reached. The manager should
    /// offer the user a choice to skip this step or cancel the walkthrough.
    /// The phase stays awaitingUserAction — the controller waits for explicit
    /// userCancelled or the manager's skip logic before advancing.
    case offerSkipOrCancelAfterRetryCap
}

// MARK: - WalkthroughController

/// Owns the walkthrough state snapshot and publishes WalkthroughPhase for
/// observation by overlay and panel views.
///
/// All mutations go through apply(event:), which delegates to the pure static
/// transition(from:on:) function. No timers, no Claude calls, no TTS — the
/// manager (U8) drives the controller.
///
/// @MainActor because @Published property updates must happen on the main thread.
@MainActor
final class WalkthroughController: ObservableObject {

    // MARK: - Retry cap constant

    /// Maximum number of retries allowed for a single step before the controller
    /// surfaces the skip/cancel offer. retryCountForCurrentStep reaching this
    /// value (not exceeding it) triggers offerSkipOrCancelAfterRetryCap.
    static let maximumRetriesPerStep = 2

    // MARK: - Published state

    /// The current phase, published for SwiftUI observation. Callers that need
    /// the full snapshot (e.g. the manager reading step instructions) should
    /// access currentSnapshot directly.
    @Published private(set) var phase: WalkthroughPhase = .inactive

    // MARK: - Internal snapshot

    /// The authoritative snapshot. Private(set) so external callers can read
    /// it (e.g. to build the verification turn system prompt in U8) but cannot
    /// mutate it directly — all mutations go through apply(event:).
    private(set) var currentSnapshot: WalkthroughStateSnapshot = WalkthroughStateSnapshot(
        phase: .inactive,
        declaredSteps: [],
        currentStepIndex: 0,
        retryCountForCurrentStep: 0,
        totalStepCount: 0
    )

    // MARK: - Event application

    /// Applies an event to the current snapshot via the pure transition function,
    /// stores the resulting snapshot, and publishes the new phase.
    ///
    /// Returns the effect so the caller can act on it immediately (e.g. speak
    /// a retry hint) without having to observe a separate published property.
    @discardableResult
    func apply(event: WalkthroughTransitionEvent) -> WalkthroughTransitionEffect {
        let (newSnapshot, effect) = WalkthroughController.transition(
            from: currentSnapshot,
            on: event
        )
        currentSnapshot = newSnapshot
        // Only trigger a @Published notification when the phase actually changed —
        // no-op transitions (defensive ignores) should not wake SwiftUI views.
        if phase != newSnapshot.phase {
            phase = newSnapshot.phase
        }
        return effect
    }

    // MARK: - Pure static transition function

    /// Encodes the full Phase C state diagram as a pure function.
    ///
    /// nonisolated so it can be called from tests without MainActor context.
    /// Takes explicit value-type inputs and returns value-type outputs — no
    /// stored state, no side effects, fully deterministic.
    ///
    /// Invalid event/phase combinations return the snapshot unchanged with
    /// effect .none. This is a documented defensive policy: callers must not
    /// depend on invalid combos producing specific behaviour, but they must also
    /// not crash or corrupt state.
    nonisolated static func transition(
        from snapshot: WalkthroughStateSnapshot,
        on event: WalkthroughTransitionEvent
    ) -> (snapshot: WalkthroughStateSnapshot, effect: WalkthroughTransitionEffect) {

        // ── userCancelled is valid from any non-inactive phase ──────────────
        // Handled before the phase switch so every phase gets it for free.
        // Cancelling from inactive is a no-op (nothing to announce).
        if case .userCancelled = event {
            guard snapshot.phase != .inactive else {
                return (snapshot, .none)
            }
            return (
                snapshot.withPhase(.inactive),
                .announceCancellation
            )
        }

        switch snapshot.phase {

        // ── inactive ────────────────────────────────────────────────────────
        case .inactive:
            switch event {
            case .walkthroughDeclared(let totalStepCount):
                // A walkthrough tag was parsed. Record the declared total and
                // move to presentingStep so the manager can present step 1.
                let newSnapshot = WalkthroughStateSnapshot(
                    phase: .presentingStep,
                    declaredSteps: snapshot.declaredSteps,
                    currentStepIndex: 0,
                    retryCountForCurrentStep: 0,
                    totalStepCount: totalStepCount
                )
                return (newSnapshot, .none)

            default:
                // Any other event while inactive is invalid — ignore defensively.
                return (snapshot, .none)
            }

        // ── presentingStep ──────────────────────────────────────────────────
        case .presentingStep:
            switch event {
            case .stepPresented(let step):
                // The manager finished TTS + pointing for this step. Accumulate
                // the step in declaredSteps and move to awaitingUserAction.
                var updatedDeclaredSteps = snapshot.declaredSteps
                updatedDeclaredSteps.append(step)
                let newSnapshot = WalkthroughStateSnapshot(
                    phase: .awaitingUserAction,
                    declaredSteps: updatedDeclaredSteps,
                    currentStepIndex: snapshot.currentStepIndex,
                    retryCountForCurrentStep: snapshot.retryCountForCurrentStep,
                    totalStepCount: snapshot.totalStepCount
                )
                return (newSnapshot, .none)

            case .userCancelled:
                // Already handled above — unreachable but exhaustiveness requires it.
                return (snapshot.withPhase(.inactive), .announceCancellation)

            default:
                // walkthroughDeclared while already presenting: ignore (no re-entrant
                // walkthrough declaration mid-flow). Other events: ignore defensively.
                return (snapshot, .none)
            }

        // ── awaitingUserAction ──────────────────────────────────────────────
        case .awaitingUserAction:
            switch event {
            case .userSignaledStepDone:
                // User pressed "I did it" or spoke a completion utterance.
                // Move to verifying so the manager can kick off the verification turn.
                return (snapshot.withPhase(.verifying), .none)

            case .userAskedForHelp:
                // A help question during awaitingUserAction is handled by the manager
                // as a normal Claude turn with walkthrough context. The step does not
                // change and the retry count does not increment.
                return (snapshot, .none)

            case .retryCapReached:
                // The manager detected the cap independently (e.g. user keeps asking
                // for help after retries). Surface the offer again without changing phase.
                return (snapshot, .offerSkipOrCancelAfterRetryCap)

            case .userCancelled:
                // Already handled above — unreachable but exhaustiveness requires it.
                return (snapshot.withPhase(.inactive), .announceCancellation)

            default:
                return (snapshot, .none)
            }

        // ── verifying ───────────────────────────────────────────────────────
        case .verifying:
            switch event {
            case .stepVerifiedDone:
                // The verification turn confirmed the step was completed correctly.
                // Determine whether this was the last step.
                let isLastStep = snapshot.currentStepIndex >= snapshot.totalStepCount - 1

                if isLastStep {
                    // Walkthrough complete — reset to inactive.
                    return (snapshot.withPhase(.inactive), .announceCompletion)
                } else {
                    // Advance to the next step. Reset retry count for the new step.
                    let advancedSnapshot = WalkthroughStateSnapshot(
                        phase: .presentingStep,
                        declaredSteps: snapshot.declaredSteps,
                        currentStepIndex: snapshot.currentStepIndex + 1,
                        retryCountForCurrentStep: 0,
                        totalStepCount: snapshot.totalStepCount
                    )
                    return (advancedSnapshot, .none)
                }

            case .stepNeedsRetry(let hint):
                // Verification found the step was not completed correctly.
                // Increment the retry count and return to awaitingUserAction so
                // the user can try again.
                let newRetryCount = snapshot.retryCountForCurrentStep + 1
                let newSnapshot = WalkthroughStateSnapshot(
                    phase: .awaitingUserAction,
                    declaredSteps: snapshot.declaredSteps,
                    currentStepIndex: snapshot.currentStepIndex,
                    retryCountForCurrentStep: newRetryCount,
                    totalStepCount: snapshot.totalStepCount
                )

                // Once the retry count reaches the cap, the manager must offer
                // skip/cancel instead of silently repeating the same instruction.
                // The phase stays awaitingUserAction — advancing or cancelling
                // requires explicit events.
                if newRetryCount >= WalkthroughController.maximumRetriesPerStep {
                    return (newSnapshot, .offerSkipOrCancelAfterRetryCap)
                } else {
                    return (newSnapshot, .speakRetryHint(hint))
                }

            case .turnInterrupted:
                // The user pressed push-to-talk while the verification turn was
                // in flight, cancelling currentResponseTask. The controller must
                // return to awaitingUserAction — it cannot stay in verifying with
                // no active turn (that would strand the walkthrough indefinitely).
                //
                // Crucially, the retry count is PRESERVED: the interrupted turn
                // did not produce a verdict, so it must not be counted against the
                // user's retry budget.
                return (snapshot.withPhase(.awaitingUserAction), .none)

            case .userCancelled:
                // Already handled above — unreachable but exhaustiveness requires it.
                return (snapshot.withPhase(.inactive), .announceCancellation)

            default:
                return (snapshot, .none)
            }
        }
    }
}

// MARK: - WalkthroughStateSnapshot convenience helpers

private extension WalkthroughStateSnapshot {
    /// Returns a copy of this snapshot with only the phase changed.
    /// Used in transition(from:on:) for transitions that don't change
    /// step index, retry count, or step list.
    func withPhase(_ newPhase: WalkthroughPhase) -> WalkthroughStateSnapshot {
        WalkthroughStateSnapshot(
            phase: newPhase,
            declaredSteps: declaredSteps,
            currentStepIndex: currentStepIndex,
            retryCountForCurrentStep: retryCountForCurrentStep,
            totalStepCount: totalStepCount
        )
    }
}
