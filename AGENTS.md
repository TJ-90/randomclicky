# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Act-Mode Confirmation Panel is the ONE Focus Exception**: Every Clicky surface is non-activating by design — the menu bar panel, cursor overlay, and all annotation shapes deliberately never steal keyboard focus so the user's work is never interrupted. The act-mode confirmation panel (Phase D, U11) is the single intentional exception: it uses a `.nonactivatingPanel` style that becomes key without activating the Clicky app so Return confirms and Esc cancels without leaking keystrokes into the target app. This exception is necessary because the existing listen-only CGEvent tap cannot swallow events — confirmation via the tap would leak Return into whatever text field the user has focused. The panel's key acquisition is limited to the confirmation window; on dismiss, focus returns to the previously active app.

**Act-Mode Conventions (Phase D)**: Act mode is OFF by default (R14) and toggled from the panel. The system prompt's CLICK/TYPE grammar paragraph is appended only when act mode is on — `CompanionManager.companionVoiceResponseSystemPrompt(actModeEnabled:)` is a pure static function checked at request time. Actions use element IDs only (no pixel-coordinate form): `[CLICK:E<id>:description]` / `[TYPE:E<id>:text:description]`. TYPE payloads must never contain newlines or control characters, and must NEVER appear in any analytics payload — enforced at the `ClickyAnalytics.buildActionEventProperties` signature level (no typed-text parameter exists). Every action requires explicit per-action user confirmation before execution.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~2595 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot + AX inventory walk (concurrent, 1.5s timeout) → Claude → TTS → pointing + annotation pipeline. Supports AX-grounded pointing and multi-shape annotations: element IDs from the inventory resolve to exact on-screen centers/rects; pixel-coordinate form is the fallback for AX-less apps. Publishes `resolvedScreenAnnotations: [ResolvedScreenAnnotation]`. `clearDetectedElementLocation()` preserves step annotations during active walkthrough phases (.awaitingUserAction/.presentingStep); `clearAllStepVisuals()` does a full unconditional clear (used on walkthrough end/cancel). Stores `stepAnnotationsForActiveWalkthrough` snapshot so step visuals restore after a help turn. `scheduleTransientHideIfNeeded()` is suppressed while `walkthroughController.phase != .inactive` (buddy stays visible mid-walkthrough). Implements guided walkthrough turn orchestration (U8/U9): routes PTT transcripts, runs `runWalkthroughVerificationTurn()`, exposes `cancelActiveWalkthrough()`. U12: publishes `isActModeEnabledPublished` and `accessibilityHealthState`; `companionVoiceResponseSystemPrompt(actModeEnabled:)` is a pure static func that appends the CLICK/TYPE grammar only when act mode is on; `performAccessibilityHealthSelfCheck()` runs once at launch. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~1108 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Includes the active-walkthrough section (step progress badge, "I did it" button, "Cancel walkthrough" button) visible while `walkthroughController.phase != .inactive`. U12: act-mode toggle section (ACT MODE header, toggle bound to `isActModeEnabledPublished`, explanatory copy); stale-TCC hint row in the accessibility permission row when `accessibilityHealthState == .staleGrantNeedsReToggle`. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~1013 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, spinner, annotation shapes, and walkthrough step chip. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, fade-out transitions, and annotation rendering via `AnnotationLayerView`. Includes `WalkthroughStepChipView` as a persistent ZStack layer cross-faded by `walkthroughController.phase`. Includes `convertAppKitGlobalRectToSwiftUILocalRect` helper. |
| `CompanionResponseOverlay.swift` | ~405 | SwiftUI view for the response text bubble displayed next to the cursor in the overlay. Also hosts `WalkthroughStepChipView` — the persistent chip near the buddy cursor showing "Step N of M — instruction" during active walkthroughs, with a "checking…" ellipsis affordance during .verifying. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~347 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. Accepts an optional `supplementalContextText` parameter to inject the AX element inventory as a text block after images. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `AccessibilityElementInventoryService.swift` | ~1035 | Bounded, non-blocking AX walk that enumerates actionable elements in the frontmost window on a dedicated serial queue. Returns `AccessibilityElementInventory` with per-element CG and AppKit frames. |
| `AnnotationTagParser.swift` | ~461 | Pure static scanning parser for multi-shape screen annotation tags (BOX, CIRCLE, ARROW, HIGHLIGHT). Strips all annotation tags from response text before the end-anchored POINT parser runs; malformed tags are stripped silently. Returns `[ParsedScreenAnnotation]` and the tag-free spoken text. |
| `AnnotationOverlayViews.swift` | ~210 | SwiftUI shape views for annotation rendering: BoxAnnotationView, CircleAnnotationView, ArrowAnnotationView (custom `AnnotationArrowShape`), HighlightAnnotationView, and the `AnnotationLayerView` container. Pure presentation — receives pre-converted SwiftUI-local rects from BlueCursorView and renders DS-token-styled shapes with fade/scale-in transitions. Never inserted/removed from ZStack — cross-fades by opacity. |
| `WalkthroughTagParser.swift` | ~330 | Pure static scanning parser for walkthrough protocol tags. Parses `[WALKTHROUGH:<total>]` and `[STEP:<n>:<instruction>]` (greedy instruction, may contain colons) from Claude responses, strips them from spoken text, and collapses whitespace. Also parses `[VERIFY:done]` / `[VERIFY:retry:<hint>]` verdicts from verification turns (graceful nil on no tag), and classifies PTT transcripts against the done-signal word list via `transcriptMatchesDoneSignal(_:)`. |
| `WalkthroughController.swift` | ~435 | Pure value-semantic state machine for multi-step guided walkthrough lifecycle. Phases: inactive → presenting → awaitingUserAction → verifying → (back to presenting or inactive). Driven by events (walkthroughDeclared, stepPresented, userSignaledStepDone, userAskedForHelp, stepVerifiedDone, stepNeedsRetry, turnInterrupted, userCancelled, retryCapReached). Returns optional side-effect values (speakRetryHint, announceCompletion, announceCancellation, offerSkipOrCancelAfterRetryCap). No async, no UI — pure transition function for testability. |
| `ScreenCoordinateConverter.swift` | ~249 | Pure static coordinate-space converters: screenshot-pixels→AppKit-global, CG-global↔AppKit-global (points and rects), AppKit-global→screenshot-pixel. Used by both the pointing pipeline and the inventory prompt formatter. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~318 | PostHog analytics integration for usage tracking. Tracks AX inventory walk outcomes (element count, captured/timedOut/emptyTree/permissionUnavailable), element pointing method (element ID resolved vs pixel fallback vs ID lookup failed), and guided walkthrough lifecycle events (walkthroughStarted, stepAdvanced, stepRetried, completed, cancelled). U12: act-mode toggle events (actModeEnabled/actModeDisabled), action lifecycle events (trackActionProposed/Confirmed/Cancelled/Failed with target app bundle ID — no typed text). `buildActionEventProperties(actionKind:targetAppBundleID:)` is a pure testable builder that deliberately has no typed-text parameter, enforcing the privacy invariant at compile time. |
| `WindowPositionManager.swift` | ~332 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. U12: `AccessibilityHealthState` enum (healthy/staleGrantNeedsReToggle/notGranted) and `accessibilityHealthState(isProcessTrusted:trivialAXReadSucceeded:)` pure static decision function for the stale-TCC self-check. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `ActionExecutionService.swift` | ~1165 | Phase D act-mode execution primitive. Performs a click or type action on an AX-discovered element. Safety chain: hard refusals (secure field, secure input mode, control chars, denylisted processes) → pre-stage re-validation (stale handle or frame drift beyond epsilon → .staleTarget, nothing executes) → click chain (AXPress → CGEvent to PID → CGEvent to HID tap) → type chain (kAXValueAttribute set → CGEvent keyboard chunks). All AX calls run on the shared serial queue from AccessibilityElementInventoryService (never a second queue). Synthetic events are stamped with a magic userData value (0x434C4B59); `isClickySyntheticEvent(_:)` lets GlobalPushToTalkShortcutMonitor ignore them. User-activity sampler pauses synthetic input while the physical mouse/keyboard is active. Abort flag checked between every stage and every keyboard chunk. |
| `ActionTagParser.swift` | ~380 | Phase D (U11). Pure static scanning parser for CLICK and TYPE action tags emitted by Claude. Element-ID targets only — pixel-coordinate forms are rejected at parse time as the act-mode safety floor. Returns `ActionTagParseResult` with parsed actions in document order and all action tags stripped from the spoken text. |
| `PendingActionStateMachine.swift` | ~215 | Phase D (U11). Pure static state-transition functions for the pending-action queue: `currentPendingAction`, `confirmHead`, `queueAfterConfirmingHead`, `cancelAllPendingActions`, `abortAllPendingActionsOnKillSwitch`, `expireCurrentPendingAction`, `filterActionsForEnqueuing` (act-mode gate), `shouldShowActModeOffNotice`, and `resolveElementForAction`. No side effects — directly unit-testable. |
| `ActionConfirmationPanel.swift` | ~780 | Phase D (U11). `ActionConfirmationPanelController` manages the lifecycle of a single non-activating key-accepting NSPanel that presents a CLICK/TYPE action for explicit user confirmation. 750ms arming delay (guarded by pure static `isConfirmationArmed`), 15s expiry, Confirm button + Return key accelerator, Cancel button + Esc key. `ActionConfirmationPanel` enum provides the `runKeyAcquisitionSpike()` DEBUG harness (activate with `--confirmation-panel-spike` launch argument). |
| `CompanionManager+PendingAction.swift` | ~700 | Phase D (U11/U12). Extension on CompanionManager wiring the pending-action queue lifecycle: act-mode UserDefaults flag, `processActionTagsAndEnqueue` (response pipeline integration), kill-switch observation (`bindActModeKillSwitchObservation`), confirmation panel presentation/outcome handling, walkthrough integration, highlight annotation lifecycle. Uses `PendingActionStateStorage` (associated object) for stored state. U12: analytics calls at all four action lifecycle points (proposed/confirmed/cancelled/failed); failure cases broken out by kind for granular `failure_reason` tracking. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
