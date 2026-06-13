//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    // MARK: - Act-mode published state (U12)

    /// Whether act mode is currently enabled. Mirrors the UserDefaults flag
    /// defined in CompanionManager+PendingAction.swift so SwiftUI views can
    /// bind a Toggle to it and receive change notifications.
    ///
    /// The UserDefaults key (`actModeEnabled`) is defined in
    /// CompanionManager+PendingAction.swift as `actModeEnabledUserDefaultsKey`.
    /// This @Published wrapper is the UI-facing source-of-truth; write through
    /// `setActModeEnabled(_:)` so both the @Published value and UserDefaults stay
    /// in sync. Do NOT write UserDefaults directly from the toggle binding —
    /// that would create a second source of truth.
    @Published var isActModeEnabledPublished: Bool = UserDefaults.standard.bool(forKey: "actModeEnabled")

    /// Sets act mode on or off and persists the choice to UserDefaults.
    ///
    /// Called by the toggle binding in CompanionPanelView. Also fires the
    /// actModeEnabled/actModeDisabled analytics events.
    func setActModeEnabled(_ enabled: Bool) {
        isActModeEnabledPublished = enabled
        UserDefaults.standard.set(enabled, forKey: Self.actModeEnabledUserDefaultsKey)
        if enabled {
            ClickyAnalytics.trackActModeEnabled()
        } else {
            ClickyAnalytics.trackActModeDisabled()
        }
        print("🎬 Act mode: \(enabled ? "enabled" : "disabled")")
    }

    // MARK: - Accessibility health state (U12 stale-TCC self-check)

    /// The result of the launch-time stale-TCC self-check.
    ///
    /// Updated once at launch (in `start()`) and again on demand via
    /// `performAccessibilityHealthSelfCheck()`. The panel reads this to decide
    /// whether to show the normal "Granted" badge, a "re-toggle" hint, or the
    /// "Grant" button.
    ///
    /// Starts as `.notGranted` so the panel renders the correct initial state
    /// before the first check completes.
    @Published private(set) var accessibilityHealthState: AccessibilityHealthState = .notGranted

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// The AX element inventory that was available when the current interaction
    /// was dispatched to Claude. Used during response parsing to resolve
    /// [POINT:E<id>:...] element-ID tags to exact screen coordinates.
    ///
    /// Set to nil here as a placeholder — U4 wires the actual inventory capture
    /// (screenshot + AX walk run concurrently before the Claude API call).
    /// The property is non-private so resolution logic in the same file can read it
    /// without needing a separate accessor.
    var inventoryForCurrentInteraction: AccessibilityElementInventory? = nil

    /// Annotation tags (BOX/CIRCLE/ARROW/HIGHLIGHT) parsed from the most recent
    /// Claude response for the current interaction.
    ///
    /// Populated in `sendTranscriptToClaudeWithScreenshot` immediately after
    /// `AnnotationTagParser.parseAnnotationTags(from:)` runs — BEFORE the
    /// end-anchored POINT parser so the POINT parser sees a clean tail.
    ///
    /// Reset to empty on every new interaction (when this method is entered),
    /// matching the lifecycle of `inventoryForCurrentInteraction`.
    var annotationsParsedFromCurrentResponse: [ParsedScreenAnnotation] = []

    /// Annotations from the current response that have been fully resolved to
    /// on-screen AppKit rectangles and are ready for the overlay to render.
    ///
    /// Each entry carries the AppKit-global rect, the display frame of its
    /// target screen (so each per-screen BlueCursorView can filter to its own
    /// screen), the annotation kind, and an optional label.
    ///
    /// Published so BlueCursorView observes it and reacts to changes exactly
    /// like `detectedElementScreenLocation` — the same state-publication
    /// handshake. Set alongside the pointing publication in
    /// `sendTranscriptToClaudeWithScreenshot`; cleared inside
    /// `clearDetectedElementLocation()` so both halves of the overlay state
    /// (pointing cursor + annotation shapes) are always cleared together.
    // internal(set) — not private(set) — so CompanionManager+PendingAction.swift
    // (a separate file extension in the same module) can append/remove highlight
    // annotations without having to funnel every mutation through a helper on the
    // class itself. All writes still happen on @MainActor.
    @Published var resolvedScreenAnnotations: [ResolvedScreenAnnotation] = []

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Walkthrough step state machine for Phase C (guided walkthroughs).
    ///
    /// Exposed as a `let` (not @Published) because WalkthroughController is
    /// itself an ObservableObject — SwiftUI views that need walkthrough state
    /// observe walkthroughController directly (e.g. via @ObservedObject or by
    /// reading companionManager.walkthroughController in an @EnvironmentObject
    /// context). This is the same pattern as buddyDictationManager: the child
    /// object publishes its own state, and the parent exposes the object itself
    /// rather than mirroring every property.
    ///
    /// U8 calls walkthroughController.apply(event:) as turns complete.
    /// U9 reads walkthroughController.phase and currentSnapshot for the
    /// overlay chip and panel controls.
    let walkthroughController = WalkthroughController()

    /// The most recently parsed walkthrough step from a Claude response.
    ///
    /// Stored so the TTS-completion observer in sendTranscriptToClaudeWithScreenshot
    /// can fire apply(.stepPresented(step:)) after TTS finishes — the step data
    /// must survive from parse time (mid-task) to the post-TTS polling loop.
    ///
    /// Reset to nil at the start of each new turn so a stale step from a
    /// previous turn cannot accidentally re-trigger step presentation.
    private var pendingWalkthroughStepAfterTTS: WalkthroughStep? = nil

    /// The resolved screen annotations that belong to the currently active
    /// walkthrough step — stored separately so they can survive a help turn
    /// (which may replace resolvedScreenAnnotations with its own annotations).
    ///
    /// Set when the walkthrough controller transitions to awaitingUserAction
    /// (i.e. when the step has been fully presented and the step's pointing +
    /// annotations are on screen). Cleared by clearAllStepVisuals() at the end
    /// of the walkthrough or on cancel.
    ///
    /// After a help turn's TTS completes, these annotations are restored into
    /// resolvedScreenAnnotations so the step's visual anchor reappears even
    /// though the help response may have temporarily replaced them.
    var stepAnnotationsForActiveWalkthrough: [ResolvedScreenAnnotation] = []

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    /// OpenRouter vision client, allocated once on first use.
    ///
    /// Only touched when ~/Library/Application Support/Clicky/llm.json is
    /// present and specifies "openrouter" as the provider. The API key is
    /// read from that file at call time — it is never stored in this property
    /// or anywhere else in the binary.
    private lazy var openRouterAPI: OpenRouterAPI = {
        return OpenRouterAPI()
    }()

    /// Ollama local vision client, allocated once on first use.
    ///
    /// Only touched when ~/Library/Application Support/Clicky/llm.json is
    /// present and specifies "ollama" as the provider. No API key is needed —
    /// Ollama is a local server that ignores the Authorization header. The
    /// client is configured with long timeouts (180s request / 240s resource)
    /// to accommodate cold-start loading of a local 4.7B model on an M1.
    private lazy var ollamaAPI: OllamaAPI = {
        return OllamaAPI()
    }()

    // Internal (not private): the CompanionManager+PendingAction extension lives in a
    // separate file and speaks action outcomes through this client.
    lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // Phase D (act mode, U11): subscribe to the Esc and PTT kill-switch channels
        // so pending actions are aborted on either signal. Must be called after
        // bindShortcutTransitions() so both subscriptions to shortcutTransitionPublisher
        // are live. The two subscriptions are independent and do not interfere.
        bindActModeKillSwitchObservation()

        // Request Speech Recognition authorization up front so the prompt appears
        // in a calm context at launch instead of racing the push-to-talk release
        // (which cancels the start task before the dialog can surface). No-op once
        // granted, or when the provider doesn't need speech recognition.
        Task { await buddyDictationManager.prewarmSpeechRecognitionAuthorizationIfNeeded() }

        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the local Ollama provider is configured, prewarm the model at launch
        // so the user's first question gets warm (~6s) latency instead of the
        // ~46s cold reload that otherwise makes the app look broken. Best-effort
        // background load; failures are swallowed inside prewarm().
        if let ollamaLaunchConfig = LLMProviderConfiguration.loadFromDisk(), ollamaLaunchConfig.usesOllama {
            Task { await ollamaAPI.prewarm(model: ollamaLaunchConfig.model) }
        }

        // Phase D (act mode, U11): confirmation-panel key-acquisition spike.
        // Only runs when `--confirmation-panel-spike` is in the launch arguments.
        // See ActionConfirmationPanel.swift for full spike instructions.
        // Compiled only in DEBUG builds (the spike body is #if DEBUG guarded there).
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--confirmation-panel-spike") {
            ActionConfirmationPanel.runKeyAcquisitionSpike()
        }
        #endif

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Phase D (act mode, U12): perform the stale-TCC self-check once at launch.
        // Runs async on the AX serial queue so the main thread is never blocked.
        // If the check discovers a stale grant, `accessibilityHealthState` is
        // updated to `.staleGrantNeedsReToggle` and the panel surfaces the
        // "re-toggle Accessibility" hint instead of the normal "Granted" badge.
        Task {
            await performAccessibilityHealthSelfCheck()
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    /// Clears the pointing trio (buddy cursor target) and — unless a walkthrough
    /// step is actively being shown — also clears the annotation shapes.
    ///
    /// During a walkthrough's .awaitingUserAction or .presentingStep phase the
    /// annotations are the step's visual anchor and must survive the 3-second
    /// hold-and-fly-back that normally clears them.  The buddy still flies home
    /// (detectedElementScreenLocation is always cleared), but the annotation
    /// shapes remain until the walkthrough ends or is cancelled.
    ///
    /// For all non-walkthrough code paths this function behaves exactly as
    /// before: annotations are cleared together with the pointing trio.
    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil

        // Preserve annotations while a walkthrough step is live.
        // Both .awaitingUserAction and .presentingStep represent phases where the
        // step's visual anchor (annotation shapes) must remain on screen — the
        // former lasts as long as the user takes to complete the step, the latter
        // lasts until TTS finishes. Clearing annotations during either would leave
        // the user with no visual reference for where to look.
        let walkthroughPhase = walkthroughController.phase
        let walkthroughStepIsLive = (walkthroughPhase == .awaitingUserAction
                                     || walkthroughPhase == .presentingStep)
        if walkthroughStepIsLive {
            // The buddy flies home but annotations stay. Do NOT clear
            // resolvedScreenAnnotations here.
            return
        }

        // Non-walkthrough path: remove Claude-authored annotations (they share the
        // pointing lifecycle) but PRESERVE any pending-action highlight so it stays
        // visible for the full confirmation window. The pending-action highlight is
        // owned by act-mode state (clearPendingActionHighlight removes it) — clearing
        // it here when the buddy flies home would leave the confirmation panel without
        // its visual anchor. This mirrors the walkthrough-phase preservation above.
        // FIX 12: use isPendingActionHighlight to identify which entries to keep.
        let pendingActionHighlightsToPreserve = resolvedScreenAnnotations.filter { $0.isPendingActionHighlight }
        resolvedScreenAnnotations = pendingActionHighlightsToPreserve
    }

    /// Clears the pointing trio AND all annotation shapes unconditionally.
    ///
    /// Used at walkthrough end (completion / cancellation) and anywhere a
    /// full reset is needed regardless of walkthrough phase. This is the
    /// companion to clearDetectedElementLocation() — call this one when you
    /// want everything gone, call the other when normal lifecycle rules apply.
    func clearAllStepVisuals() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        resolvedScreenAnnotations = []
        stepAnnotationsForActiveWalkthrough = []
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    // MARK: - AX health self-check (U12)

    /// Performs a cheap one-attribute AX read against the frontmost application
    /// on the shared AX serial queue, then updates `accessibilityHealthState`
    /// based on `WindowPositionManager.accessibilityHealthState(isProcessTrusted:trivialAXReadSucceeded:)`.
    ///
    /// Call at launch (from `start()`) and optionally on demand. The method is
    /// async so the AX work runs off the main thread on the shared serial queue
    /// owned by `AccessibilityElementInventoryService`. The result is published
    /// back to the main actor.
    ///
    /// Frequency design: we run this ONCE at launch (not on every 1.5s poll)
    /// because a trivial AX read on every tick would add unnecessary serial-queue
    /// pressure. The panel's "re-toggle" hint persists until the user acts; a
    /// second on-demand check fires if they tap the hint link (showing the hint
    /// caused them to toggle, so re-checking then is useful).
    @MainActor
    func performAccessibilityHealthSelfCheck() async {
        let isTrusted = AXIsProcessTrusted()

        // If the OS says we're not trusted, we don't need to waste time on an
        // AX read — the health state is .notGranted and we update immediately.
        guard isTrusted else {
            accessibilityHealthState = WindowPositionManager.accessibilityHealthState(
                isProcessTrusted: false,
                trivialAXReadSucceeded: false
            )
            return
        }

        // Perform a cheap one-attribute read on the shared AX serial queue.
        // We read kAXRoleAttribute from the frontmost app element. Any non-error
        // result counts as "read succeeded". We don't need the actual value.
        let trivialReadSucceeded: Bool = await AccessibilityElementInventoryService.shared.performOnAXSerialQueue {
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
                // No frontmost app — treat as read failure so the check is
                // conservative (might surface the hint briefly, but won't miss a
                // real stale grant).
                return false
            }
            let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
            var roleValue: AnyObject?
            let readResult = AXUIElementCopyAttributeValue(
                appElement,
                kAXRoleAttribute as CFString,
                &roleValue
            )
            // Any return other than .success (including .apiDisabled, .cannotComplete,
            // .notImplemented) indicates the grant is stale or the AX subsystem
            // is refusing calls.
            return readResult == .success
        }

        // Publish back on the main actor (performOnAXSerialQueue already bridges
        // back via async/await; this assignment runs on MainActor because the
        // surrounding method is @MainActor).
        accessibilityHealthState = WindowPositionManager.accessibilityHealthState(
            isProcessTrusted: isTrusted,
            trivialAXReadSucceeded: trivialReadSucceeded
        )

        if accessibilityHealthState == .staleGrantNeedsReToggle {
            print("⚠️ AX health check: grant is STALE — trusted=true but read failed. Panel will show re-toggle hint.")
        } else {
            print("✅ AX health check: \(accessibilityHealthState)")
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance.
            // Walkthrough-aware behaviour:
            //   - PTT is NEVER a cancel for the whole walkthrough (the panel button
            //     handles cancellation). PTT during a walkthrough routes the utterance
            //     into the walkthrough context (help or done-signal) — see the routing
            //     in sendTranscriptToClaudeWithScreenshot.
            //   - However if a verification turn is currently in flight (phase == .verifying),
            //     cancelling currentResponseTask means no verdict will arrive. We must
            //     apply .turnInterrupted so the controller returns to awaitingUserAction
            //     and the walkthrough is never stranded in .verifying.
            //   - Step visuals (pointing/annotations for the current step) are owned by
            //     walkthrough state and should NOT be cleared by PTT mid-walkthrough.
            //     U9 will scope clearDetectedElementLocation() to non-walkthrough turns;
            //     for now we call it here unconditionally to preserve existing behaviour.
            let walkthroughPhaseBeforeCancel = walkthroughController.phase
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // After cancelling, notify the controller so it does not get stranded
            // in a phase that has no active turn to drive it forward.
            //
            // FIX 8: previously only .verifying applied .turnInterrupted. But a PTT
            // press during .presentingStep (step TTS playing) also cancels the task
            // and leaves the controller stuck in .presentingStep with no active turn.
            // Apply .turnInterrupted for .presentingStep too — the step was at least
            // partially spoken; the safe state is to wait for the user to act rather
            // than discard the step entirely. WalkthroughController.transition handles
            // .presentingStep + .turnInterrupted → .awaitingUserAction (retry preserved).
            //
            // .verifying: interrupted before a verdict — return to awaiting.
            // .presentingStep: TTS interrupted mid-speech — return to awaiting.
            if walkthroughPhaseBeforeCancel == .verifying
                || walkthroughPhaseBeforeCancel == .presentingStep {
                walkthroughController.apply(event: .turnInterrupted)
            }

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPromptBase = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    grounded pointing with element IDs:
    sometimes you'll receive a section titled "interactive elements of the frontmost app" before your question. this is a live inventory of UI elements with exact frames in the same pixel coordinate space as the screenshots. when this list is present, PREFER the element-ID form over pixel coordinates — it resolves to the exact center of the element on screen and is more accurate than estimating from a screenshot.

    element-ID form: [POINT:E<id>:label] where <id> is the number from the inventory (e.g. [POINT:E12:submit button]). use the ID of the element you want the cursor to fly to. the frames in the list are in the same pixel space as the screenshots, so you can cross-check them visually. only use element IDs from the current list — IDs change between turns.

    fall back to the pixel-coordinate form [POINT:x,y:label:screenN] only for targets that are not in the inventory (off-screen elements, games, video content, or anything the list doesn't include). keep [POINT:none] for turns where pointing wouldn't help.

    examples:
    - inventory present, user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. [POINT:E7:color inspector]"
    - inventory present, user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c. [POINT:E3:source control]"
    - no inventory (or target not in list): "you'll want to open the color inspector — it's right up in the top right area of the toolbar. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode (no inventory): "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"

    screen annotations:
    when the user would benefit from seeing multiple regions highlighted at once — like a form with several fields to fill in, a comparison between two UI areas, or a set of related controls — you can draw annotation shapes directly on the screen. use these alongside or instead of a single POINT when there are multiple things to show.

    annotation tags go INLINE in your response, right where they're relevant — not at the end like POINT. they're stripped before being spoken, so never describe them out loud and never end a sentence with one.

    four shapes: BOX draws a rectangle, CIRCLE draws an oval, ARROW points at something, HIGHLIGHT fills a region with a translucent wash.

    tag format: [SHAPE:target:label] where SHAPE is BOX, CIRCLE, ARROW, or HIGHLIGHT. the label is optional. use the same target forms as POINT:
    - element-ID form (preferred when inventory is present): [BOX:E12:first name field]
    - pixel-rect form (fallback): [BOX:x,y,w,h:label] or [BOX:x,y,w,h:label:screenN] — x,y is the top-left corner, w,h is the size, all in screenshot pixel space (same coordinate space as POINT pixel coordinates).

    pick element IDs from the current inventory when available — they resolve to exact frames and are more accurate than pixel estimates. pixel-rect fallback is for elements not in the inventory (games, video, web content where the AX tree is sparse).

    examples:
    - user asks how to fill out a form: "fill in your name [BOX:E3:name field] then your email [BOX:E4:email field] and hit [ARROW:E7:submit]. [POINT:E3:name field]"
    - user asks what two buttons do: "the left one [HIGHLIGHT:E5:cancel] discards everything, the right one [HIGHLIGHT:E6:save] keeps your changes. [POINT:E5:cancel]"
    - user asks about a login screen (no inventory): "enter your email in the top box [BOX:120,200,400,48:email field] and your password below [BOX:120,264,400,48:password field]. [POINT:120,200:email field]"
    - user asks a general knowledge question: "the capital of france is paris. [POINT:none]"

    you can still include a single POINT at the end to make the cursor fly to the most important element. annotations and POINT work together fine.

    guided walkthroughs:
    when the user asks to be walked through a multi-step process — like "walk me through enabling dark mode" or "guide me through setting up Wi-Fi" — declare the walkthrough and present only the first step. do not dump all the steps at once.

    declaration: at the very beginning of your response, emit [WALKTHROUGH:<total>] where <total> is the total number of steps. then present step 1 immediately in that same response.

    step format: [STEP:<n>:<short imperative instruction>] — the instruction should be a short action the user can take right now (5-10 words max). include a point or annotation for the step's target element so the user knows exactly where to look.

    example first response for a 3-step walkthrough:
    "ok, let's do this in three steps. first, open system settings — you'll find it in the apple menu or spotlight. [WALKTHROUGH:3] [STEP:1:Open System Settings] [POINT:E1:System Settings]"

    after each step: wait. the user will signal when they're done (by saying "done", "i did it", "next", etc., or pressing a button in the panel). you'll then receive a fresh screenshot and element inventory to verify whether they succeeded. respond with [VERIFY:done] if the step was completed correctly, or [VERIFY:retry:<specific corrective hint>] if not. if done, present the next step in the same response with [STEP:<n+1>:<instruction>]. if it was the last step, just [VERIFY:done] and a brief congratulations with no new step tag.

    keep walkthrough instructions short and concrete. one action per step. no multi-part steps.
    """

    // MARK: - Act-mode prompt grammar (U12)

    /// The paragraph appended to the system prompt when act mode is DISABLED.
    ///
    /// Kept separate from `companionVoiceResponseSystemPromptBase` so that when
    /// act mode is ON the base prompt does NOT contain contradictory "you cannot
    /// click" instructions alongside the act-mode-on grammar paragraph.
    ///
    /// Voice matches the rest of the prompt: lowercase, casual.
    private static let actModeOffParagraph = """

    act mode (currently off):
    you cannot click buttons or type text on the user's behalf right now — act mode is off. if the user asks you to "click", "press", "type", "fill in", or otherwise do something for them, tell them you can't do that with act mode off, and guide them on how to do it themselves instead. don't be apologetic or long-winded — just redirect naturally: "i can't click for you right now, but here's how to do it yourself..." if they want you to take actions, they can enable act mode from the clicky panel.
    """

    /// The paragraph appended to the system prompt when act mode is enabled.
    ///
    /// DESIGN: the CLICK/TYPE grammar is ONLY advertised when act mode is on.
    /// This is the prompt-level gate: Claude never sees the grammar — and therefore
    /// never proposes actions — unless the user explicitly opted in. It works
    /// alongside the execution-level gate in PendingActionStateMachine for defence
    /// in depth: a jailbroken model response still cannot execute actions when the
    /// toggle is off because filterActionsForEnqueuing drops them before any panel
    /// is shown.
    ///
    /// Voice matches the rest of the prompt: lowercase, casual, action-oriented.
    /// No newlines in TYPE text is enforced here (at the prompt level) AND in
    /// ActionExecutionService (at the execution level) — belt and braces.
    private static let actModeGrammarParagraph = """

    act mode (enabled):
    the user has turned on act mode. this means you can click buttons and type text on their behalf — but every action requires their explicit confirmation before anything happens. they'll see a preview panel and must press return to confirm or esc to cancel.

    when the user asks you to do something for them and act mode is on, emit action tags anywhere in your response (they're stripped before being spoken, so never describe them out loud and never end a sentence with one):
    - to click a UI element: [CLICK:E<id>:short plain-english description]
    - to type text into a field: [TYPE:E<id>:text to type:short plain-english description]

    element IDs (E1, E2, …) come ONLY from the current interactive-elements inventory. never use an ID from a previous turn — they change every interaction.

    rules for act mode:
    - every action requires user confirmation. never assume confirmation.
    - never type into password fields (AXSecureTextField). if the target is a secure field, describe what to do instead.
    - never include newlines or control characters in TYPE text — only plain text the user can read in the preview.
    - keep descriptions honest and brief: "click Save" not "click the big important Save button".
    - if the inventory is absent or the target element isn't in it, describe the action in words instead of emitting a tag.

    examples:
    - user says "click save for me": "got it. [CLICK:E5:click Save button]"
    - user says "fill in my name": "filling that in. [TYPE:E3:Jane Smith:type name into Name field]"
    - user says "submit the form": "on it. [TYPE:E2:Jane Smith:fill Name] [TYPE:E4:jane@example.com:fill Email] then [CLICK:E7:click Submit]"
    """

    /// Returns the system prompt for a normal (non-verification) companion turn.
    ///
    /// Converted from a `static let` to a `static func` (U12) so the act-mode
    /// grammar paragraph is appended conditionally at request time. This is a
    /// pure function — same inputs always produce the same output — so it is
    /// directly unit-testable without constructing a CompanionManager.
    ///
    /// - Parameter actModeEnabled: When true the CLICK/TYPE grammar paragraph is
    ///   appended; when false the base prompt is returned unchanged so Claude
    ///   never learns the grammar and cannot propose actions.
    /// - Returns: The complete system prompt string ready to pass to the API.
    static func companionVoiceResponseSystemPrompt(actModeEnabled: Bool) -> String {
        actModeEnabled
            ? companionVoiceResponseSystemPromptBase + actModeGrammarParagraph
            : companionVoiceResponseSystemPromptBase + actModeOffParagraph
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    ///
    /// WALKTHROUGH ROUTING (Phase C, U8)
    /// ──────────────────────────────────────────────────────────────────────
    /// When a walkthrough is active (walkthroughController.phase != .inactive),
    /// the transcript is classified locally before dispatching to Claude:
    ///
    ///   - Done-signal ("done", "i did it", "next", etc.) → runWalkthroughVerificationTurn()
    ///     applies .userSignaledStepDone and starts a verification turn.
    ///
    ///   - Everything else → help turn: normal Claude turn with the regular system
    ///     prompt augmented with current walkthrough context so Claude knows the user
    ///     is mid-walkthrough and should be returned to the current step after helping.
    ///     Applies .userAskedForHelp (phase stays awaitingUserAction, no step advance).
    ///
    /// When no walkthrough is active the method behaves exactly as before.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        // Reset the pending step so TTS completion from a previous turn cannot
        // accidentally fire stepPresented for a stale step.
        pendingWalkthroughStepAfterTTS = nil

        // --- Walkthrough routing: classify the transcript BEFORE dispatching ---
        // Only route when a walkthrough is active and the user is awaiting action.
        // Other phases (presentingStep, verifying) are managed internally.
        if walkthroughController.phase == .awaitingUserAction {
            if WalkthroughTagParser.transcriptMatchesDoneSignal(transcript) {
                // User signalled they completed the step — start verification.
                runWalkthroughVerificationTurn()
                return
            }
            // Not a done-signal → treat as a help question: fall through to the
            // normal Claude turn below, but augment the system prompt with walkthrough
            // context so Claude knows to return the user to the current step after helping.
            walkthroughController.apply(event: .userAskedForHelp)
        }

        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Run screenshot capture and the AX element walk concurrently so
                // neither blocks the other. The AX walk is raced against a 1.5s
                // timeout: if it cannot finish in time this turn proceeds with NO
                // inventory rather than delaying the interaction. The walk continues
                // in the background (warming Electron trees and completing into
                // mostRecentCompletedInventory) so the next turn's fresh walk can
                // finish inside the budget — at most one turn is un-grounded after
                // a slow app. A previous turn's inventory is never sent for the
                // current turn: its frames describe a screen state that may no
                // longer match the screenshot, and the E-id resolver only resolves
                // against the inventory captured for this interaction.
                // Screenshots and AX walk run concurrently. async let is fine for
                // screenCapturesResult because it is awaited directly below (legal).
                // The AX walk is called directly inside the child task instead of via
                // async let, because Swift forbids capturing an async-let binding in a
                // Sendable child-task closure. The walk's background-completion behaviour
                // is preserved: AccessibilityElementInventoryService runs the walk body
                // on its own serial dispatch queue, which ignores Swift task cancellation,
                // so the walk continues warming Electron trees even after the group
                // cancels the child task below.
                async let screenCapturesResult = CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Race the AX walk against a 1.5s deadline. On timeout we synthesise
                // a .timedOut outcome so analytics can track the miss separately from
                // an empty tree. The walk itself keeps running and will complete into
                // mostRecentCompletedInventory for the next turn.
                let axInventoryTimeoutInNanoseconds: UInt64 = 1_500_000_000
                let completedInventoryOrNil: AccessibilityElementInventory?
                let axWalkOutcomeForAnalytics: AccessibilityInventoryCaptureOutcome

                do {
                    // withTaskGroup lets us race the real walk against a sleep.
                    // The first to finish wins; we cancel the other branch.
                    let raceResult = await withTaskGroup(
                        of: AccessibilityElementInventory?.self
                    ) { group in
                        // Call the service directly inside the child task — NOT via
                        // async let. Swift prohibits capturing an async-let binding in
                        // a Sendable closure (SE-0304); calling the service here avoids
                        // that restriction while keeping true concurrency with screenshots.
                        group.addTask {
                            return await AccessibilityElementInventoryService.shared.captureInventoryOfFrontmostWindow()
                        }
                        group.addTask {
                            try? await Task.sleep(nanoseconds: axInventoryTimeoutInNanoseconds)
                            // Return nil to signal timeout — the winner check below
                            // distinguishes a real inventory from this nil sentinel.
                            return nil
                        }
                        // Take the first result; cancel the remaining branch.
                        let firstResult = await group.next()
                        // FIX 3: when the sleep sentinel wins it returns nil, so
                        // group.next() yields .some(.none) — NOT nil (nil from
                        // group.next() means the group is exhausted, which cannot
                        // happen with 2 live tasks). Use pattern matching to detect
                        // the timeout case and drain one more result: the real walk
                        // may have completed microseconds after the sleep fired.
                        // cancelAll() marks the walk task cancelled but does NOT
                        // discard a result that already arrived; the second await
                        // returns promptly once the task is cancelled or done.
                        if case .some(.none) = firstResult {
                            group.cancelAll()
                            let secondResult = await group.next()
                            return secondResult ?? nil
                        }
                        group.cancelAll()
                        return firstResult ?? nil
                    }

                    if let inventoryFromRace = raceResult {
                        // Walk finished before the timeout — use the real result
                        completedInventoryOrNil = inventoryFromRace
                        axWalkOutcomeForAnalytics = inventoryFromRace.captureOutcome
                    } else {
                        // Timeout branch won — proceed without a live inventory for
                        // this turn. The background walk will still complete and update
                        // mostRecentCompletedInventory for the next turn.
                        completedInventoryOrNil = nil
                        axWalkOutcomeForAnalytics = .timedOut
                    }
                }

                // Assign the resolved inventory so response-parsing code in this
                // same file can look up element IDs against it.
                inventoryForCurrentInteraction = completedInventoryOrNil

                // Capture the screen captures result (may throw)
                let screenCaptures = try await screenCapturesResult

                guard !Task.isCancelled else { return }

                // Track the AX walk outcome in analytics — this lets us measure
                // how often inventory is available vs timed out vs absent.
                let frontmostAppNameForAnalytics = completedInventoryOrNil?.frontmostAppName
                    ?? AccessibilityElementInventoryService.shared.mostRecentCompletedInventory?.frontmostAppName
                    ?? ""
                ClickyAnalytics.trackAXInventoryWalkCompleted(
                    elementCount: completedInventoryOrNil?.elements.count ?? 0,
                    captureOutcome: axWalkOutcomeForAnalytics,
                    frontmostAppName: frontmostAppNameForAnalytics
                )

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Build the supplemental AX inventory text block if an inventory
                // is available. The inventory is frontmost-window-only; screenshots
                // remain all-displays so the two data sources naturally complement
                // each other. We use the cursor screen's capture dimensions to put
                // element frames in the same pixel space as the images.
                //
                // Only the inventory captured for THIS interaction is ever sent.
                // A previous turn's inventory would advertise element IDs the
                // resolver cannot resolve (inventoryForCurrentInteraction is nil
                // on timeout) and frames that may not match the screenshot.
                let supplementalInventoryTextBlock: String? = Self.buildSupplementalInventoryTextBlock(
                    inventory: completedInventoryOrNil,
                    cursorScreenCapture: screenCaptures.first(where: { $0.isCursorScreen })
                )

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // Choose the system prompt. During an active walkthrough help turn
                // (phase was awaitingUserAction and the transcript was NOT a done-signal),
                // we augment the base prompt with walkthrough context so Claude knows
                // the user is mid-walkthrough and should be guided back to the current
                // step after answering. The help-turn augment is built inline here so
                // it stays close to the dispatch site and is easy to read.
                let effectiveSystemPrompt: String = {
                    // U12: pass the current act-mode state into the prompt builder
                    // so the CLICK/TYPE grammar paragraph is included only when
                    // act mode is on. This is checked at request time (not at startup)
                    // so toggling act mode mid-session takes effect on the next turn.
                    let basePrompt = Self.companionVoiceResponseSystemPrompt(
                        actModeEnabled: isActModeEnabled
                    )
                    let snapshot = walkthroughController.currentSnapshot
                    guard snapshot.phase == .awaitingUserAction,
                          !snapshot.declaredSteps.isEmpty else {
                        return basePrompt
                    }
                    let currentStepIndex = snapshot.currentStepIndex
                    let currentInstruction = currentStepIndex < snapshot.declaredSteps.count
                        ? snapshot.declaredSteps[currentStepIndex].instruction
                        : ""
                    let stepContext = "the user is mid-walkthrough (step \(currentStepIndex + 1) of \(snapshot.totalStepCount): \"\(currentInstruction)\"). answer their question, then remind them to go back to the current step when ready. do not advance the walkthrough or emit [STEP:] or [VERIFY:] tags."
                    return basePrompt + "\n\n" + stepContext
                }()

                // Provider switch: if the user has placed a local llm.json config at
                // ~/Library/Application Support/Clicky/llm.json, route this vision request
                // through the appropriate client instead of the default Claude-via-Worker
                // path. Supported providers: "openrouter" (remote, API key required) and
                // "ollama" (local localhost:11434, no API key needed). When the file is
                // absent or invalid, the default Claude path is used.
                let llmProviderConfig = LLMProviderConfiguration.loadFromDisk()
                appendDebugLog("LLM routing — provider=\(llmProviderConfig?.provider ?? "nil (default Claude)"), model=\(llmProviderConfig?.model ?? "-"), localVoice=\(llmProviderConfig?.localVoiceOutput ?? false)")

                let fullResponseText: String
                if let openRouterConfig = llmProviderConfig, openRouterConfig.usesOpenRouter {
                    print("🔀 Using OpenRouter provider — model: \(openRouterConfig.model)")
                    fullResponseText = try await openRouterAPI.analyzeImage(
                        images: labeledImages,
                        systemPrompt: effectiveSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        supplementalContextText: supplementalInventoryTextBlock,
                        apiKey: openRouterConfig.apiKey,
                        model: openRouterConfig.model
                    )
                } else if let ollamaConfig = llmProviderConfig, ollamaConfig.usesOllama {
                    // Local Ollama path — no API key, long timeouts for cold-start inference.
                    print("🦙 Using Ollama provider — model: \(ollamaConfig.model)")
                    fullResponseText = try await ollamaAPI.analyzeImage(
                        images: labeledImages,
                        systemPrompt: effectiveSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        supplementalContextText: supplementalInventoryTextBlock,
                        model: ollamaConfig.model
                    )
                } else {
                    // Default path: Claude via Cloudflare Worker proxy (streaming).
                    let (claudeResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: effectiveSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        supplementalContextText: supplementalInventoryTextBlock,
                        onTextChunk: { _ in
                            // No streaming text display — spinner stays until TTS plays
                        }
                    )
                    fullResponseText = claudeResponseText
                }

                appendDebugLog("LLM RESPONSE OK — raw length=\(fullResponseText.count) chars, preview=\(fullResponseText.prefix(120))")

                guard !Task.isCancelled else { return }

                // --- Annotation parsing (Phase B, U5) ---
                // Run the scanning annotation parser FIRST, before the end-anchored
                // POINT parser. Annotation tags appear anywhere in the response body;
                // stripping them here ensures the POINT parser sees a clean tail so
                // its end-anchor regex still finds [POINT:...] at the true end of text.
                //
                // Parse order contract (documented in AnnotationTagParser.swift):
                //   1. parseAnnotationTags   — strips BOX/CIRCLE/ARROW/HIGHLIGHT tags
                //   2. parsePointingCoordinates — sees annotation-free text, POINT intact
                //
                // U6 will read `annotationsParsedFromCurrentResponse` to render shapes.
                // We reset it here at the start of each response so stale annotations
                // from a prior turn are never shown alongside a new response.
                annotationsParsedFromCurrentResponse = []
                let annotationParseResult = AnnotationTagParser.parseAnnotationTags(from: fullResponseText)
                annotationsParsedFromCurrentResponse = annotationParseResult.annotations

                // The text with annotation tags stripped is what flows downstream:
                // into the POINT parser, TTS, and conversation history. This is the
                // same pattern as POINT stripping — tags are never spoken or stored.
                let responseTextAfterAnnotationStripping = annotationParseResult.strippedText

                if !annotationParseResult.annotations.isEmpty {
                    print("🖼️ Annotations parsed: \(annotationParseResult.annotations.count) shapes")
                }

                // --- Walkthrough tag parsing (Phase C, U8) ---
                // Run AFTER annotation stripping and BEFORE the POINT parser so the
                // parse-order contract is maintained: POINT sees a clean tail free of
                // all inline tags. The walkthrough tags ([WALKTHROUGH:] and [STEP:])
                // are stripped here; the stripped text flows into POINT parsing, TTS,
                // and conversation history.
                //
                // Declaration handling: apply .walkthroughDeclared immediately so the
                // controller moves to presentingStep before we present the step.
                //
                // Step handling: store the parsed step in pendingWalkthroughStepAfterTTS.
                // We apply .stepPresented AFTER TTS finishes (below, in the post-TTS
                // polling loop) so the phase only reaches awaitingUserAction once the
                // user has heard the instruction — matching the plan's requirement that
                // stepPresented fires "after TTS for this turn completes".
                let walkthroughParseResult = WalkthroughTagParser.parseWalkthroughTags(
                    from: responseTextAfterAnnotationStripping
                )

                if let declaration = walkthroughParseResult.declaration {
                    walkthroughController.apply(event: .walkthroughDeclared(totalStepCount: declaration.totalStepCount))
                    ClickyAnalytics.trackWalkthroughStarted(totalSteps: declaration.totalStepCount)
                    print("📋 Walkthrough declared: \(declaration.totalStepCount) steps")
                }

                if let step = walkthroughParseResult.step {
                    // Store so the post-TTS block below can fire stepPresented once
                    // the user has heard the instruction.
                    // Convert the parser's ParsedWalkthroughStep into the controller's
                    // WalkthroughStep (same fields, distinct types across the parse/state layers).
                    pendingWalkthroughStepAfterTTS = WalkthroughStep(stepNumber: step.stepNumber, instruction: step.instruction)
                    print("📋 Walkthrough step \(step.stepNumber) pending TTS: \"\(step.instruction)\"")
                }

                // The text with both annotation AND walkthrough tags stripped is what
                // flows into POINT parsing, TTS, and conversation history.
                let responseTextAfterWalkthroughStripping = walkthroughParseResult.strippedText

                // --- Annotation resolution (Phase B, U6) ---
                // Resolve the parsed annotations to exact AppKit-global rects and
                // publish them so each per-screen BlueCursorView can render its slice.
                // Resolution uses the inventory captured for THIS interaction (element-ID
                // form) or ScreenCoordinateConverter (pixel-rect form), mirroring the
                // two pointing-resolution branches exactly.
                //
                // Published BEFORE the POINT resolution block below so the annotations
                // are already set when voiceState switches to .idle (which triggers the
                // flight animation in BlueCursorView and the opacity cross-fade for
                // annotation shapes).
                //
                // resolvedScreenAnnotations is reset to [] at the top of this method
                // via clearDetectedElementLocation() (called by handleShortcutTransition
                // on every new PTT press), and again in clearDetectedElementLocation()
                // when the buddy finishes its return flight — so the lifecycle exactly
                // mirrors the pointing-cursor lifecycle.
                resolvedScreenAnnotations = Self.resolveAnnotationsToScreenRects(
                    parsedAnnotations: annotationParseResult.annotations,
                    inventory: inventoryForCurrentInteraction,
                    screenCaptures: screenCaptures,
                    allScreenFramesInAppKitCoordinates: NSScreen.screens.map { $0.frame }
                )
                if !resolvedScreenAnnotations.isEmpty {
                    print("🖼️ Annotations resolved: \(resolvedScreenAnnotations.count) shapes ready for overlay")
                }

                // --- Action tag parsing (Phase D, U11) ---
                // Run AFTER annotation and walkthrough tags have been stripped, and BEFORE
                // the POINT parser so the parse-order contract is maintained: POINT sees
                // a clean tail free of all inline tags (CLICK/TYPE appear anywhere in the
                // response body, not end-anchored, so they must be stripped before POINT).
                //
                // processActionTagsAndEnqueue (defined in CompanionManager+PendingAction.swift):
                //   1. Parses CLICK/TYPE tags from responseTextAfterWalkthroughStripping.
                //   2. Applies the act-mode gate — drops all if act mode is off.
                //   3. Resolves element IDs against inventoryForCurrentInteraction.
                //   4. Enqueues resolved actions so the confirmation panel appears.
                //   5. Returns the text with CLICK/TYPE tags removed (and optionally a
                //      "act mode is off" notice prefix when actions were dropped).
                //
                // The returned text flows into POINT parsing, TTS, and conversation
                // history — CLICK/TYPE tags are never spoken aloud or stored.
                let responseTextAfterActionTagStripping = processActionTagsAndEnqueue(
                    textAfterWalkthroughStripping: responseTextAfterWalkthroughStripping
                )

                // Parse the [POINT:...] tag from the fully-stripped response text
                // (annotation + walkthrough + action tags all removed). The end-anchor
                // regex reliably finds [POINT:...] at the actual end of the text.
                let parseResult = Self.parsePointingCoordinates(from: responseTextAfterActionTagStripping)
                let spokenText = parseResult.spokenText

                // Resolve the pointing instruction to an on-screen location.
                // Three branches:
                //   1. Element-ID form [POINT:E<id>:...]: look up the element in the
                //      inventory captured for this interaction. If found, publish the
                //      element's AppKit-space center directly — no screenshot-pixel
                //      scaling needed. If not found (nil inventory or unknown ID),
                //      behave like [POINT:none]: speak the response, no pointing, never
                //      a (0,0) point.
                //   2. Pixel-coordinate form [POINT:x,y:...]: use the existing
                //      ScreenCoordinateConverter path, unchanged.
                //   3. [POINT:none] or no tag: no pointing.
                if let targetElementID = parseResult.elementID {
                    // Branch 1: element-ID resolution
                    if let resolvedLocation = Self.resolveElementIDToAppKitCenter(
                        elementID: targetElementID,
                        inventory: inventoryForCurrentInteraction,
                        allScreenFramesInAppKitCoordinates: NSScreen.screens.map { $0.frame }
                    ) {
                        // Switch to idle so the triangle is visible before the flight animation
                        voiceState = .idle

                        let elementScreenFrame = Self.findScreenFrameContainingOrNearestToPoint(
                            point: resolvedLocation,
                            allScreenFramesInAppKitCoordinates: NSScreen.screens.map { $0.frame }
                        )

                        detectedElementScreenLocation = resolvedLocation
                        detectedElementDisplayFrame = elementScreenFrame
                        if let label = parseResult.elementLabel {
                            detectedElementBubbleText = label
                        }
                        ClickyAnalytics.trackElementPointed(
                            elementLabel: parseResult.elementLabel,
                            pointingMethod: .elementIDResolved
                        )
                        print("🎯 Element pointing: E\(targetElementID) → (\(Int(resolvedLocation.x)), \(Int(resolvedLocation.y))) \"\(parseResult.elementLabel ?? "element")\"")
                    } else {
                        // Unknown ID or no inventory — behave like [POINT:none]: just speak, no point
                        ClickyAnalytics.trackElementPointed(
                            elementLabel: parseResult.elementLabel,
                            pointingMethod: .elementIDLookupFailed
                        )
                        print("🎯 Element pointing: E\(targetElementID) not found in inventory — speaking without pointing")
                    }
                } else {
                    // Branch 2 or 3: legacy pixel-coordinate form or [POINT:none] / no tag

                    // Switch to idle BEFORE setting the location so the triangle
                    // becomes visible and can fly to the target. Without this, the
                    // spinner hides the triangle and the flight animation is invisible.
                    let hasPointCoordinate = parseResult.coordinate != nil
                    if hasPointCoordinate {
                        voiceState = .idle
                    }

                    // Pick the screen capture matching Claude's screen number,
                    // falling back to the cursor screen if not specified.
                    let targetScreenCapture: CompanionScreenCapture? = {
                        if let screenNumber = parseResult.screenNumber,
                           screenNumber >= 1 && screenNumber <= screenCaptures.count {
                            return screenCaptures[screenNumber - 1]
                        }
                        return screenCaptures.first(where: { $0.isCursorScreen })
                    }()

                    if let pointCoordinate = parseResult.coordinate,
                       let targetScreenCapture {
                        // Claude's coordinates are in the screenshot's pixel space
                        // (top-left origin, e.g. 1280x831). Scale to the display's
                        // point space (e.g. 1512x982), then convert to AppKit global coords.
                        // ScreenCoordinateConverter handles clamping, ratio-scaling, Y-flip,
                        // and displayFrame.origin offset in one place so this logic is not
                        // duplicated between the main pipeline and the onboarding demo.
                        let displayFrame = targetScreenCapture.displayFrame
                        let globalLocation = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
                            screenshotPixelPoint: pointCoordinate,
                            screenshotWidthInPixels: CGFloat(targetScreenCapture.screenshotWidthInPixels),
                            screenshotHeightInPixels: CGFloat(targetScreenCapture.screenshotHeightInPixels),
                            displayWidthInPoints: CGFloat(targetScreenCapture.displayWidthInPoints),
                            displayHeightInPoints: CGFloat(targetScreenCapture.displayHeightInPoints),
                            displayFrameInAppKitCoordinates: displayFrame
                        )

                        detectedElementScreenLocation = globalLocation
                        detectedElementDisplayFrame = displayFrame
                        ClickyAnalytics.trackElementPointed(
                            elementLabel: parseResult.elementLabel,
                            pointingMethod: .pixelCoordinateFallback
                        )
                        print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                    } else {
                        print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                    }
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                // speakResponse handles both the local-voice and ElevenLabs paths,
                // including the empty-check and voiceState transition.
                await speakResponse(spokenText)

                // --- Post-TTS walkthrough step presentation (Phase C, U8) ---
                // Wait for TTS to finish playing, then apply .stepPresented so the
                // controller transitions from presentingStep → awaitingUserAction.
                // We wait because stepPresented should only fire once the user has
                // actually heard the instruction — firing earlier would leave the
                // overlay chip in "awaiting" while TTS is still playing.
                //
                // Poll pattern mirrors scheduleTransientHideIfNeeded: 200ms intervals,
                // task-cancellation checked each iteration so PTT mid-TTS exits cleanly.
                //
                // We capture pendingWalkthroughStepAfterTTS into a local so a concurrent
                // new turn (which resets the property at the top of sendTranscript...)
                // cannot race this loop.
                if let stepToPresent = pendingWalkthroughStepAfterTTS {
                    // Snapshot the step's annotations NOW — before the async TTS wait.
                    // A help turn that fires and completes DURING TTS playback sets
                    // resolvedScreenAnnotations to help-response overlays. If we snapshot
                    // after the await, stepAnnotationsForActiveWalkthrough would capture
                    // those help annotations instead of the step's BOX/CIRCLE/ARROW shapes,
                    // causing wrong overlays when the user acts on the step.
                    // resolvedScreenAnnotations is set synchronously above (before any await
                    // in this turn), so this snapshot is always the step's own annotations.
                    let stepAnnotationsSnapshot = resolvedScreenAnnotations

                    // Wait for TTS audio to finish before signalling step presented.
                    // waitForTTSPlaybackToFinish uses do/catch so cancellation is not
                    // silently swallowed; it also applies a 30s ceiling so a stuck
                    // isPlaying flag can never spin this loop forever.
                    await waitForTTSPlaybackToFinish()
                    if !Task.isCancelled {
                        pendingWalkthroughStepAfterTTS = nil
                        // FIX 9: only apply .stepPresented when the controller is actually
                        // in .presentingStep. A help turn can contain a stray [STEP:] tag
                        // (e.g. the user asks about a future step); that tag is stripped
                        // from TTS but would incorrectly advance the controller and
                        // overwrite stepAnnotationsForActiveWalkthrough if unchecked.
                        // The transition function itself ignores .stepPresented from other
                        // phases, but the annotation snapshot must also be guarded.
                        if walkthroughController.phase == .presentingStep {
                            walkthroughController.apply(event: .stepPresented(step: WalkthroughStep(
                                stepNumber: stepToPresent.stepNumber,
                                instruction: stepToPresent.instruction
                            )))
                            // Store the pre-TTS snapshot of the step's resolved annotations
                            // so we can restore them after a help turn replaces
                            // resolvedScreenAnnotations with help-response annotations.
                            stepAnnotationsForActiveWalkthrough = stepAnnotationsSnapshot
                            print("📋 Walkthrough step \(stepToPresent.stepNumber) presented — now awaitingUserAction")
                        } else {
                            print("📋 Walkthrough: skipping stepPresented — phase is \(walkthroughController.phase), not presentingStep (FIX 9)")
                        }
                    }
                } else if walkthroughController.phase == .awaitingUserAction
                            && !stepAnnotationsForActiveWalkthrough.isEmpty {
                    // This was a help turn (no pendingWalkthroughStepAfterTTS) while
                    // a walkthrough step was active. The help response's TTS just
                    // finished — restore the step's visual anchor so the user still
                    // sees the annotation for the step they need to complete.
                    //
                    // We wait for TTS to finish first so the help response's own
                    // annotations (if any) don't disappear mid-speech; the step
                    // annotations reappear as a natural handoff once the help is done.
                    await waitForTTSPlaybackToFinish()
                    if !Task.isCancelled {
                        resolvedScreenAnnotations = stepAnnotationsForActiveWalkthrough
                        print("📋 Walkthrough: step annotations restored after help turn")
                    }
                }

            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                appendDebugLog("RESPONSE ERROR: \(error.localizedDescription) || raw: \(error)")
                // Speak the REAL error (truncated) instead of the misleading
                // "out of credits" message so failures are diagnosable from the
                // app itself rather than masked behind one generic line.
                speakTextLocally("Error. " + String(error.localizedDescription.prefix(140)))
                voiceState = .responding
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    ///
    /// WALKTHROUGH SUPPRESSION: when walkthroughController.phase != .inactive
    /// the buddy must remain visible for the entire walkthrough session — the
    /// user needs the overlay to see step annotations and the chip even with
    /// "Show Clicky" off.  In that case this function returns immediately
    /// without scheduling a hide. When the walkthrough ends (completion or
    /// cancellation), cancelActiveWalkthrough() and the verification path
    /// each call scheduleTransientHideIfNeeded() again so normal transient
    /// behaviour resumes at that point.
    private func scheduleTransientHideIfNeeded() {
        // Suppress transient hide during any active walkthrough phase — the
        // buddy must stay visible while the user is being guided step by step.
        guard walkthroughController.phase == .inactive else { return }

        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing. The shared helper uses do/catch
            // so a cancelled task does not keep spinning (try? would swallow
            // CancellationError). The 30s ceiling prevents a stuck isPlaying from
            // blocking this task indefinitely.
            await waitForTTSPlaybackToFinish()
            guard !Task.isCancelled else { return }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor). 10s ceiling prevents a
            // stuck detectedElementScreenLocation from spinning forever.
            let maximumPointingWaitIterations = 50 // 50 * 200ms = 10s
            var pointingPollIterations = 0
            while detectedElementScreenLocation != nil {
                guard pointingPollIterations < maximumPointingWaitIterations else {
                    print("⚠️ scheduleTransientHideIfNeeded: pointing-wait ceiling reached, proceeding with hide")
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
                pointingPollIterations += 1
            }
            guard !Task.isCancelled else { return }

            // Pause 1s after everything finishes, then fade out
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Polls until ElevenLabs TTS playback finishes, the Swift task is cancelled,
    /// or the given total-wait ceiling (in seconds) is exceeded — whichever comes
    /// first.
    ///
    /// Using `try?` on `Task.sleep` is intentionally avoided here: discarding the
    /// error silently swallows `CancellationError`, causing a cancelled task to keep
    /// spinning indefinitely. Instead we use a do/catch that breaks out of the loop
    /// on any error (including cancellation). The ceiling prevents a pathological
    /// `isPlaying` flag that never clears from blocking the pipeline forever.
    ///
    /// - Parameter maximumWaitInSeconds: Upper bound on how long to poll. Defaults
    ///   to 30 seconds — generous enough for the longest expected TTS response while
    ///   still providing a hard exit if the ElevenLabs client gets into a bad state.
    /// - Returns: `true` if playback finished normally, `false` if the task was
    ///   cancelled or the ceiling was reached (callers should check `Task.isCancelled`
    ///   on `false` to distinguish the two cases if needed).
    @discardableResult
    private func waitForTTSPlaybackToFinish(
        maximumWaitInSeconds: Double = 30.0
    ) async -> Bool {
        let pollIntervalInNanoseconds: UInt64 = 200_000_000 // 200 ms
        let maximumIterations = Int(maximumWaitInSeconds * 5) // 5 polls per second

        var iterationsElapsed = 0
        while elevenLabsTTSClient.isPlaying {
            guard iterationsElapsed < maximumIterations else {
                // Ceiling reached — TTS appears stuck; exit to avoid spinning forever.
                print("⚠️ waitForTTSPlaybackToFinish: ceiling of \(maximumWaitInSeconds)s reached, exiting poll loop")
                return false
            }
            do {
                try await Task.sleep(nanoseconds: pollIntervalInNanoseconds)
            } catch {
                // CancellationError or any other error — exit the loop immediately.
                // Callers must check Task.isCancelled after this returns false.
                return false
            }
            iterationsElapsed += 1
        }
        return true
    }

    /// Stored synthesizer for local macOS voice output. Using a stored property
    /// (rather than a local variable) prevents the synthesizer from being
    /// deallocated mid-speech, which would silently cut off the audio.
    private let localSpeechSynthesizer = NSSpeechSynthesizer()

    /// Speaks `text` aloud locally with the macOS synthesizer. Used when local
    /// voice output is configured, and as the fallback when ElevenLabs fails so
    /// the user hears the REAL reply rather than a credits error.
    private func speakTextLocally(_ text: String) {
        localSpeechSynthesizer.stopSpeaking()
        localSpeechSynthesizer.startSpeaking(text)
    }

    /// Appends a timestamped diagnostic line to
    /// ~/Library/Application Support/Clicky/clicky-debug.log so the real cause of
    /// a response-pipeline failure is recoverable — the generic catch otherwise
    /// masks every error behind one user-facing message.
    private func appendDebugLog(_ message: String) {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let directoryURL = applicationSupportURL.appendingPathComponent("Clicky", isDirectory: true)
        let logURL = directoryURL.appendingPathComponent("clicky-debug.log")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let lineData = "[\(Date())] \(message)\n".data(using: .utf8) else { return }
        if let fileHandle = try? FileHandle(forWritingTo: logURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(lineData)
            try? fileHandle.close()
        } else {
            try? lineData.write(to: logURL)
        }
    }

    /// Speaks a model reply. Local macOS voice when `localVoiceOutput` is set in
    /// llm.json (fully offline, no Worker); otherwise ElevenLabs with a local
    /// fallback if it fails (e.g. Worker out of credits). Sets voiceState to
    /// .responding once speech begins.
    private func speakResponse(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            appendDebugLog("SPEAK SKIPPED — spoken text was empty after stripping (model returned only tags or whitespace)")
            return
        }

        if LLMProviderConfiguration.loadFromDisk()?.localVoiceOutput == true {
            appendDebugLog("SPEAK local — len=\(trimmedText.count), synthesizing via NSSpeechSynthesizer")
            speakTextLocally(trimmedText)
            voiceState = .responding
            return
        }

        do {
            try await elevenLabsTTSClient.speakText(trimmedText)
            voiceState = .responding
        } catch {
            ClickyAnalytics.trackTTSError(error: error.localizedDescription)
            print("⚠️ ElevenLabs TTS error: \(error) — falling back to local voice")
            speakTextLocally(trimmedText)
            voiceState = .responding
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Walkthrough Verification Turn

    /// Shared capture helper: runs screenshot capture and AX inventory walk
    /// concurrently, races the walk against a 1.5s timeout, and returns the
    /// results. Extracted so the main pipeline and the verification turn share
    /// one implementation — avoiding duplication of the async let + taskGroup
    /// race pattern.
    ///
    /// FIX 4: this helper also assigns `inventoryForCurrentInteraction` so every
    /// caller keeps the property in sync automatically. Without the assignment here,
    /// a future caller that forgets the manual write would resolve element IDs against
    /// stale inventory from a prior turn. The main pipeline does NOT call this helper
    /// (it has its own inline race) and assigns `inventoryForCurrentInteraction`
    /// itself, so the assignment happens exactly once per turn on both code paths.
    ///
    /// Returns (screenCaptures, inventory). On AX walk timeout inventory is nil;
    /// on screenshot failure the method throws.
    private func captureScreenshotsAndInventory() async throws -> (
        screenCaptures: [CompanionScreenCapture],
        inventory: AccessibilityElementInventory?
    ) {
        // Screenshots and AX walk run concurrently. async let is legal for
        // screenCapturesResult because it is awaited directly (not captured in a
        // Sendable closure). The AX walk is called directly inside the child task
        // to avoid the SE-0304 restriction on capturing async-let bindings in
        // Sendable closures. The walk's background-completion behaviour is preserved:
        // the service runs on its own serial dispatch queue and ignores Swift task
        // cancellation, so it keeps warming trees after the group cancels the child.
        async let screenCapturesResult = CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

        let axInventoryTimeoutInNanoseconds: UInt64 = 1_500_000_000

        let inventoryOrNil: AccessibilityElementInventory? = await withTaskGroup(
            of: AccessibilityElementInventory?.self
        ) { group in
            // Call the service directly — NOT via async let. See Fix 1 comment above.
            group.addTask {
                return await AccessibilityElementInventoryService.shared.captureInventoryOfFrontmostWindow()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: axInventoryTimeoutInNanoseconds)
                return nil
            }
            let firstResult = await group.next()
            // FIX 3 (same as main pipeline): the sleep sentinel returns nil, so
            // group.next() yields .some(.none) — NOT nil. Use pattern matching
            // to detect the timeout case and drain one more result before
            // concluding timeout — the real walk may have completed microseconds
            // after the sleep fired. See the main pipeline comment for details.
            if case .some(.none) = firstResult {
                group.cancelAll()
                let secondResult = await group.next()
                return secondResult ?? nil
            }
            group.cancelAll()
            return firstResult ?? nil
        }

        let screenCaptures = try await screenCapturesResult

        // FIX 4: assign inventoryForCurrentInteraction here so every caller
        // automatically resolves element IDs against the inventory for THIS turn.
        // The main pipeline assigns this itself; callers of this helper must not
        // duplicate the assignment (they will read `inventory` from the return tuple
        // for any additional local use, but the property is already set here).
        inventoryForCurrentInteraction = inventoryOrNil

        return (screenCaptures: screenCaptures, inventory: inventoryOrNil)
    }

    /// Kicks off a walkthrough verification turn.
    ///
    /// Called when the user signals step completion (done-signal via PTT or the
    /// panel "I did it" button). Applies .userSignaledStepDone, captures a fresh
    /// screenshot + AX inventory (same concurrent race as the main pipeline), sends
    /// to Claude with the verification system prompt, parses the verdict, and drives
    /// the controller accordingly.
    ///
    /// VERIFY tag handling:
    ///   - [VERIFY:done]: apply .stepVerifiedDone. The same response may also contain
    ///     a [STEP:n+1:...] tag for the next step — walkthrough tag parsing handles it.
    ///   - [VERIFY:retry:hint]: apply .stepNeedsRetry(hint:). The hint is already
    ///     embedded in the spoken text (it IS the spoken text after tag stripping).
    ///   - No VERIFY tag (graceful degradation): speak the response as a hint, then
    ///     apply .turnInterrupted to return from .verifying to .awaitingUserAction.
    ///     This prevents the walkthrough from being stranded in .verifying when Claude
    ///     omits the protocol tag (model drift, network truncation, etc.).
    func runWalkthroughVerificationTurn() {
        // FIX 5: perform bounds check BEFORE applying .userSignaledStepDone.
        // Previously, applying the event first moved the controller into .verifying
        // and then bailing on the guard left it stranded there — subsequent "I did it"
        // presses would trigger .userSignaledStepDone from .verifying (invalid) and
        // be silently dropped.
        let snapshotBeforeSignal = walkthroughController.currentSnapshot
        let currentStepIndex = snapshotBeforeSignal.currentStepIndex
        guard currentStepIndex < snapshotBeforeSignal.declaredSteps.count else {
            print("⚠️ Walkthrough: runWalkthroughVerificationTurn called with out-of-bounds step index — ignoring")
            return
        }
        // Safe to subscript directly — the guard above guarantees the index is valid
        // and WalkthroughStep is a non-optional value type.
        let currentStep = snapshotBeforeSignal.declaredSteps[currentStepIndex]

        // Bounds are valid — now signal step done and transition to .verifying.
        walkthroughController.apply(event: .userSignaledStepDone)

        let stepListForPrompt = snapshotBeforeSignal.declaredSteps

        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        pendingWalkthroughStepAfterTTS = nil

        currentResponseTask = Task {
            voiceState = .processing

            do {
                let (screenCaptures, inventory) = try await captureScreenshotsAndInventory()
                // FIX 4: inventoryForCurrentInteraction is now assigned inside
                // captureScreenshotsAndInventory() — no manual assignment needed here.

                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let supplementalInventoryTextBlock: String? = Self.buildSupplementalInventoryTextBlock(
                    inventory: inventory,
                    cursorScreenCapture: screenCaptures.first(where: { $0.isCursorScreen })
                )

                let verificationSystemPrompt = Self.walkthroughVerificationSystemPrompt(
                    stepList: stepListForPrompt,
                    currentStep: currentStep
                )

                // Verification turns do NOT use conversationHistory — the full step
                // context is carried in the system prompt itself (so truncation cannot
                // lose it). The conversation history window is for user-Claude dialogue;
                // the verification turn is a protocol exchange, not a conversation turn.
                //
                // Provider switch: same logic as sendTranscriptToClaudeWithScreenshot —
                // use OpenRouter when llm.json specifies "openrouter", Ollama when it
                // specifies "ollama", or fall back to Claude. Walkthroughs use the same
                // locally-configured vision model as normal turns for consistency.
                let verificationLLMProviderConfig = LLMProviderConfiguration.loadFromDisk()

                let fullResponseText: String
                if let openRouterVerificationConfig = verificationLLMProviderConfig,
                   openRouterVerificationConfig.usesOpenRouter {
                    print("🔀 Walkthrough verification using OpenRouter provider — model: \(openRouterVerificationConfig.model)")
                    fullResponseText = try await openRouterAPI.analyzeImage(
                        images: labeledImages,
                        systemPrompt: verificationSystemPrompt,
                        conversationHistory: [],
                        userPrompt: "please verify whether I completed the current step",
                        supplementalContextText: supplementalInventoryTextBlock,
                        apiKey: openRouterVerificationConfig.apiKey,
                        model: openRouterVerificationConfig.model
                    )
                } else if let ollamaVerificationConfig = verificationLLMProviderConfig,
                          ollamaVerificationConfig.usesOllama {
                    // Local Ollama path — no API key, long timeouts for cold-start inference.
                    print("🦙 Walkthrough verification using Ollama provider — model: \(ollamaVerificationConfig.model)")
                    fullResponseText = try await ollamaAPI.analyzeImage(
                        images: labeledImages,
                        systemPrompt: verificationSystemPrompt,
                        conversationHistory: [],
                        userPrompt: "please verify whether I completed the current step",
                        supplementalContextText: supplementalInventoryTextBlock,
                        model: ollamaVerificationConfig.model
                    )
                } else {
                    // Default path: Claude via Cloudflare Worker proxy (streaming).
                    let (claudeVerificationResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: verificationSystemPrompt,
                        conversationHistory: [],
                        userPrompt: "please verify whether I completed the current step",
                        supplementalContextText: supplementalInventoryTextBlock,
                        onTextChunk: { _ in }
                    )
                    fullResponseText = claudeVerificationResponseText
                }

                guard !Task.isCancelled else { return }

                // --- Parse annotation tags first (same parse-order contract as main pipeline) ---
                annotationsParsedFromCurrentResponse = []
                let annotationParseResult = AnnotationTagParser.parseAnnotationTags(from: fullResponseText)
                annotationsParsedFromCurrentResponse = annotationParseResult.annotations
                resolvedScreenAnnotations = Self.resolveAnnotationsToScreenRects(
                    parsedAnnotations: annotationParseResult.annotations,
                    inventory: inventoryForCurrentInteraction,
                    screenCaptures: screenCaptures,
                    allScreenFramesInAppKitCoordinates: NSScreen.screens.map { $0.frame }
                )

                // --- Parse walkthrough tags (next step may be in this response) ---
                let walkthroughParseResult = WalkthroughTagParser.parseWalkthroughTags(
                    from: annotationParseResult.strippedText
                )
                if let nextStep = walkthroughParseResult.step {
                    pendingWalkthroughStepAfterTTS = WalkthroughStep(stepNumber: nextStep.stepNumber, instruction: nextStep.instruction)
                }

                // --- Parse the verification verdict ---
                let verdictParseResult = WalkthroughTagParser.parseVerificationVerdict(
                    from: walkthroughParseResult.strippedText
                )

                // --- Strip action tags from the verification response (FIX 10) ---
                // Verification responses should not contain CLICK/TYPE tags, but if
                // Claude emits them (model drift, prompt bleed) they would be spoken
                // aloud by TTS and saved to conversation history without this step.
                //
                // We use ActionTagParser.parseActionTags directly (strip-only) rather
                // than routing through processActionTagsAndEnqueue, because that
                // function's in-flight guard prepends "still working on the previous
                // action — " to the return value when isActionCurrentlyRunning is true.
                // In a verification turn that prefix would corrupt the spoken verdict
                // and the conversation history entry. Tags are simply discarded here —
                // a verification turn must never enqueue act-mode actions.
                let verificationResponseAfterActionTagStripping = ActionTagParser.parseActionTags(
                    from: verdictParseResult.strippedText
                ).strippedText

                // Annotations + walkthrough + verify + action tags all stripped; POINT still present.
                let pointParseResult = Self.parsePointingCoordinates(from: verificationResponseAfterActionTagStripping)
                let spokenText = pointParseResult.spokenText

                // --- Resolve pointing for the verification response ---
                if let targetElementID = pointParseResult.elementID,
                   let resolvedLocation = Self.resolveElementIDToAppKitCenter(
                       elementID: targetElementID,
                       inventory: inventoryForCurrentInteraction,
                       allScreenFramesInAppKitCoordinates: NSScreen.screens.map { $0.frame }
                   ) {
                    voiceState = .idle
                    let elementScreenFrame = Self.findScreenFrameContainingOrNearestToPoint(
                        point: resolvedLocation,
                        allScreenFramesInAppKitCoordinates: NSScreen.screens.map { $0.frame }
                    )
                    detectedElementScreenLocation = resolvedLocation
                    detectedElementDisplayFrame = elementScreenFrame
                    if let label = pointParseResult.elementLabel {
                        detectedElementBubbleText = label
                    }
                } else if let pointCoordinate = pointParseResult.coordinate {
                    voiceState = .idle
                    if let capture = screenCaptures.first(where: { $0.isCursorScreen }) {
                        let globalLocation = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
                            screenshotPixelPoint: pointCoordinate,
                            screenshotWidthInPixels: CGFloat(capture.screenshotWidthInPixels),
                            screenshotHeightInPixels: CGFloat(capture.screenshotHeightInPixels),
                            displayWidthInPoints: CGFloat(capture.displayWidthInPoints),
                            displayHeightInPoints: CGFloat(capture.displayHeightInPoints),
                            displayFrameInAppKitCoordinates: capture.displayFrame
                        )
                        detectedElementScreenLocation = globalLocation
                        detectedElementDisplayFrame = capture.displayFrame
                    }
                }

                // Append the verification exchange to history (stripped text only).
                // The step list rides in the system prompt for future verification turns
                // so history truncation is safe.
                conversationHistory.append((
                    userTranscript: "done",
                    assistantResponse: spokenText
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                // --- Apply the verdict to the controller ---
                switch verdictParseResult.verdict {

                case .done:
                    // Play TTS first so the user hears the result before the controller
                    // advances. The next step (if any) is handled by pendingWalkthroughStepAfterTTS.
                    await speakResponse(spokenText)
                    // Capture the step number before the controller advances (it
                    // increments currentStepIndex on stepVerifiedDone).
                    let completedStepNumber = walkthroughController.currentSnapshot.currentStepIndex + 1
                    let verifyDoneEffect = walkthroughController.apply(event: .stepVerifiedDone)
                    if verifyDoneEffect == .announceCompletion {
                        // The walkthrough reached its last step — fire completed analytics.
                        ClickyAnalytics.trackWalkthroughCompleted(
                            totalSteps: walkthroughController.currentSnapshot.totalStepCount
                        )
                        // Walkthrough is now inactive — resume normal transient behaviour.
                        scheduleTransientHideIfNeeded()
                        print("📋 Walkthrough complete!")
                    } else {
                        // Mid-walkthrough step advance.
                        ClickyAnalytics.trackWalkthroughStepAdvanced(stepNumber: completedStepNumber)
                    }
                    // If there is a next step in this response, wait for TTS to finish
                    // then apply stepPresented so the controller reaches awaitingUserAction.
                    // Use the shared helper to avoid try?-swallowed cancellation and
                    // to apply the 30s ceiling against a stuck isPlaying flag.
                    if let stepToPresent = pendingWalkthroughStepAfterTTS {
                        await waitForTTSPlaybackToFinish()
                        if !Task.isCancelled {
                            pendingWalkthroughStepAfterTTS = nil
                            walkthroughController.apply(event: .stepPresented(step: WalkthroughStep(
                                stepNumber: stepToPresent.stepNumber,
                                instruction: stepToPresent.instruction
                            )))
                            // Snapshot the new step's annotations for the same
                            // restore-after-help-turn mechanism as the main pipeline.
                            stepAnnotationsForActiveWalkthrough = resolvedScreenAnnotations
                            print("📋 Walkthrough step \(stepToPresent.stepNumber) presented after verification")
                        }
                    }

                case .retry(let hint):
                    // Speak the full response (hint already in spokenText after stripping).
                    // The speakRetryHint effect from the controller is informational here.
                    await speakResponse(spokenText)
                    // Apply the retry and track analytics. newRetryCount is read from
                    // the snapshot AFTER the transition — the controller increments it.
                    walkthroughController.apply(event: .stepNeedsRetry(hint: hint))
                    let retryStepNumber = walkthroughController.currentSnapshot.currentStepIndex + 1
                    let retryCount = walkthroughController.currentSnapshot.retryCountForCurrentStep
                    ClickyAnalytics.trackWalkthroughStepRetried(
                        stepNumber: retryStepNumber,
                        retryCount: retryCount
                    )
                    // Restore the step's visual anchor so the user still sees the
                    // annotation for the step they need to redo.
                    if !stepAnnotationsForActiveWalkthrough.isEmpty {
                        resolvedScreenAnnotations = stepAnnotationsForActiveWalkthrough
                    }
                    print("📋 Walkthrough step retry: \(hint)")

                case nil:
                    // No [VERIFY:...] tag found — graceful degradation path.
                    // Speak the response as a plain hint, then apply .turnInterrupted so
                    // the controller returns from .verifying to .awaitingUserAction.
                    await speakResponse(spokenText)
                    walkthroughController.apply(event: .turnInterrupted)
                    print("📋 Walkthrough: no VERIFY tag — applied turnInterrupted (graceful degradation)")
                }

            } catch is CancellationError {
                // PTT pressed during verification — turnInterrupted already applied in
                // handleShortcutTransition before the task was cancelled.
            } catch {
                print("⚠️ Walkthrough verification error: \(error)")
                walkthroughController.apply(event: .turnInterrupted)
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Cancels the active walkthrough from the panel's Cancel button.
    ///
    /// Stops any in-flight TTS and API response, applies .userCancelled to the
    /// controller (which emits .announceCancellation), and speaks a brief
    /// acknowledgement via NSSpeechSynthesizer (no API call needed for cancel).
    ///
    /// Cancellation via spoken intent is NOT routed here in v1 — the panel button
    /// is the canonical cancel entry point. Spoken "cancel" utterances during
    /// awaitingUserAction are treated as help turns. This is documented as a v1
    /// limitation; v2 could add "cancel" to a separate classifier.
    func cancelActiveWalkthrough() {
        guard walkthroughController.phase != .inactive else { return }

        // Track the step we're on before the controller resets to inactive.
        let cancelledAtStepNumber = walkthroughController.currentSnapshot.currentStepIndex + 1

        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        pendingWalkthroughStepAfterTTS = nil

        let effect = walkthroughController.apply(event: .userCancelled)

        if effect == .announceCancellation {
            // Speak via system TTS — no API call needed, keeps cancel snappy.
            let synthesizer = NSSpeechSynthesizer()
            synthesizer.startSpeaking("ok, walkthrough cancelled")
        }

        // Use the full-clear variant so both pointing state AND step annotations
        // are wiped — clearDetectedElementLocation() would preserve annotations
        // because the phase was still active at call time.
        clearAllStepVisuals()

        ClickyAnalytics.trackWalkthroughCancelled(atStep: cancelledAtStepNumber)
        print("📋 Walkthrough cancelled by user at step \(cancelledAtStepNumber)")

        // Walkthrough is now inactive — resume normal transient-cursor behaviour
        // in case the user had "Show Clicky" off.
        scheduleTransientHideIfNeeded()
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate from a [POINT:x,y:...] tag, or nil when an
        /// element-ID tag is used or Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        /// Only populated for the legacy pixel-coordinate form.
        let screenNumber: Int?
        /// The AX element ID parsed from a [POINT:E<digits>:...] tag (e.g. 12 for E12),
        /// or nil when the legacy pixel-coordinate or [POINT:none] form was used.
        let elementID: Int?
    }

    /// Parses a [POINT:...] tag from the end of Claude's response. Supports three forms:
    ///
    ///   [POINT:x,y:label:screenN]   — legacy pixel-coordinate form (R3 fallback)
    ///   [POINT:E<digits>:label]     — element-ID form (R2 grounded pointing)
    ///   [POINT:none]                — no pointing
    ///
    /// The tag must appear at the very end of the response (end-anchored) so that a
    /// stray "[POINT:..." inside spoken text is never mistaken for a pointing instruction.
    ///
    /// Returns the spoken text with the tag stripped plus the parsed pointing data.
    ///
    /// LEGACY REGEX BEHAVIOR (hard regression boundary)
    /// ─────────────────────────────────────────────────
    /// The legacy regex accepts:
    ///   - [POINT:none]                 → coordinate nil, elementLabel "none"
    ///   - [POINT:123,456]              → coordinate (123,456), label nil
    ///   - [POINT:123,456:label]        → coordinate (123,456), label "label"
    ///   - [POINT:123,456:label:screen2]→ coordinate (123,456), label "label", screen 2
    /// The label capture group [^\]:\s][^\]:]*? means the label must not start with
    /// whitespace or ':' or ']', and must not contain ']' or ':'. This rejects e.g.
    /// [POINT:abc] (no comma → falls to "none" branch → also no x/y → returns none-result).
    /// A tag NOT at the end (e.g. mid-sentence) is silently ignored.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {

        // --- Step 1: Try the legacy pixel-coordinate / none form (end-anchored) ---
        // Matches [POINT:none] OR [POINT:123,456:optional-label:optional-screenN]
        let legacyPattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        if let legacyRegex = try? NSRegularExpression(pattern: legacyPattern, options: []),
           let match = legacyRegex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) {

            // Remove the tag from spoken text
            let tagRange = Range(match.range, in: responseText)!
            let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Determine if it matched [POINT:none] or the pixel-coordinate form.
            // Capture group 1 (x) and group 2 (y) are nil for the [POINT:none] branch.
            guard match.numberOfRanges >= 3,
                  let xRange = Range(match.range(at: 1), in: responseText),
                  let yRange = Range(match.range(at: 2), in: responseText),
                  let x = Double(responseText[xRange]),
                  let y = Double(responseText[yRange]) else {
                // [POINT:none] branch — no coordinate, no element ID
                return PointingParseResult(
                    spokenText: spokenText,
                    coordinate: nil,
                    elementLabel: "none",
                    screenNumber: nil,
                    elementID: nil
                )
            }

            var elementLabel: String? = nil
            if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
                elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
            }

            var screenNumber: Int? = nil
            if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
                screenNumber = Int(responseText[screenRange])
            }

            return PointingParseResult(
                spokenText: spokenText,
                coordinate: CGPoint(x: x, y: y),
                elementLabel: elementLabel,
                screenNumber: screenNumber,
                elementID: nil
            )
        }

        // --- Step 2: Try the element-ID form [POINT:E<digits>] or [POINT:E<digits>:label] ---
        // End-anchored just like the legacy form. The label may contain spaces but
        // not ']' (which would close the tag). No screenN suffix — element IDs resolve
        // to the element's own screen via inventory lookup, no screen hint needed.
        let elementIDPattern = #"\[POINT:E(\d+)(?::([^\]]*))?\]\s*$"#

        if let elementIDRegex = try? NSRegularExpression(pattern: elementIDPattern, options: []),
           let match = elementIDRegex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) {

            // Remove the tag from spoken text
            let tagRange = Range(match.range, in: responseText)!
            let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Capture group 1 is always present when this branch matches (it's the \d+ digits)
            guard let idRange = Range(match.range(at: 1), in: responseText),
                  let parsedElementID = Int(responseText[idRange]) else {
                // Malformed — treat as no tag
                return PointingParseResult(
                    spokenText: responseText,
                    coordinate: nil,
                    elementLabel: nil,
                    screenNumber: nil,
                    elementID: nil
                )
            }

            var elementLabel: String? = nil
            if match.numberOfRanges >= 3, let labelRange = Range(match.range(at: 2), in: responseText) {
                let trimmedLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                if !trimmedLabel.isEmpty {
                    elementLabel = trimmedLabel
                }
            }

            return PointingParseResult(
                spokenText: spokenText,
                coordinate: nil,
                elementLabel: elementLabel,
                screenNumber: nil,
                elementID: parsedElementID
            )
        }

        // --- Step 3: No recognised tag found ---
        return PointingParseResult(
            spokenText: responseText,
            coordinate: nil,
            elementLabel: nil,
            screenNumber: nil,
            elementID: nil
        )
    }

    // MARK: - Supplemental Inventory Text Block Builder

    /// Builds the supplemental AX inventory text block to append to a Claude message,
    /// or returns nil when no inventory is available.
    ///
    /// The block consists of:
    ///   1. A one-line header naming the frontmost app and describing the coordinate
    ///      space so Claude can cross-check the list against the screenshot images.
    ///   2. The formatted element lines from `AccessibilityElementInventoryService.formatInventoryForPrompt`.
    ///
    /// Returns nil when:
    ///   - `inventory` is nil (no walk completed in time and no previous walk is cached)
    ///   - The inventory's element list is empty (stub AX tree, AX-less app)
    ///
    /// Returning nil results in a message shape identical to before U4 — no extra
    /// block is added, so legacy behaviour is fully preserved for AX-less apps.
    ///
    /// This is a pure static function so it is directly unit-testable without
    /// constructing a CompanionManager or making any API calls.
    ///
    /// - Parameters:
    ///   - inventory: The AX inventory to format, or nil when none is available.
    ///   - cursorScreenCapture: The screen capture for the display where the
    ///     cursor lives. Its pixel dimensions are used to convert element AppKit
    ///     frames to the same coordinate space as the screenshot images. When nil
    ///     (no cursor-screen capture found) the function returns nil — without
    ///     the pixel dimensions we cannot guarantee the coordinate spaces match.
    /// - Returns: A formatted multi-line string ready to inject as a supplemental
    ///   text block, or nil when no inventory is available.
    static func buildSupplementalInventoryTextBlock(
        inventory: AccessibilityElementInventory?,
        cursorScreenCapture: CompanionScreenCapture?
    ) -> String? {
        guard let inventory,
              !inventory.elements.isEmpty,
              let cursorCapture = cursorScreenCapture else {
            // No inventory, empty tree, or no cursor-screen capture —
            // return nil so no extra block is added to the message.
            return nil
        }

        let formattedElementLines = AccessibilityElementInventoryService.formatInventoryForPrompt(
            elements: inventory.elements,
            screenshotWidthInPixels: cursorCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: cursorCapture.screenshotHeightInPixels,
            displayFrameInAppKitCoordinates: cursorCapture.displayFrame
        )

        guard !formattedElementLines.isEmpty else {
            // formatInventoryForPrompt returns an empty string for an empty list —
            // guard here in case the element list became empty after filtering.
            return nil
        }

        // Header line names the app and states the coordinate space so Claude
        // knows these frames are in the same pixel space as the screenshots.
        let headerLine = "Interactive elements of the frontmost app (\(inventory.frontmostAppName)), frames in the screenshot's pixel coordinate space:"

        return "\(headerLine)\n\(formattedElementLines)"
    }

    // MARK: - Walkthrough Verification System Prompt Builder

    /// Builds the system prompt for a walkthrough verification turn.
    ///
    /// A verification turn is a fresh Claude call that receives a new screenshot
    /// + AX inventory and must return either [VERIFY:done] (step completed) or
    /// [VERIFY:retry:<hint>] (step not completed). The step list travels in this
    /// system prompt so conversation-history truncation cannot lose it — the
    /// history only carries stripped spoken text (10-exchange window), but the
    /// step context is always present in the system prompt for every verification
    /// turn regardless of where in the walkthrough we are.
    ///
    /// The same casual lowercase voice rules as companionVoiceResponseSystemPrompt
    /// apply here — responses will be spoken aloud via TTS.
    ///
    /// This is a pure static function so it is directly unit-testable without
    /// constructing a CompanionManager or making any API calls.
    ///
    /// - Parameters:
    ///   - stepList: All steps declared so far in the walkthrough (accumulated in
    ///     WalkthroughStateSnapshot.declaredSteps). Used to give Claude full context
    ///     about the overall goal even when verifying a mid-walkthrough step.
    ///   - currentStep: The step whose completion is being verified in this turn.
    ///     Its instruction is highlighted explicitly so Claude knows exactly what
    ///     success looks like.
    /// - Returns: A system prompt string ready to pass to claudeAPI.analyzeImageStreaming.
    static func walkthroughVerificationSystemPrompt(
        stepList: [WalkthroughStep],
        currentStep: WalkthroughStep
    ) -> String {
        // Build a numbered list of all steps for context. Even steps not yet
        // reached help Claude understand the overall user goal.
        let stepListText = stepList.enumerated().map { _, step in
            "  step \(step.stepNumber): \(step.instruction)"
        }.joined(separator: "\n")

        return """
        you're clicky, a friendly always-on companion. you're verifying whether the user completed a walkthrough step. you can see their current screen and a live list of interactive elements.

        the full walkthrough:
        \(stepListText)

        you are verifying step \(currentStep.stepNumber): "\(currentStep.instruction)"

        look at the fresh screenshot and element inventory. did the user complete this step?

        if yes: reply [VERIFY:done] and — unless this was the last step — immediately present the next step with [STEP:\(currentStep.stepNumber + 1):<short instruction>] and a point/annotation. if it was the last step, just [VERIFY:done] and a brief warm congratulations (one sentence, no new step tag).

        if no: reply [VERIFY:retry:<specific corrective hint>] where the hint tells them exactly what to do differently. be specific — "you clicked sharing, go back and pick general" is better than "try again". the hint will be spoken aloud so keep it conversational and under 15 words.

        rules:
        - always lowercase, casual, warm. no emojis.
        - write for the ear — this will be spoken via text-to-speech.
        - the [VERIFY:...] tag can appear anywhere in your response. it does not need to be at the end.
        - for [VERIFY:retry:<hint>], the hint is everything after the second colon up to the closing bracket. it may contain commas but keep it short.
        - if you present the next step, follow the same pointing/annotation rules as normal (use element IDs from the inventory when available).
        - do not say "simply" or "just".
        """
    }

    // MARK: - ResolvedScreenAnnotation

    /// An annotation from Claude's response that has been resolved to an exact
    /// AppKit-global rect and is ready for a per-screen overlay view to render.
    ///
    /// The separation between `ParsedScreenAnnotation` (U5, raw parse output) and
    /// this type (U6, resolved output) keeps the parser pure: it never touches
    /// NSScreen or the inventory. Resolution happens here in CompanionManager
    /// where both the inventory and the screen list are available.
    struct ResolvedScreenAnnotation {
        /// The visual shape to draw.
        let kind: ScreenAnnotationKind
        /// The bounding rect of the target element or region, expressed in AppKit
        /// global coordinates (bottom-left origin of the primary display, points).
        /// Each per-screen BlueCursorView converts this to its own SwiftUI-local
        /// coordinate space using `convertAppKitGlobalRectToSwiftUILocalRect`.
        let rectInAppKitGlobalCoordinates: CGRect
        /// The display frame (AppKit global, NSScreen.frame) of the screen this
        /// annotation belongs to. Each BlueCursorView compares its own `screenFrame`
        /// against this value to decide whether to render this annotation.
        let displayFrameOfTargetScreen: CGRect
        /// Optional short label shown as a chip near the annotation shape.
        let label: String?
        /// FIX 12: True when this annotation was synthesised by the pending-action
        /// pipeline (publishPendingActionHighlight) rather than parsed from a Claude
        /// response. This stable identity field lets clearPendingActionHighlight()
        /// remove ONLY the pending-action highlight without touching any
        /// Claude-authored HIGHLIGHT annotations in the same array.
        ///
        /// Previously clearPendingActionHighlight() removed all entries whose kind
        /// is .highlight — which would incorrectly delete a Claude-authored HIGHLIGHT
        /// that happened to coexist with a pending-action turn.
        ///
        /// Default is false — all annotations created by the resolution pipeline are
        /// NOT pending-action highlights. Only publishPendingActionHighlight() sets
        /// this to true (in CompanionManager+PendingAction.swift).
        ///
        /// clearDetectedElementLocation() also reads this field: if the array contains
        /// a pending-action highlight it is preserved even on a non-walkthrough clear,
        /// mirroring the walkthrough-phase preservation logic for step annotations.
        let isPendingActionHighlight: Bool
    }

    /// Resolves a list of parsed annotations to their exact AppKit-global rects
    /// and screen assignments. This is a pure static function so it can be
    /// directly unit-tested without constructing a CompanionManager.
    ///
    /// Resolution rules:
    ///   - `.elementID` targets: look up the element in the inventory → use its
    ///     `appKitFrame`. If the inventory is nil or the ID is not found, the
    ///     annotation is dropped (never a zero-rect artifact).
    ///   - `.pixelRect` targets: convert the screenshot-pixel rect to AppKit
    ///     global using ScreenCoordinateConverter. The screen capture is selected
    ///     the same way as for pixel-form POINT: if a screenNumber is specified
    ///     and valid, use that capture; otherwise fall back to the cursor screen.
    ///     If no matching capture is found, the annotation is dropped.
    ///
    /// Screen assignment: each resolved annotation's `displayFrameOfTargetScreen`
    /// is the `displayFrame` of the screen capture (for pixel-rect targets) or the
    /// screen frame nearest to the element's AppKit-center (for element-ID targets).
    /// This mirrors the identical assignment logic used for POINT resolution.
    ///
    /// - Parameters:
    ///   - parsedAnnotations: The raw annotations from `AnnotationTagParser`.
    ///   - inventory: The AX inventory for the current interaction, or nil when
    ///     none was available (AX walk timed out, AX-less app, etc.).
    ///   - screenCaptures: All screen captures for this interaction, in the same
    ///     order as they were passed to Claude (1-based screen numbers).
    ///   - allScreenFramesInAppKitCoordinates: `NSScreen.screens.map { $0.frame }`,
    ///     passed as a parameter so the function stays pure and testable.
    /// - Returns: The resolved annotations, in the same order as the input list
    ///   (annotations that could not be resolved are simply absent from the output).
    static func resolveAnnotationsToScreenRects(
        parsedAnnotations: [ParsedScreenAnnotation],
        inventory: AccessibilityElementInventory?,
        screenCaptures: [CompanionScreenCapture],
        allScreenFramesInAppKitCoordinates: [CGRect]
    ) -> [ResolvedScreenAnnotation] {

        var resolvedAnnotations: [ResolvedScreenAnnotation] = []

        for parsedAnnotation in parsedAnnotations {
            switch parsedAnnotation.target {

            case .elementID(let elementID):
                // Element-ID resolution: look up the element's AppKit frame from
                // the inventory captured for this interaction. Unknown IDs are
                // dropped — never produce a (0,0) annotation.
                guard let inventory else {
                    // No inventory available for this turn — drop this annotation.
                    continue
                }
                guard let matchingElement = inventory.elements.first(where: { $0.elementID == elementID }) else {
                    // ID referenced by Claude but not present in the inventory —
                    // capped, hallucinated, or stale. Drop rather than misplace.
                    continue
                }

                // The element's appKitFrame is already in AppKit global coordinates;
                // no further conversion needed.
                let elementAppKitRect = matchingElement.appKitFrame
                let elementCenter = CGPoint(
                    x: elementAppKitRect.midX,
                    y: elementAppKitRect.midY
                )
                let targetScreenFrame = findScreenFrameContainingOrNearestToPoint(
                    point: elementCenter,
                    allScreenFramesInAppKitCoordinates: allScreenFramesInAppKitCoordinates
                )

                resolvedAnnotations.append(ResolvedScreenAnnotation(
                    kind: parsedAnnotation.kind,
                    rectInAppKitGlobalCoordinates: elementAppKitRect,
                    displayFrameOfTargetScreen: targetScreenFrame,
                    label: parsedAnnotation.label,
                    isPendingActionHighlight: false // Claude-authored annotation, not a pending-action highlight
                ))

            case .pixelRect(let screenshotPixelRect, let screenNumber):
                // Pixel-rect resolution: same screen-selection logic as POINT pixel form.
                // screenNumber is 1-based; nil means the cursor screen.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber,
                       screenNumber >= 1,
                       screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                guard let captureForThisAnnotation = targetScreenCapture else {
                    // No matching screen capture — drop the annotation.
                    continue
                }

                // Convert the rect origin (top-left in screenshot-pixel space)
                // to AppKit global using the same converter as point conversion.
                // We convert the origin and the opposite corner separately so we
                // can use the existing point converter, then reconstruct the rect.
                let displayFrame = captureForThisAnnotation.displayFrame
                let screenshotWidth = CGFloat(captureForThisAnnotation.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(captureForThisAnnotation.screenshotHeightInPixels)
                let displayWidth = CGFloat(captureForThisAnnotation.displayWidthInPoints)
                let displayHeight = CGFloat(captureForThisAnnotation.displayHeightInPoints)

                // Scale the rect from screenshot-pixel space to AppKit global.
                // We scale origin + size directly (no Y flip on size), then apply
                // the full point conversion to the rect using the dedicated rect
                // helper which handles the bottom-left origin adjustment correctly.
                let scaleX = displayWidth / screenshotWidth
                let scaleY = displayHeight / screenshotHeight

                // Scale to display-point space (still top-left origin, display-local)
                let displayLocalX = screenshotPixelRect.origin.x * scaleX
                let displayLocalY = screenshotPixelRect.origin.y * scaleY
                let displayLocalWidth = screenshotPixelRect.width * scaleX
                let displayLocalHeight = screenshotPixelRect.height * scaleY

                // Flip Y from top-left (display-local) to bottom-left (AppKit display-local):
                // AppKit rect origin is at the bottom-left edge of the rect, so
                // appKitLocalY = displayHeight - (displayLocalY + height).
                let appKitLocalY = displayHeight - (displayLocalY + displayLocalHeight)

                // Translate from display-local to AppKit global by adding the
                // display's origin offset. For the primary display this is (0,0);
                // for secondary displays it reflects the user's Displays arrangement.
                let appKitGlobalRect = CGRect(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitLocalY + displayFrame.origin.y,
                    width: displayLocalWidth,
                    height: displayLocalHeight
                )

                resolvedAnnotations.append(ResolvedScreenAnnotation(
                    kind: parsedAnnotation.kind,
                    rectInAppKitGlobalCoordinates: appKitGlobalRect,
                    displayFrameOfTargetScreen: displayFrame,
                    label: parsedAnnotation.label,
                    isPendingActionHighlight: false // Claude-authored annotation, not a pending-action highlight
                ))
            }
        }

        return resolvedAnnotations
    }

    // MARK: - Element-ID Resolution Helpers

    /// Looks up an element ID in the given inventory and returns the element's
    /// center point in AppKit global coordinates, or nil if the inventory is nil
    /// or the ID is not found.
    ///
    /// Why return the AppKit center: the overlay pipeline publishes AppKit global
    /// coordinates to `detectedElementScreenLocation`. The element's `appKitFrame`
    /// is already in that space (converted during the AX walk by
    /// `ScreenCoordinateConverter.convertCGGlobalRectToAppKitGlobalRect`), so we
    /// read it directly without any further conversion.
    ///
    /// Why this is static: pure function over value types — no NSScreen side
    /// effects, callable from any thread, and directly unit-testable.
    ///
    /// - Parameters:
    ///   - elementID: The integer from `[POINT:E<id>:...]`, e.g. 12 for E12.
    ///   - inventory: The inventory captured for the current interaction. Pass nil
    ///     when no inventory was available (AX walk timed out or not yet wired).
    ///   - allScreenFramesInAppKitCoordinates: NSScreen.screens.map { $0.frame },
    ///     passed as a parameter so the function remains pure and testable without
    ///     a display attached. Used only for the screen-assignment helper called by
    ///     the resolution site; not needed by this function itself.
    /// - Returns: The center of the element's AppKit frame, or nil when the element
    ///   cannot be resolved (nil inventory, or ID not found in the element list).
    static func resolveElementIDToAppKitCenter(
        elementID: Int,
        inventory: AccessibilityElementInventory?,
        allScreenFramesInAppKitCoordinates: [CGRect]
    ) -> CGPoint? {
        guard let inventory else {
            // No inventory available for this interaction — caller treats this
            // exactly like [POINT:none]: speak the response, skip pointing.
            return nil
        }

        guard let matchingElement = inventory.elements.first(where: { $0.elementID == elementID }) else {
            // ID was present in Claude's response but is not in the inventory.
            // Could happen if the inventory was capped before this element, or if
            // Claude hallucinated an ID. Either way, never point at (0,0).
            return nil
        }

        // The center of the AppKit-global frame is the exact point the overlay
        // should fly to. AppKit frame origin is the bottom-left corner, so the
        // center is (origin.x + width/2, origin.y + height/2).
        let centerX = matchingElement.appKitFrame.origin.x + matchingElement.appKitFrame.width / 2
        let centerY = matchingElement.appKitFrame.origin.y + matchingElement.appKitFrame.height / 2
        return CGPoint(x: centerX, y: centerY)
    }

    /// Returns the screen frame (in AppKit global coordinates) that contains the
    /// given point, or the frame of the nearest screen when no screen contains it.
    ///
    /// When to fall back to nearest: an element's frame center might lie outside
    /// all screen frames if the screen was unplugged between the AX walk and the
    /// render, or if the element straddles a display boundary. Rather than dropping
    /// the point entirely, we use the nearest screen so the cursor still flies
    /// somewhere sensible.
    ///
    /// Distance metric: the distance from `point` to the closest point within
    /// each screen's frame. For a point already inside a frame that distance is
    /// zero, so "contains" is naturally expressed by the same metric.
    ///
    /// Why the screens are passed as a parameter: this makes the function pure and
    /// testable without NSScreen — the caller passes `NSScreen.screens.map { $0.frame }`.
    ///
    /// - Parameters:
    ///   - point: A point in AppKit global coordinates (e.g. an element's AppKit center).
    ///   - allScreenFramesInAppKitCoordinates: The AppKit frames of all connected
    ///     displays (NSScreen.screens.map { $0.frame }).
    /// - Returns: The screen frame that contains the point, or the nearest screen
    ///   frame if no screen contains it. Returns `.zero` only if the screen list is empty
    ///   (which cannot happen on a running macOS system with at least one display).
    static func findScreenFrameContainingOrNearestToPoint(
        point: CGPoint,
        allScreenFramesInAppKitCoordinates: [CGRect]
    ) -> CGRect {
        guard !allScreenFramesInAppKitCoordinates.isEmpty else {
            // Defensive: a running macOS system always has at least one screen.
            return .zero
        }

        // Find the screen that contains the point exactly, or if none does,
        // the screen whose nearest boundary is closest to the point.
        var nearestScreenFrame = allScreenFramesInAppKitCoordinates[0]
        var smallestDistanceToNearestBoundary = distanceFromPointToNearestEdgeOfRect(
            point: point,
            rect: allScreenFramesInAppKitCoordinates[0]
        )

        for screenFrame in allScreenFramesInAppKitCoordinates.dropFirst() {
            let distanceToThisScreen = distanceFromPointToNearestEdgeOfRect(
                point: point,
                rect: screenFrame
            )
            if distanceToThisScreen < smallestDistanceToNearestBoundary {
                smallestDistanceToNearestBoundary = distanceToThisScreen
                nearestScreenFrame = screenFrame
            }
        }

        return nearestScreenFrame
    }

    /// Computes the distance from `point` to the closest point within `rect`.
    /// Returns 0.0 when the point is inside or on the boundary of the rect.
    ///
    /// This is a support function for `findScreenFrameContainingOrNearestToPoint`.
    /// It is private because it is an implementation detail of screen assignment
    /// and has no independent use in the rest of the file.
    private static func distanceFromPointToNearestEdgeOfRect(
        point: CGPoint,
        rect: CGRect
    ) -> CGFloat {
        // Clamp the point into the rect: if the point is inside, the clamped
        // point equals the original and the distance is 0.
        let clampedX = max(rect.minX, min(point.x, rect.maxX))
        let clampedY = max(rect.minY, min(point.y, rect.maxY))
        let deltaX = point.x - clampedX
        let deltaY = point.y - clampedY
        return sqrt(deltaX * deltaX + deltaY * deltaY)
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                // Same screenshot-pixel→AppKit conversion as the main pipeline.
                // ScreenCoordinateConverter centralises the clamping, ratio-scaling,
                // Y-flip, and displayFrame.origin offset so the two call sites stay
                // bit-identical without duplicating the logic.
                let displayFrame = cursorScreenCapture.displayFrame
                let globalLocation = ScreenCoordinateConverter.convertScreenshotPixelPointToAppKitGlobalPoint(
                    screenshotPixelPoint: pointCoordinate,
                    screenshotWidthInPixels: CGFloat(cursorScreenCapture.screenshotWidthInPixels),
                    screenshotHeightInPixels: CGFloat(cursorScreenCapture.screenshotHeightInPixels),
                    displayWidthInPoints: CGFloat(cursorScreenCapture.displayWidthInPoints),
                    displayHeightInPoints: CGFloat(cursorScreenCapture.displayHeightInPoints),
                    displayFrameInAppKitCoordinates: displayFrame
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
