//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Centralized PostHog analytics wrapper. All event names and properties
//  are defined here so instrumentation is consistent and easy to audit.
//

import Foundation
import PostHog

enum ClickyAnalytics {

    // MARK: - Setup

    static func configure() {
        let config = PostHogConfig(
            apiKey: "phc_xcQPygmhTMzzYh8wNW92CCwoXmnzqyChAixh8zgpqC3C",
            host: "https://us.i.posthog.com"
        )
        PostHogSDK.shared.setup(config)
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        PostHogSDK.shared.capture("app_opened", properties: [
            "app_version": version
        ])
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        PostHogSDK.shared.capture("onboarding_started")
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        PostHogSDK.shared.capture("onboarding_replayed")
    }

    /// The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {
        PostHogSDK.shared.capture("onboarding_video_completed")
    }

    /// The 40s onboarding demo interaction where Clicky points at something.
    static func trackOnboardingDemoTriggered() {
        PostHogSDK.shared.capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        PostHogSDK.shared.capture("all_permissions_granted")
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        PostHogSDK.shared.capture("permission_granted", properties: [
            "permission": permission
        ])
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        PostHogSDK.shared.capture("push_to_talk_started")
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        PostHogSDK.shared.capture("push_to_talk_released")
    }

    /// Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {
        PostHogSDK.shared.capture("user_message_sent", properties: [
            "transcript": transcript,
            "character_count": transcript.count
        ])
    }

    /// Claude responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
        PostHogSDK.shared.capture("ai_response_received", properties: [
            "response": response,
            "character_count": response.count
        ])
    }

    // MARK: - AX Inventory

    /// Describes how an element-pointing instruction was resolved, distinguishing
    /// accurate element-ID resolution from the pixel-coordinate fallback path.
    enum ElementPointingMethod: String {
        /// Claude referenced an element by inventory ID (E<n>) and it was found
        /// in the captured inventory — the cursor will land on the exact center.
        case elementIDResolved = "element_id_resolved"

        /// Claude referenced an element by inventory ID but the ID was not in
        /// the inventory (unknown ID, capped list, or hallucinated ID). The cursor
        /// does not fly anywhere for this turn.
        case elementIDLookupFailed = "element_id_lookup_failed"

        /// Claude used the legacy pixel-coordinate form [POINT:x,y:label:screenN].
        /// This is the fallback for AX-less apps (games, video) and any target
        /// not in the inventory.
        case pixelCoordinateFallback = "pixel_coordinate_fallback"
    }

    /// Claude's response included a [POINT:...] tag, so the buddy is (or is
    /// trying to) fly to a UI element. The `pointingMethod` distinguishes
    /// grounded element-ID resolution from the pixel fallback so we can measure
    /// how often AX grounding is actually providing value.
    static func trackElementPointed(
        elementLabel: String?,
        pointingMethod: ElementPointingMethod
    ) {
        PostHogSDK.shared.capture("element_pointed", properties: [
            "element_label": elementLabel ?? "unknown",
            "pointing_method": pointingMethod.rawValue
        ])
    }

    /// Fired after the AX element walk completes (or times out) for one interaction.
    /// Tracks walk quality metrics so we can tune the timeout and element cap.
    ///
    /// - Parameters:
    ///   - elementCount: The number of actionable elements kept in the inventory.
    ///     Zero when the walk timed out, returned an empty tree, or AX is unavailable.
    ///   - captureOutcome: Why the walk produced its result (captured / timedOut /
    ///     emptyTree / permissionUnavailable).
    ///   - frontmostAppName: The localized display name of the frontmost application
    ///     at walk time. Useful for spotting which apps time out or return stub trees.
    static func trackAXInventoryWalkCompleted(
        elementCount: Int,
        captureOutcome: AccessibilityInventoryCaptureOutcome,
        frontmostAppName: String
    ) {
        let outcomeString: String
        switch captureOutcome {
        case .captured:
            outcomeString = "captured"
        case .timedOut:
            outcomeString = "timed_out"
        case .emptyTree:
            outcomeString = "empty_tree"
        case .permissionUnavailable:
            outcomeString = "permission_unavailable"
        }

        PostHogSDK.shared.capture("ax_inventory_walk_completed", properties: [
            "element_count": elementCount,
            "capture_outcome": outcomeString,
            "frontmost_app_name": frontmostAppName
        ])
    }

    // MARK: - Guided Walkthroughs

    /// A new guided walkthrough was declared by Claude (WALKTHROUGH tag parsed).
    static func trackWalkthroughStarted(totalSteps: Int) {
        PostHogSDK.shared.capture("walkthrough_started", properties: [
            "total_steps": totalSteps
        ])
    }

    /// The controller advanced to the next step after a successful verification.
    static func trackWalkthroughStepAdvanced(stepNumber: Int) {
        PostHogSDK.shared.capture("walkthrough_step_advanced", properties: [
            "step_number": stepNumber
        ])
    }

    /// The verification turn returned VERIFY:retry — the user needs to redo a step.
    static func trackWalkthroughStepRetried(stepNumber: Int, retryCount: Int) {
        PostHogSDK.shared.capture("walkthrough_step_retried", properties: [
            "step_number": stepNumber,
            "retry_count": retryCount
        ])
    }

    /// The walkthrough reached its final step and was verified done.
    static func trackWalkthroughCompleted(totalSteps: Int) {
        PostHogSDK.shared.capture("walkthrough_completed", properties: [
            "total_steps": totalSteps
        ])
    }

    /// The user cancelled the walkthrough before it completed.
    static func trackWalkthroughCancelled(atStep: Int) {
        PostHogSDK.shared.capture("walkthrough_cancelled", properties: [
            "at_step": atStep
        ])
    }

    // MARK: - Act Mode (U12)

    /// The user enabled act mode from the panel toggle.
    static func trackActModeEnabled() {
        PostHogSDK.shared.capture("act_mode_enabled")
    }

    /// The user disabled act mode from the panel toggle.
    static func trackActModeDisabled() {
        PostHogSDK.shared.capture("act_mode_disabled")
    }

    // MARK: - Act Mode Action Lifecycle (U11/U12)

    /// Claude proposed an action (CLICK or TYPE tag was parsed and enqueued).
    ///
    /// PRIVACY AUDIT: `targetAppBundleID` (e.g. "com.apple.Safari") is safe to
    /// send — it is the app identifier, not any user content. The `actionKind`
    /// is "click" or "type" — no typed text. No text content from TYPE payloads
    /// ever appears in any analytics payload; text-to-type is a device-local
    /// secret between the user and the target app.
    static func trackActionProposed(actionKind: String, targetAppBundleID: String) {
        PostHogSDK.shared.capture("act_mode_action_proposed", properties:
            buildActionEventProperties(
                actionKind: actionKind,
                targetAppBundleID: targetAppBundleID
            )
        )
    }

    /// The user confirmed an action (pressed Return on the confirmation panel).
    ///
    /// No text content included — see privacy note on `trackActionProposed`.
    static func trackActionConfirmed(actionKind: String, targetAppBundleID: String) {
        PostHogSDK.shared.capture("act_mode_action_confirmed", properties:
            buildActionEventProperties(
                actionKind: actionKind,
                targetAppBundleID: targetAppBundleID
            )
        )
    }

    /// The user cancelled an action (pressed Esc, PTT, or the cancel button).
    ///
    /// No text content included — see privacy note on `trackActionProposed`.
    static func trackActionCancelled(actionKind: String, targetAppBundleID: String) {
        PostHogSDK.shared.capture("act_mode_action_cancelled", properties:
            buildActionEventProperties(
                actionKind: actionKind,
                targetAppBundleID: targetAppBundleID
            )
        )
    }

    /// An action failed to execute (stale target, refused, or execution error).
    ///
    /// `failureReason` is a short machine-readable tag (e.g. "staleTarget",
    /// "refused_secure_field") — never user-entered text.
    /// No text content included — see privacy note on `trackActionProposed`.
    static func trackActionFailed(
        actionKind: String,
        targetAppBundleID: String,
        failureReason: String
    ) {
        var properties = buildActionEventProperties(
            actionKind: actionKind,
            targetAppBundleID: targetAppBundleID
        )
        properties["failure_reason"] = failureReason
        PostHogSDK.shared.capture("act_mode_action_failed", properties: properties)
    }

    // MARK: - Pure payload builder (testable)

    /// Builds the base properties dictionary for act-mode action analytics events.
    ///
    /// Extracted as a pure static function so tests can verify that no user
    /// content (e.g. TYPE text payloads) ever appears in the output. Call sites
    /// pass exactly `actionKind` ("click" or "type") and `targetAppBundleID`
    /// — nothing else.
    ///
    /// PRIVACY INVARIANT (enforced by this function's signature):
    ///   The function accepts only `actionKind` and `targetAppBundleID`.
    ///   There is no `textToType` parameter. Any caller that tries to pass
    ///   typed text here will fail to compile. This is the primary compile-time
    ///   guarantee that TYPE payloads never reach the analytics backend.
    static func buildActionEventProperties(
        actionKind: String,
        targetAppBundleID: String
    ) -> [String: Any] {
        return [
            "action_kind": actionKind,
            "target_app_bundle_id": targetAppBundleID
            // INTENTIONALLY NO "text_to_type" KEY HERE.
            // TYPE payloads must never leave this device via analytics.
            // If you add a typed-text field here, you violate the privacy contract.
        ]
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
        PostHogSDK.shared.capture("response_error", properties: [
            "error": error
        ])
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
        PostHogSDK.shared.capture("tts_error", properties: [
            "error": error
        ])
    }
}
