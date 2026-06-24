# AGENTS.md - leanring-buddy App Target

This file applies to the macOS app source under `leanring-buddy/`. The top-level `AGENTS.md` remains the project-wide source of truth, and `CLAUDE.md` is a symlink to it.

## Current Shape

- `leanring_buddyApp.swift` is the menu-bar-only app entry point. There is no dock app or main window.
- `CompanionManager.swift` is the central state machine for push-to-talk, screenshots, provider routing, response overlays, TTS, pointing, walkthroughs, and act-mode coordination.
- `LLMProviderConfiguration.swift` loads `~/Library/Application Support/Clicky/llm.json` and selects Claude, OpenRouter, Ollama, or Codex.
- `CodexAPI.swift` bridges to local `codex exec` in read-only/ephemeral mode, attaches screenshots, and returns normal Clicky response text/tags.
- `CompanionPanelView.swift`, `MenuBarPanelManager.swift`, `OverlayWindow.swift`, and `CompanionResponseOverlay.swift` own the visible menu bar panel, cursor, text bubble, and annotation UI.
- `ActionTagParser.swift`, `PendingActionStateMachine.swift`, `ActionExecutionService.swift`, `ActionConfirmationPanel.swift`, and `CompanionManager+PendingAction.swift` own act-mode parsing, confirmation, and execution.

## Build And Verification

- Do not run local `xcodebuild`; it can churn macOS TCC permissions for Accessibility and Screen Recording.
- Use GitHub Actions for build/package verification.
- Local lightweight checks are fine when they do not launch or rebuild the app bundle.
- Keep GitHub Actions packaging compatible with unsigned/ad-hoc builds unless real signing secrets are present.

## Codex Provider Rules

- Keep the Codex bridge local and conservative: `codex exec`, screenshot attachments, final response file via `-o`, read-only sandbox by default, and no persistent session mutation unless the user explicitly configures it.
- Do not bypass Clicky's existing response pipeline. Codex output must still pass through the same TTS, text overlay, pointing, walkthrough, annotation, and act-mode parsers.
- Do not put secrets or auth tokens in source. Codex credentials must come from the user's installed Codex config or local runtime.

## Act Mode Rules

- Act mode stays off by default and is toggled from the Clicky panel.
- The CLICK/TYPE grammar must be present only when `CompanionManager.companionVoiceResponseSystemPrompt(actModeEnabled:)` is called with `true`.
- Actions use element IDs only: `[CLICK:E<id>:description]` and `[TYPE:E<id>:text:description]`.
- Every action needs explicit per-action confirmation before execution.
- Never log or send typed text in analytics.
- Do not weaken the secure-field, secure-input, stale-target, denylisted-process, or physical-user-activity safeguards.

## Editing Style

- Prefer clear, specific Swift names over short names.
- Use SwiftUI unless AppKit is required for menu bar, panel, overlay, or global input behavior.
- Keep UI state on `@MainActor`.
- Keep diffs narrow and reversible; avoid broad refactors while fixing a targeted bug.
- Do not add dependencies unless the user explicitly asks.
- Do not rename the legacy `leanring-buddy` project or scheme.
