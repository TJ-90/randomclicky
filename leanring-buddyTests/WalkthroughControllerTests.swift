//
//  WalkthroughControllerTests.swift
//  leanring-buddyTests
//
//  Tests for WalkthroughController.transition(from:on:) — the pure static
//  function that encodes the walkthrough state diagram exactly.
//
//  All tests call the static transition function directly with explicit
//  WalkthroughStateSnapshot inputs and assert on the returned snapshot
//  and effect. No MainActor isolation needed here — the function is
//  nonisolated and synchronous, matching the pure-decision-function
//  testing pattern used in WindowPositionManager tests.
//
//  STATE DIAGRAM UNDER TEST (from Phase C mermaid)
//  ────────────────────────────────────────────────
//  inactive          + walkthroughDeclared      → presentingStep
//  presentingStep    + stepPresented            → awaitingUserAction
//  awaitingUserAction + userSignaledStepDone    → verifying
//  awaitingUserAction + userAskedForHelp        → awaitingUserAction (no effect)
//  verifying         + stepVerifiedDone (not last) → presentingStep, index+1, retry reset
//  verifying         + stepVerifiedDone (last)  → inactive, announceCompletion
//  verifying         + stepNeedsRetry           → awaitingUserAction, retry+1
//  verifying         + stepNeedsRetry @ cap     → awaitingUserAction, offerSkipOrCancelAfterRetryCap
//  verifying         + turnInterrupted          → awaitingUserAction, retry preserved
//  any               + userCancelled            → inactive, announceCancellation
//  invalid combos                               → unchanged, effect none
//

import Testing
@testable import leanring_buddy

struct WalkthroughControllerTests {

    // MARK: - Helpers

    /// Builds a snapshot in the inactive phase with no steps declared yet.
    /// Used as the starting point for happy-path tests.
    private func makeInactiveSnapshot() -> WalkthroughStateSnapshot {
        WalkthroughStateSnapshot(
            phase: .inactive,
            declaredSteps: [],
            currentStepIndex: 0,
            retryCountForCurrentStep: 0,
            totalStepCount: 0
        )
    }

    /// Builds a set of three walkthrough steps for multi-step happy-path tests.
    private func makeThreeSteps() -> [WalkthroughStep] {
        [
            WalkthroughStep(stepNumber: 1, instruction: "Open System Settings"),
            WalkthroughStep(stepNumber: 2, instruction: "Click General"),
            WalkthroughStep(stepNumber: 3, instruction: "Enable Dark Mode"),
        ]
    }

    // MARK: - Declaration: inactive + walkthroughDeclared → presentingStep

    @Test func walkthroughDeclaredFromInactiveTransitionsToPresentingStep() {
        let initialSnapshot = makeInactiveSnapshot()

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: initialSnapshot,
            on: .walkthroughDeclared(totalStepCount: 3)
        )

        #expect(resultSnapshot.phase == .presentingStep)
        #expect(resultSnapshot.totalStepCount == 3)
        #expect(resultSnapshot.currentStepIndex == 0)
        #expect(resultEffect == .none)
    }

    // MARK: - Step presented: presentingStep + stepPresented → awaitingUserAction

    @Test func stepPresentedFromPresentingStepTransitionsToAwaitingUserAction() {
        let step = WalkthroughStep(stepNumber: 1, instruction: "Open System Settings")
        let presentingSnapshot = WalkthroughStateSnapshot(
            phase: .presentingStep,
            declaredSteps: [],
            currentStepIndex: 0,
            retryCountForCurrentStep: 0,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: presentingSnapshot,
            on: .stepPresented(step: step)
        )

        #expect(resultSnapshot.phase == .awaitingUserAction)
        // The step is recorded in the declared steps list
        #expect(resultSnapshot.declaredSteps.count == 1)
        #expect(resultSnapshot.declaredSteps[0].instruction == "Open System Settings")
        #expect(resultEffect == .none)
    }

    // MARK: - User signals done: awaitingUserAction + userSignaledStepDone → verifying

    @Test func userSignaledStepDoneTransitionsToVerifying() {
        let awaitingSnapshot = WalkthroughStateSnapshot(
            phase: .awaitingUserAction,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 0,
            retryCountForCurrentStep: 0,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: awaitingSnapshot,
            on: .userSignaledStepDone
        )

        #expect(resultSnapshot.phase == .verifying)
        #expect(resultSnapshot.currentStepIndex == 0)
        #expect(resultEffect == .none)
    }

    // MARK: - Help request: awaitingUserAction + userAskedForHelp → stays awaitingUserAction, no effect

    @Test func userAskedForHelpDoesNotChangePhaseOrRetryCount() {
        let awaitingSnapshot = WalkthroughStateSnapshot(
            phase: .awaitingUserAction,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 1,
            retryCountForCurrentStep: 1,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: awaitingSnapshot,
            on: .userAskedForHelp
        )

        #expect(resultSnapshot.phase == .awaitingUserAction)
        #expect(resultSnapshot.currentStepIndex == 1)
        // Retry count must not change — asking for help is not a retry attempt
        #expect(resultSnapshot.retryCountForCurrentStep == 1)
        #expect(resultEffect == .none)
    }

    // MARK: - Happy path: 3-step walkthrough, all steps verified done in sequence

    @Test func threeStepHappyPathAdvancesIndicesAndCompletesOnLastStep() {
        let steps = makeThreeSteps()

        // Step 1: declare
        var snapshot = makeInactiveSnapshot()
        (snapshot, _) = WalkthroughController.transition(from: snapshot, on: .walkthroughDeclared(totalStepCount: 3))
        #expect(snapshot.phase == .presentingStep)

        // Step 1: present
        (snapshot, _) = WalkthroughController.transition(from: snapshot, on: .stepPresented(step: steps[0]))
        #expect(snapshot.phase == .awaitingUserAction)
        #expect(snapshot.currentStepIndex == 0)

        // Step 1: user signals done → verifying
        (snapshot, _) = WalkthroughController.transition(from: snapshot, on: .userSignaledStepDone)
        #expect(snapshot.phase == .verifying)

        // Step 1: verify done (not last) → presentingStep, index advances to 1, retry resets
        var effect: WalkthroughTransitionEffect
        (snapshot, effect) = WalkthroughController.transition(from: snapshot, on: .stepVerifiedDone)
        #expect(snapshot.phase == .presentingStep)
        #expect(snapshot.currentStepIndex == 1)
        #expect(snapshot.retryCountForCurrentStep == 0)
        #expect(effect == .none)

        // Step 2: present
        (snapshot, _) = WalkthroughController.transition(from: snapshot, on: .stepPresented(step: steps[1]))
        #expect(snapshot.phase == .awaitingUserAction)
        #expect(snapshot.currentStepIndex == 1)

        // Step 2: user signals done → verifying
        (snapshot, _) = WalkthroughController.transition(from: snapshot, on: .userSignaledStepDone)
        #expect(snapshot.phase == .verifying)

        // Step 2: verify done (not last) → presentingStep, index advances to 2, retry resets
        (snapshot, effect) = WalkthroughController.transition(from: snapshot, on: .stepVerifiedDone)
        #expect(snapshot.phase == .presentingStep)
        #expect(snapshot.currentStepIndex == 2)
        #expect(snapshot.retryCountForCurrentStep == 0)
        #expect(effect == .none)

        // Step 3: present
        (snapshot, _) = WalkthroughController.transition(from: snapshot, on: .stepPresented(step: steps[2]))
        #expect(snapshot.phase == .awaitingUserAction)
        #expect(snapshot.currentStepIndex == 2)

        // Step 3: user signals done → verifying
        (snapshot, _) = WalkthroughController.transition(from: snapshot, on: .userSignaledStepDone)
        #expect(snapshot.phase == .verifying)

        // Step 3: verify done (last step) → inactive, announceCompletion
        (snapshot, effect) = WalkthroughController.transition(from: snapshot, on: .stepVerifiedDone)
        #expect(snapshot.phase == .inactive)
        #expect(effect == .announceCompletion)
    }

    // MARK: - Off-by-one: final step verify done completes (no phantom extra step)

    @Test func verifyDoneOnFinalStepCompletesImmediatelyWithoutAdvancingIndex() {
        // A single-step walkthrough — index 0 is both first and last.
        let singleStepSnapshot = WalkthroughStateSnapshot(
            phase: .verifying,
            declaredSteps: [WalkthroughStep(stepNumber: 1, instruction: "Do the thing")],
            currentStepIndex: 0,
            retryCountForCurrentStep: 0,
            totalStepCount: 1
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: singleStepSnapshot,
            on: .stepVerifiedDone
        )

        #expect(resultSnapshot.phase == .inactive)
        #expect(resultEffect == .announceCompletion)
        // Index must not advance past the last step
        #expect(resultSnapshot.currentStepIndex == 0)
    }

    // MARK: - Retry: stepNeedsRetry increments retry count, stays awaitingUserAction

    @Test func firstStepNeedsRetryIncrementsRetryCountAndStaysAwaitingUserAction() {
        let verifyingSnapshot = WalkthroughStateSnapshot(
            phase: .verifying,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 1,
            retryCountForCurrentStep: 0,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: verifyingSnapshot,
            on: .stepNeedsRetry(hint: "You clicked the wrong pane, try again")
        )

        #expect(resultSnapshot.phase == .awaitingUserAction)
        #expect(resultSnapshot.currentStepIndex == 1)
        #expect(resultSnapshot.retryCountForCurrentStep == 1)
        // First retry (count now 1, cap is 2) — no cap effect yet
        #expect(resultEffect == .speakRetryHint("You clicked the wrong pane, try again"))
    }

    @Test func secondStepNeedsRetryIncrementsRetryCountButDoesNotYetTriggerCap() {
        // After first retry retryCount is 1 — second retry brings it to 2 which IS the cap.
        // This test validates the boundary exactly: cap is 2, so reaching 2 triggers the offer.
        let verifyingSnapshot = WalkthroughStateSnapshot(
            phase: .verifying,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 0,
            retryCountForCurrentStep: 1,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: verifyingSnapshot,
            on: .stepNeedsRetry(hint: "Still not quite right")
        )

        #expect(resultSnapshot.phase == .awaitingUserAction)
        #expect(resultSnapshot.retryCountForCurrentStep == 2)
        // The cap (2) has been reached — controller must offer skip/cancel
        #expect(resultEffect == .offerSkipOrCancelAfterRetryCap)
    }

    @Test func retryCountResetsToZeroWhenStepAdvances() {
        // After accumulating retries on step 0, step 0 is verified done.
        // The retry count for the next step must start at 0.
        let verifyingWithRetriesSnapshot = WalkthroughStateSnapshot(
            phase: .verifying,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 0,
            retryCountForCurrentStep: 1,
            totalStepCount: 3
        )

        let (resultSnapshot, _) = WalkthroughController.transition(
            from: verifyingWithRetriesSnapshot,
            on: .stepVerifiedDone
        )

        #expect(resultSnapshot.phase == .presentingStep)
        #expect(resultSnapshot.currentStepIndex == 1)
        // Retry counter is reset — starts fresh for the new step
        #expect(resultSnapshot.retryCountForCurrentStep == 0)
    }

    // MARK: - turnInterrupted: verifying → awaitingUserAction, retry count preserved

    @Test func turnInterruptedDuringVerifyingReturnsToAwaitingUserActionWithRetryCountPreserved() {
        // The user pressed PTT while a verification turn was in flight.
        // The controller must return to awaitingUserAction — it must never
        // get stranded in verifying, and the retry count is preserved (the
        // interrupted turn did not consume a retry attempt).
        let verifyingSnapshot = WalkthroughStateSnapshot(
            phase: .verifying,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 1,
            retryCountForCurrentStep: 1,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: verifyingSnapshot,
            on: .turnInterrupted
        )

        #expect(resultSnapshot.phase == .awaitingUserAction)
        // Retry count is preserved — the interrupted turn is not counted as a retry
        #expect(resultSnapshot.retryCountForCurrentStep == 1)
        #expect(resultSnapshot.currentStepIndex == 1)
        #expect(resultEffect == .none)
    }

    @Test func turnInterruptedDuringVerifyingWithZeroRetriesPreservesZeroCount() {
        let verifyingSnapshot = WalkthroughStateSnapshot(
            phase: .verifying,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 0,
            retryCountForCurrentStep: 0,
            totalStepCount: 3
        )

        let (resultSnapshot, _) = WalkthroughController.transition(
            from: verifyingSnapshot,
            on: .turnInterrupted
        )

        #expect(resultSnapshot.phase == .awaitingUserAction)
        #expect(resultSnapshot.retryCountForCurrentStep == 0)
    }

    // MARK: - Cancel: from any phase → inactive, announceCancellation exactly once

    @Test func cancelFromPresentingStepTransitionsToInactiveWithCancellationEffect() {
        let presentingSnapshot = WalkthroughStateSnapshot(
            phase: .presentingStep,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 0,
            retryCountForCurrentStep: 0,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: presentingSnapshot,
            on: .userCancelled
        )

        #expect(resultSnapshot.phase == .inactive)
        #expect(resultEffect == .announceCancellation)
    }

    @Test func cancelFromAwaitingUserActionTransitionsToInactiveWithCancellationEffect() {
        let awaitingSnapshot = WalkthroughStateSnapshot(
            phase: .awaitingUserAction,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 1,
            retryCountForCurrentStep: 0,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: awaitingSnapshot,
            on: .userCancelled
        )

        #expect(resultSnapshot.phase == .inactive)
        #expect(resultEffect == .announceCancellation)
    }

    @Test func cancelFromVerifyingTransitionsToInactiveWithCancellationEffect() {
        let verifyingSnapshot = WalkthroughStateSnapshot(
            phase: .verifying,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 2,
            retryCountForCurrentStep: 1,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: verifyingSnapshot,
            on: .userCancelled
        )

        #expect(resultSnapshot.phase == .inactive)
        #expect(resultEffect == .announceCancellation)
    }

    @Test func cancelFromInactiveIsDefensivelyIgnored() {
        // Cancelling when already inactive is a no-op — the snapshot is unchanged
        // and no spurious cancellation announcement fires.
        let inactiveSnapshot = makeInactiveSnapshot()

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: inactiveSnapshot,
            on: .userCancelled
        )

        #expect(resultSnapshot.phase == .inactive)
        // Already inactive — no announcement needed
        #expect(resultEffect == .none)
    }

    // MARK: - Defensive: invalid event/phase combinations leave snapshot unchanged

    @Test func stepVerifiedDoneWhileInactiveIsDefensivelyIgnored() {
        // stepVerifiedDone is only valid from verifying.
        // Receiving it while inactive must be a no-op — no crash, no state change.
        let inactiveSnapshot = makeInactiveSnapshot()

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: inactiveSnapshot,
            on: .stepVerifiedDone
        )

        #expect(resultSnapshot.phase == .inactive)
        #expect(resultEffect == .none)
    }

    @Test func stepNeedsRetryWhileInactiveIsDefensivelyIgnored() {
        let inactiveSnapshot = makeInactiveSnapshot()

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: inactiveSnapshot,
            on: .stepNeedsRetry(hint: "some hint")
        )

        #expect(resultSnapshot.phase == .inactive)
        #expect(resultEffect == .none)
    }

    @Test func turnInterruptedWhileInactiveIsDefensivelyIgnored() {
        let inactiveSnapshot = makeInactiveSnapshot()

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: inactiveSnapshot,
            on: .turnInterrupted
        )

        #expect(resultSnapshot.phase == .inactive)
        #expect(resultEffect == .none)
    }

    @Test func walkthroughDeclaredWhileAlreadyActiveIsDefensivelyIgnored() {
        // Re-declaring a walkthrough while already presenting steps should be
        // ignored defensively — the state machine does not restart mid-flow.
        let presentingSnapshot = WalkthroughStateSnapshot(
            phase: .presentingStep,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 1,
            retryCountForCurrentStep: 0,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: presentingSnapshot,
            on: .walkthroughDeclared(totalStepCount: 5)
        )

        // Phase and index must be unchanged
        #expect(resultSnapshot.phase == .presentingStep)
        #expect(resultSnapshot.currentStepIndex == 1)
        #expect(resultSnapshot.totalStepCount == 3)
        #expect(resultEffect == .none)
    }

    // MARK: - retryCapReached event: same phase effect as stepNeedsRetry at cap

    @Test func retryCapReachedEventFromAwaitingUserActionProducesOfferEffect() {
        // retryCapReached is an explicit event the manager can fire (e.g. after
        // counting externally). The controller treats it as an offer-skip-or-cancel.
        let awaitingSnapshot = WalkthroughStateSnapshot(
            phase: .awaitingUserAction,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 0,
            retryCountForCurrentStep: 2,
            totalStepCount: 3
        )

        let (resultSnapshot, resultEffect) = WalkthroughController.transition(
            from: awaitingSnapshot,
            on: .retryCapReached
        )

        #expect(resultSnapshot.phase == .awaitingUserAction)
        #expect(resultEffect == .offerSkipOrCancelAfterRetryCap)
    }

    // MARK: - Snapshot immutability: transition never mutates; each call is independent

    @Test func transitionFunctionProducesNewSnapshotWithoutMutatingInput() {
        let originalSnapshot = WalkthroughStateSnapshot(
            phase: .verifying,
            declaredSteps: makeThreeSteps(),
            currentStepIndex: 0,
            retryCountForCurrentStep: 0,
            totalStepCount: 3
        )

        let (resultSnapshot, _) = WalkthroughController.transition(
            from: originalSnapshot,
            on: .stepVerifiedDone
        )

        // Input snapshot must be unchanged
        #expect(originalSnapshot.phase == .verifying)
        #expect(originalSnapshot.currentStepIndex == 0)
        // Output is different
        #expect(resultSnapshot.phase == .presentingStep)
        #expect(resultSnapshot.currentStepIndex == 1)
    }
}
