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
