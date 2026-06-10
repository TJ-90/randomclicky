//
//  ActionConfirmationPanel.swift
//  leanring-buddy
//
//  A small non-activating NSPanel that presents a pending CLICK or TYPE action
//  for explicit user confirmation before anything is executed.
//
//  ARCHITECTURE: KEY-ACCEPTING NON-ACTIVATING PANEL
//  ─────────────────────────────────────────────────────────────────────────────
//  The panel uses `.nonactivatingPanel` style so showing it does NOT activate
//  Clicky (the user's focused app stays focused at the OS level). However it
//  subclasses NSPanel with `canBecomeKey = true` — the same pattern used by
//  `KeyablePanel` in `MenuBarPanelManager.swift` — so we can programmatically
//  call `makeKeyAndOrderFront` to acquire key status.
//
//  KEY ACQUISITION FROM A BACKGROUND APP: THE SPIKE
//  ─────────────────────────────────────────────────────────────────────────────
//  Whether a non-activating panel shown programmatically from a background app
//  reliably acquires key status over an active third-party app is the plan's
//  least-proven mechanism (KTD: "Confirmation must consume keystrokes"). The
//  `KeyablePanel` in `MenuBarPanelManager` only becomes key after the user
//  clicks the status-item button — a user gesture, which is a very different
//  code path from programmatic acquisition triggered by Claude's response.
//
//  TO RUN THE SPIKE (from Xcode):
//  ─────────────────────────────────────────────────────────────────────────────
//  1. Edit the scheme (Product → Scheme → Edit Scheme…).
//  2. In the "Arguments" tab under "Arguments Passed On Launch", add:
//       --confirmation-panel-spike
//  3. Build and run (Cmd+R). Focus another app (e.g. Finder) within 3 seconds.
//  4. The spike panel will appear after 3 seconds and print results to the
//     Xcode console:
//       [SPIKE] Panel shown. isKeyWindow = true/false
//       [SPIKE] Key acquisition: SUCCEEDED / FAILED (fell back to click-to-confirm)
//  5. Try pressing Return — the console will print whether the keypress was
//     consumed by the panel or leaked to the frontmost app.
//  6. Remove the launch argument when done.
//
//  The wiring for the launch flag lives in `CompanionManager.start()` — it
//  checks `ProcessInfo.processInfo.arguments.contains("--confirmation-panel-spike")`
//  and calls `ActionConfirmationPanel.runKeyAcquisitionSpike()` if present.
//
//  DUAL CONFIRM AFFORDANCE (fallback design)
//  ─────────────────────────────────────────────────────────────────────────────
//  The panel ALWAYS shows a clickable "Confirm" button — keyboard Return is an
//  accelerator, not the only path. If key acquisition fails (Return leaks to the
//  target app), the user can still click Confirm. The arming delay guards both
//  paths: clicking Confirm within 750ms of the panel appearing is also ignored.
//
//  ARMING DELAY
//  ─────────────────────────────────────────────────────────────────────────────
//  Return confirms ONLY after a 750ms arming delay from when the panel appeared.
//  This prevents an in-flight keystroke (e.g. the user was typing in a form when
//  Claude responded) from inadvertently confirming the action.
//
//  The arming check is exposed as a pure static function `isConfirmationArmed`
//  so it can be unit-tested without constructing the panel.
//
//  Esc cancels IMMEDIATELY — no arming delay on cancellation.
//
//  EXPIRY TIMER
//  ─────────────────────────────────────────────────────────────────────────────
//  If the user does not confirm or cancel within ~15 seconds, the panel auto-
//  dismisses and the action is cancelled silently (no spoken acknowledgment on
//  expiry — only on explicit cancel).
//
//  KEY FOCUS RESTORATION
//  ─────────────────────────────────────────────────────────────────────────────
//  On dismiss (for any reason), we attempt to restore key focus to the previously
//  key window by calling `previousKeyWindow?.makeKeyAndOrderFront(nil)`.
//  IME (Input Method Editor) composition state may be lost — this is an accepted
//  limitation documented in the plan's KTD and in U12's docs.
//

import AppKit
import SwiftUI

// MARK: - Key-accepting panel subclass

/// NSPanel subclass that can become the key window even with `.nonactivatingPanel`
/// style. Required for Return/Esc keypresses to be consumed by the panel rather
/// than leaking to the frontmost app.
///
/// This is identical in intent to `KeyablePanel` in `MenuBarPanelManager.swift`
/// but lives here because the confirmation panel has a different ownership model
/// (managed by `ActionConfirmationPanelController`, not `MenuBarPanelManager`).
private final class KeyAcceptingConfirmationPanel: NSPanel {
    /// Returning `true` here is what enables `makeKeyAndOrderFront` to succeed
    /// even though the panel uses `.nonactivatingPanel` style.
    override var canBecomeKey: Bool { true }
}

// MARK: - Confirmation outcome

/// The result of a user's interaction with the confirmation panel.
///
/// Callers in CompanionManager receive this via the `onOutcome` callback and
/// translate it into the appropriate pending-action state transition.
enum ActionConfirmationOutcome {
    /// The user confirmed the action (Return key or Confirm button click).
    case confirmed
    /// The user explicitly cancelled (Esc key or Cancel button click).
    case cancelledByUser
    /// The 15s expiry timer fired with no user interaction.
    case expiredWithoutConfirmation
}

// MARK: - Confirmation panel controller

/// Manages the lifecycle of a single action confirmation panel.
///
/// Create one per pending action, call `show(near:)`, and listen for the
/// `onOutcome` callback. The controller tears itself down (closes the panel,
/// cancels timers) before calling back.
///
/// Only one confirmation panel should be visible at a time — CompanionManager
/// enforces this by keeping a single `currentConfirmationPanelController`
/// instance.
@MainActor
final class ActionConfirmationPanelController {

    // MARK: - Configuration

    /// The arming delay in seconds. Return/Confirm is ignored until this much
    /// time has elapsed since the panel appeared. Exposed publicly so tests can
    /// call `isConfirmationArmed` with a known boundary.
    static let armingDelayInSeconds: TimeInterval = 0.750

    /// The expiry timeout in seconds. If no user interaction occurs within this
    /// window the action is silently cancelled.
    static let expiryTimeoutInSeconds: TimeInterval = 15.0

    // MARK: - State

    private let pendingAction: ParsedElementAction
    /// The element's role and title from the AX inventory, formatted as a short
    /// string like `AXButton "Submit"`. Displayed prominently so a mislabeled
    /// action is visually loud.
    private let axElementRoleAndTitle: String
    private let onOutcome: (ActionConfirmationOutcome) -> Void

    private var panel: KeyAcceptingConfirmationPanel?

    /// Whether the confirmation panel is currently the key window.
    ///
    /// `fileprivate` so the spike harness (also in this file) can check whether
    /// key acquisition succeeded without reaching past the private access boundary.
    fileprivate var isPanelKeyWindow: Bool {
        guard let panel else { return false }
        return panel.isKeyWindow
    }
    /// The window that was key before we showed the confirmation panel.
    /// Restored on dismiss so focus returns to the user's working context.
    private var previouslyKeyWindow: NSWindow?
    /// The exact time the panel was shown. Used by `isConfirmationArmed`.
    private var panelShownAtDate: Date?
    /// Timer that fires `expiryTimeoutInSeconds` after the panel appears.
    private var expiryTimer: Timer?
    /// Whether the outcome has already been delivered. Guards against delivering
    /// the callback twice (e.g. if Esc fires while the expiry timer is firing).
    private var hasDeliveredOutcome = false

    // MARK: - Init

    init(
        pendingAction: ParsedElementAction,
        axElementRoleAndTitle: String,
        onOutcome: @escaping (ActionConfirmationOutcome) -> Void
    ) {
        self.pendingAction = pendingAction
        self.axElementRoleAndTitle = axElementRoleAndTitle
        self.onOutcome = onOutcome
    }

    deinit {
        expiryTimer?.invalidate()
    }

    // MARK: - Public API

    /// Shows the confirmation panel near the given rect (the target element's
    /// AppKit-global frame) and begins the arming delay + expiry timer.
    ///
    /// - Parameter targetElementAppKitFrame: The target element's frame in AppKit
    ///   global coordinates. The panel is positioned near (but not covering) the
    ///   element so the user can see what is highlighted.
    func show(near targetElementAppKitFrame: CGRect) {
        previouslyKeyWindow = NSApp.keyWindow

        let panelWidth: CGFloat = 340
        let panelHeight: CGFloat = pendingAction.kind == .type ? 220 : 170

        let confirmationPanel = KeyAcceptingConfirmationPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        confirmationPanel.isFloatingPanel = true
        // .popUpMenu puts the panel above all other windows including full-screen apps.
        confirmationPanel.level = .popUpMenu
        confirmationPanel.isOpaque = false
        confirmationPanel.backgroundColor = .clear
        confirmationPanel.hasShadow = true
        confirmationPanel.hidesOnDeactivate = false
        confirmationPanel.isExcludedFromWindowsMenu = true
        confirmationPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        confirmationPanel.titleVisibility = .hidden
        confirmationPanel.titlebarAppearsTransparent = true

        // Build the SwiftUI content and host it in the panel.
        let contentView = ActionConfirmationContentView(
            pendingAction: pendingAction,
            axElementRoleAndTitle: axElementRoleAndTitle,
            onConfirm: { [weak self] in self?.handleConfirmButtonTapped() },
            onCancel: { [weak self] in self?.handleCancelButtonTapped() }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        confirmationPanel.contentView = hostingView

        // Position the panel just below and to the left of the target element
        // so it does not cover the highlighted element but is visually close to it.
        let panelOrigin = computePanelOrigin(
            targetElementAppKitFrame: targetElementAppKitFrame,
            panelWidth: panelWidth,
            panelHeight: panelHeight
        )
        confirmationPanel.setFrameOrigin(panelOrigin)

        panel = confirmationPanel
        panelShownAtDate = Date()

        // Show the panel and attempt to make it key so Return/Esc are consumed
        // by the panel rather than leaking to the frontmost app.
        //
        // makeKeyAndOrderFront attempts programmatic key acquisition from a
        // background app — the spike (see file header) tests whether this
        // succeeds reliably over active third-party apps.
        confirmationPanel.makeKeyAndOrderFront(nil)
        confirmationPanel.orderFrontRegardless()

        // Log the key acquisition result for the spike and for diagnostics.
        // This is cheap to leave in release builds — it only fires when the
        // confirmation panel is shown, which happens at most once per Claude response.
        print("[ActionConfirmationPanel] shown — isKeyWindow: \(confirmationPanel.isKeyWindow), keyWindowApp: \(NSApp.keyWindow?.description ?? "nil")")

        // Install a key-event monitor so Return and Esc are handled even when the
        // panel is key. We use a local monitor (not global) because the panel IS
        // key (or should be), so local monitors fire for its events.
        installKeyEventMonitor(for: confirmationPanel)

        // Start the expiry timer.
        expiryTimer = Timer.scheduledTimer(
            withTimeInterval: Self.expiryTimeoutInSeconds,
            repeats: false
        ) { [weak self] _ in
            self?.handleExpiryTimerFired()
        }
    }

    /// Dismisses the panel programmatically without delivering an outcome.
    /// Used by CompanionManager when the kill switch (Esc tap, PTT) fires
    /// before the panel delivers its own outcome.
    func dismissWithoutCallback() {
        hasDeliveredOutcome = true
        tearDown(restoreFocus: true)
    }

    // MARK: - Pure static: arming delay check

    /// Returns `true` when enough time has elapsed since the panel appeared for
    /// a confirm action to be armed (i.e. not a leaked in-flight keypress).
    ///
    /// Exposed as a pure static function so the arming logic is testable without
    /// constructing the panel or involving real timers.
    ///
    /// - Parameters:
    ///   - panelShownAt: The date the confirmation panel was shown.
    ///   - eventAt: The date of the confirm event (key press or button click).
    ///   - armingDelay: The required minimum interval. Defaults to
    ///     `ActionConfirmationPanelController.armingDelayInSeconds`.
    /// - Returns: `true` if `eventAt - panelShownAt >= armingDelay`.
    static func isConfirmationArmed(
        panelShownAt: Date,
        eventAt: Date,
        armingDelay: TimeInterval = ActionConfirmationPanelController.armingDelayInSeconds
    ) -> Bool {
        let elapsed = eventAt.timeIntervalSince(panelShownAt)
        return elapsed >= armingDelay
    }

    // MARK: - Private: event handling

    private var keyEventMonitor: Any?

    private func installKeyEventMonitor(for targetPanel: NSPanel) {
        // Local monitor fires for events while the panel is key.
        // We watch .keyDown to intercept Return (confirm) and Esc (cancel).
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let returnKeyCode: UInt16 = 36
            let escapeKeyCode: UInt16 = 53

            switch event.keyCode {
            case returnKeyCode:
                // Return: confirm, but only after the arming delay has elapsed.
                // An in-flight keystroke arriving within 750ms of the panel appearing
                // must never confirm — it would be muscle-memory from the user's
                // previous typing context.
                if let shownAt = self.panelShownAt() {
                    if Self.isConfirmationArmed(panelShownAt: shownAt, eventAt: Date()) {
                        self.handleConfirmKeyPressed()
                    } else {
                        print("[ActionConfirmationPanel] Return ignored — arming delay not elapsed")
                    }
                }
                // Consume the event (return nil) so it does not reach the target app,
                // regardless of whether we acted on it. An unarmed Return that leaks
                // to the target app could insert a newline or submit a form — worse
                // than ignoring it.
                return nil

            case escapeKeyCode:
                // Esc: cancel immediately — no arming delay.
                self.handleCancelKeyPressed()
                return nil

            default:
                // Pass all other keys through. The user may be typing in a text
                // field that happens to be behind the panel.
                return event
            }
        }
    }

    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    private func panelShownAt() -> Date? {
        return panelShownAtDate
    }

    // MARK: - Private: outcome delivery

    private func handleConfirmKeyPressed() {
        guard !hasDeliveredOutcome else { return }
        hasDeliveredOutcome = true
        print("[ActionConfirmationPanel] confirmed via Return key")
        tearDown(restoreFocus: true)
        onOutcome(.confirmed)
    }

    private func handleConfirmButtonTapped() {
        guard !hasDeliveredOutcome else { return }

        // Apply the same arming delay to the Confirm button click. This prevents
        // the edge case where the user's mouse-click on the target app accidentally
        // becomes a click on the Confirm button if it appeared at the same screen
        // position.
        if let shownAt = panelShownAtDate {
            guard Self.isConfirmationArmed(panelShownAt: shownAt, eventAt: Date()) else {
                print("[ActionConfirmationPanel] Confirm button ignored — arming delay not elapsed")
                return
            }
        }

        hasDeliveredOutcome = true
        print("[ActionConfirmationPanel] confirmed via Confirm button")
        tearDown(restoreFocus: true)
        onOutcome(.confirmed)
    }

    private func handleCancelKeyPressed() {
        guard !hasDeliveredOutcome else { return }
        hasDeliveredOutcome = true
        print("[ActionConfirmationPanel] cancelled via Esc key")
        tearDown(restoreFocus: true)
        onOutcome(.cancelledByUser)
    }

    private func handleCancelButtonTapped() {
        guard !hasDeliveredOutcome else { return }
        hasDeliveredOutcome = true
        print("[ActionConfirmationPanel] cancelled via Cancel button")
        tearDown(restoreFocus: true)
        onOutcome(.cancelledByUser)
    }

    private func handleExpiryTimerFired() {
        guard !hasDeliveredOutcome else { return }
        hasDeliveredOutcome = true
        print("[ActionConfirmationPanel] expired after \(Self.expiryTimeoutInSeconds)s with no user interaction")
        tearDown(restoreFocus: true)
        // Silent expiry — no spoken acknowledgment per the plan spec.
        // CompanionManager speaks nothing on expiry; it just clears the queue.
        onOutcome(.expiredWithoutConfirmation)
    }

    // MARK: - Private: tear-down

    private func tearDown(restoreFocus: Bool) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        removeKeyEventMonitor()
        panel?.orderOut(nil)
        panel = nil

        if restoreFocus, let previousWindow = previouslyKeyWindow {
            // Restore key focus to whatever had it before we appeared.
            // NOTE: IME composition state is lost here — this is an accepted
            // limitation documented in the plan's KTD and in U12. For example,
            // if the user was composing a CJK character when the panel appeared,
            // that composition is discarded. The alternative (not restoring focus)
            // would leave the target app un-keyed, which is worse.
            previousWindow.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Private: panel positioning

    /// Positions the panel just below and slightly to the right of the target
    /// element so it is clearly associated with the highlighted element but
    /// does not cover it.
    ///
    /// Falls back to centering on the primary screen if the target rect is
    /// zero (e.g. element was dropped before frame was available).
    private func computePanelOrigin(
        targetElementAppKitFrame: CGRect,
        panelWidth: CGFloat,
        panelHeight: CGFloat
    ) -> CGPoint {
        let gapBelowElement: CGFloat = 8

        // If the target rect is non-zero, position near the element.
        if targetElementAppKitFrame != .zero {
            let panelX = targetElementAppKitFrame.minX
            let panelY = targetElementAppKitFrame.minY - panelHeight - gapBelowElement

            // Clamp to the primary screen bounds so the panel is always visible.
            let primaryScreenFrame = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let clampedX = min(max(panelX, primaryScreenFrame.minX), primaryScreenFrame.maxX - panelWidth)
            let clampedY = min(max(panelY, primaryScreenFrame.minY), primaryScreenFrame.maxY - panelHeight)

            return CGPoint(x: clampedX, y: clampedY)
        }

        // Zero rect fallback: center on primary screen.
        let primaryScreenFrame = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let centerX = primaryScreenFrame.midX - panelWidth / 2
        let centerY = primaryScreenFrame.midY - panelHeight / 2
        return CGPoint(x: centerX, y: centerY)
    }
}

// MARK: - Spike harness (DEBUG only)

extension ActionConfirmationPanel {
    // This extension holds the spike entry point. It references the type name
    // `ActionConfirmationPanel` which is defined below (as a namespace enum).
}

// MARK: - Namespace enum (for spike)

/// Namespace for the spike harness. The spike is DEBUG-only and wired via the
/// `--confirmation-panel-spike` launch argument. See the file header for how
/// to run it.
enum ActionConfirmationPanel {

#if DEBUG
    /// Spike harness: proves whether a `.nonactivatingPanel` programmatically
    /// shown from a background app can acquire key status over an active
    /// third-party app.
    ///
    /// HOW TO RUN:
    ///   1. In Xcode: Product → Scheme → Edit Scheme → Arguments → Add:
    ///        --confirmation-panel-spike
    ///   2. Build and run (Cmd+R).
    ///   3. Focus another app (Finder, Safari, etc.) within 3 seconds.
    ///   4. The panel will appear after 3 seconds. Watch the Xcode console for:
    ///        [SPIKE] Panel shown. isKeyWindow = true/false
    ///        [SPIKE] Key acquisition: SUCCEEDED / FAILED (fell back to click-to-confirm)
    ///   5. Press Return — console prints whether the panel consumed it.
    ///   6. Press Esc or click a button to dismiss.
    ///   7. Remove the launch argument when done.
    ///
    /// PRODUCTION FALLBACK DESIGN:
    ///   The panel always shows a Confirm button (click-to-confirm path) regardless
    ///   of spike outcome. Keyboard Return is an accelerator, not the only path.
    ///   This means even if key acquisition fails, the user can still confirm by
    ///   clicking — the spike only determines whether we can additionally offer
    ///   keyboard confirmation.
    @MainActor
    static func runKeyAcquisitionSpike() {
        print("[SPIKE] Starting key acquisition spike. Focus another app within 3 seconds…")

        // Wait 3 seconds so the user has time to focus another app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let spikeAction = ParsedElementAction(
                kind: .click,
                elementID: 99,
                textToType: nil,
                claudeDescription: "SPIKE: test confirmation gate — press Return or click Confirm"
            )

            let controller = ActionConfirmationPanelController(
                pendingAction: spikeAction,
                axElementRoleAndTitle: "AXButton \"SPIKE TEST\"",
                onOutcome: { outcome in
                    switch outcome {
                    case .confirmed:
                        print("[SPIKE] Outcome: CONFIRMED")
                    case .cancelledByUser:
                        print("[SPIKE] Outcome: CANCELLED by user")
                    case .expiredWithoutConfirmation:
                        print("[SPIKE] Outcome: EXPIRED")
                    }
                }
            )

            // Position near the center of the primary screen.
            let primaryScreen = NSScreen.screens.first
            let screenCenter = CGPoint(
                x: (primaryScreen?.frame.midX ?? 720) - 170,
                y: (primaryScreen?.frame.midY ?? 450) - 85
            )
            let fakeSpikeTargetRect = CGRect(
                x: screenCenter.x,
                y: screenCenter.y + 200,
                width: 200,
                height: 44
            )

            controller.show(near: fakeSpikeTargetRect)

            // Hold a strong reference so the controller lives past this closure.
            // In production, CompanionManager holds the reference. Here we use
            // a global spike storage just for the spike session.
            ActionConfirmationPanel.spikeControllerStorage = controller

            // After 2 seconds, report whether we are the key window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // isPanelKeyWindow checks panel.isKeyWindow via a fileprivate computed
                // property — avoids reaching past the private access boundary from here.
                let weAreKeyWindow = ActionConfirmationPanel.spikeControllerStorage?.isPanelKeyWindow ?? false

                if weAreKeyWindow {
                    print("[SPIKE] Key acquisition: SUCCEEDED — Return/Esc will be consumed by the panel")
                } else {
                    print("[SPIKE] Key acquisition: FAILED — falling back to click-to-confirm (Confirm button always present)")
                    print("[SPIKE] NSApp.keyWindow = \(NSApp.keyWindow?.description ?? "nil")")
                }
            }
        }
    }

    // Storage for the spike controller reference. Not thread-safe — spike use only.
    // nonisolated(unsafe) suppresses the sendability warning for this debug-only storage.
    nonisolated(unsafe) static var spikeControllerStorage: ActionConfirmationPanelController?
#endif
}

// MARK: - SwiftUI content view

/// The SwiftUI content rendered inside the confirmation panel.
///
/// Shows:
///   1. The AX element's own role + title (e.g. `AXButton "Delete"`) — prominent,
///      so a mislabeled action is visually loud.
///   2. Claude's plain-language description ("Claude says: click the Submit button").
///   3. For TYPE actions: the verbatim text to type in a quoted monospace block.
///   4. Confirm and Cancel buttons (both pointer-cursor + hover feedback).
///   5. An arming-delay progress indicator (subtle) that shows the user when
///      keyboard confirm becomes active.
private struct ActionConfirmationContentView: View {
    let pendingAction: ParsedElementAction
    let axElementRoleAndTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// Whether the arming delay has elapsed. Drives the Confirm button appearance.
    @State private var isArmed = false
    /// Timer reference for the arming animation.
    @State private var armingTimer: Timer? = nil

    var body: some View {
        ZStack {
            // Panel background — rounded, dark, with a subtle border.
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                        .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {

                // ── Header: action kind badge ──────────────────────────────
                HStack(spacing: DS.Spacing.xs) {
                    Text(pendingAction.kind == .click ? "Click" : "Type")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.accent)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent.opacity(0.15))
                        )
                    Spacer()
                    // Subtle "act mode" label so the user knows this is an automated action.
                    Text("act mode")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                // ── AX element role + title ────────────────────────────────
                // Displayed prominently so a mislabeled action is visually loud.
                // If Claude says "click Submit" but the AX tree says "AXButton 'Delete'",
                // the user sees the discrepancy before confirming.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Target element")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(axElementRoleAndTitle)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                }

                // ── Claude's description ───────────────────────────────────
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude says")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(pendingAction.claudeDescription)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // ── TYPE payload: verbatim text in a quoted monospace block ─
                // Only shown for TYPE actions. Verbatim display lets the user
                // catch any error in the text before it is typed.
                if pendingAction.kind == .type, let textToType = pendingAction.textToType {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Text to type")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text("\"\(textToType)\"")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DS.Colors.codeText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(DS.Spacing.xs)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small)
                                    .fill(DS.Colors.surface2)
                            )
                    }
                }

                Spacer(minLength: DS.Spacing.xs)

                // ── Confirm / Cancel buttons ───────────────────────────────
                // Both are always present (click-to-confirm is the primary path;
                // Return is an accelerator). The Confirm button dims while unarmed
                // to give the user a visual signal that it is not yet active.
                HStack(spacing: DS.Spacing.sm) {
                    // Cancel button — always fully active, no arming delay.
                    Button("Cancel") { onCancel() }
                        .buttonStyle(ActionConfirmationCancelButtonStyle())

                    // Confirm button — dims until the arming delay elapses.
                    Button(isArmed ? "Confirm" : "Confirm (⏎)") { onConfirm() }
                        .buttonStyle(ActionConfirmationConfirmButtonStyle(isArmed: isArmed))
                        .opacity(isArmed ? 1.0 : 0.55)
                        .animation(.easeOut(duration: 0.2), value: isArmed)
                }
            }
            .padding(DS.Spacing.lg)
        }
        .onAppear {
            // Start the arming delay timer. After 750ms we flip `isArmed = true`
            // which both enables the Confirm button visually and enables
            // the Return key handler in ActionConfirmationPanelController.
            armingTimer = Timer.scheduledTimer(
                withTimeInterval: ActionConfirmationPanelController.armingDelayInSeconds,
                repeats: false
            ) { _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isArmed = true
                    }
                }
            }
        }
        .onDisappear {
            armingTimer?.invalidate()
            armingTimer = nil
        }
    }
}

// MARK: - Button styles for confirmation panel

/// Confirm button style — accent-colored, full-width, pointer cursor.
private struct ActionConfirmationConfirmButtonStyle: ButtonStyle {
    let isArmed: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                    .fill(confirmButtonColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func confirmButtonColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.accentHover
        } else if isHovered {
            return DS.Colors.accentHover.opacity(0.9)
        } else {
            return DS.Colors.accent
        }
    }
}

/// Cancel button style — surface-colored, full-width, pointer cursor.
private struct ActionConfirmationCancelButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                    .fill(cancelButtonColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func cancelButtonColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}
