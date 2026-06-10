//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    // MARK: - U12: Accessibility health state (stale-TCC self-check)

    /// Trusted process + successful AX read = healthy. The normal case after a
    /// clean install or re-grant.
    @Test func accessibilityHealthStateIsTrustedAndReadSucceeded() {
        let state = WindowPositionManager.accessibilityHealthState(
            isProcessTrusted: true,
            trivialAXReadSucceeded: true
        )
        #expect(state == .healthy)
    }

    /// Trusted process + FAILED AX read = stale grant. Common after re-signing
    /// dev builds or a macOS update that invalidates the cached TCC entry.
    /// The panel must surface the "re-toggle Accessibility" hint.
    @Test func accessibilityHealthStateIsTrustedButReadFailed() {
        let state = WindowPositionManager.accessibilityHealthState(
            isProcessTrusted: true,
            trivialAXReadSucceeded: false
        )
        #expect(state == .staleGrantNeedsReToggle)
    }

    /// Untrusted process = not granted, regardless of the read result. The read
    /// would never succeed anyway; this case routes to the normal grant flow.
    @Test func accessibilityHealthStateIsNotTrusted() {
        let stateWhenReadAlsoFailed = WindowPositionManager.accessibilityHealthState(
            isProcessTrusted: false,
            trivialAXReadSucceeded: false
        )
        #expect(stateWhenReadAlsoFailed == .notGranted)

        // Even if somehow the read "succeeded" with an untrusted process (which
        // cannot happen in practice), the function must still report notGranted —
        // the trust flag is the authoritative source.
        let stateWhenReadBizarrelySucceeded = WindowPositionManager.accessibilityHealthState(
            isProcessTrusted: false,
            trivialAXReadSucceeded: true
        )
        #expect(stateWhenReadBizarrelySucceeded == .notGranted)
    }

    // MARK: - U12: System prompt act-mode gating

    /// When act mode is OFF the system prompt must not contain the CLICK/TYPE
    /// grammar paragraph. This is the prompt-level gate that prevents Claude
    /// from ever proposing actions unless the user explicitly opts in.
    @Test func systemPromptOmitsActModeGrammarWhenActModeIsDisabled() {
        let promptWithActModeOff = CompanionManager.companionVoiceResponseSystemPrompt(
            actModeEnabled: false
        )
        // The grammar paragraph's unique opening line — if this is absent, the
        // model cannot learn the CLICK/TYPE syntax.
        #expect(!promptWithActModeOff.contains("act mode (enabled):"))
        #expect(!promptWithActModeOff.contains("[CLICK:E<id>"))
        #expect(!promptWithActModeOff.contains("[TYPE:E<id>"))
    }

    /// When act mode is ON the system prompt must contain the full CLICK/TYPE
    /// grammar so Claude can propose actions.
    @Test func systemPromptIncludesActModeGrammarWhenActModeIsEnabled() {
        let promptWithActModeOn = CompanionManager.companionVoiceResponseSystemPrompt(
            actModeEnabled: true
        )
        #expect(promptWithActModeOn.contains("act mode (enabled):"))
        #expect(promptWithActModeOn.contains("[CLICK:E<id>"))
        #expect(promptWithActModeOn.contains("[TYPE:E<id>"))
    }

    /// The base prompt (walkthrough grammar, pointing rules, etc.) must be
    /// present in BOTH variants — act mode gating should only ADD content,
    /// never remove existing functionality.
    @Test func systemPromptBaseContentIsPreservedInBothActModeVariants() {
        let promptOff = CompanionManager.companionVoiceResponseSystemPrompt(actModeEnabled: false)
        let promptOn  = CompanionManager.companionVoiceResponseSystemPrompt(actModeEnabled: true)

        // The base prompt's element-pointing section is always present.
        #expect(promptOff.contains("grounded pointing with element IDs:"))
        #expect(promptOn.contains("grounded pointing with element IDs:"))

        // The act-mode-on prompt is strictly longer (it includes the grammar paragraph).
        #expect(promptOn.count > promptOff.count)
    }

    // MARK: - U12: Analytics payload privacy audit

    /// The action-event payload builder must NEVER include typed text.
    /// This test is the compile-time + runtime guarantee that TYPE payloads
    /// do not leave the device via analytics.
    @Test func actionEventPayloadBuilderNeverIncludesTypedText() {
        // Build a payload with a known actionKind and bundleID.
        let payload = ClickyAnalytics.buildActionEventProperties(
            actionKind: "type",
            targetAppBundleID: "com.apple.TextEdit"
        )

        // The payload must contain exactly the two documented keys.
        #expect(payload["action_kind"] as? String == "type")
        #expect(payload["target_app_bundle_id"] as? String == "com.apple.TextEdit")

        // CRITICAL: no key that could carry typed text must exist.
        // If any of these assertions fail, a TYPE payload is leaking to analytics.
        #expect(payload["text_to_type"] == nil)
        #expect(payload["typed_text"] == nil)
        #expect(payload["text"] == nil)
        #expect(payload["content"] == nil)

        // Total key count must be exactly 2. Adding any new key that could
        // carry user content would fail this assertion and force a review.
        #expect(payload.count == 2)
    }

    /// Same check for click actions — verify the payload shape is identical
    /// (click actions have no text field either).
    @Test func actionEventPayloadBuilderForClickContainsTwoKeysOnly() {
        let payload = ClickyAnalytics.buildActionEventProperties(
            actionKind: "click",
            targetAppBundleID: "com.apple.Safari"
        )
        #expect(payload["action_kind"] as? String == "click")
        #expect(payload["target_app_bundle_id"] as? String == "com.apple.Safari")
        #expect(payload.count == 2)
    }

}
