//
//  ActionExecutionService.swift
//  leanring-buddy
//
//  Performs a click or type action on an AX-discovered UI element on the user's
//  behalf. This is the execution primitive for Phase D (act mode).
//
//  THREAD-SAFETY CONTRACT
//  ──────────────────────
//  All AXUIElement calls run on the SAME dedicated serial queue owned by
//  `AccessibilityElementInventoryService`. See that file's thread-safety
//  contract for the full rationale. We never create a second AX queue here —
//  one thread owns all AX traffic across the entire app.
//
//  SAFETY CHAIN (evaluated in order before any input is synthesised)
//  ─────────────────────────────────────────────────────────────────
//  1. HARD REFUSALS (checked first, before even touching the AX handle):
//     a. Secure text field role/subrole
//     b. System-wide secure input mode (IsSecureEventInputEnabled)
//     c. Control characters in TYPE payload (typing never synthesises Return)
//     d. Denylisted security-UI process names
//  2. PRE-STAGE RE-VALIDATION (mandatory before any synthetic input):
//     Fresh-read the element's role and frame on the AX thread. An AX error
//     (stale handle) or frame drift beyond epsilon returns .staleTarget.
//     The discovery walk may be many seconds old by execution time (Claude
//     turn + TTS + confirmation wait). A coordinate click against a moved
//     element is the forbidden failure this gate prevents.
//  3. ACTION CHAIN (click or type, each stage only if the previous failed):
//     See CLICK CHAIN and TYPE CHAIN sections below.
//
//  CG vs. AppKit coordinate spaces
//  ────────────────────────────────
//  AX element frames are in CG global space (top-left origin of primary
//  display). CGEvent expects CG space. No conversion is performed here —
//  we pass cgFrame.center directly to CGEvent. AppKit/SwiftUI conversion
//  (via ScreenCoordinateConverter) is only needed by the overlay pipeline,
//  which uses AppKit-global frames.
//
//  SYNTHETIC EVENT TAGGING
//  ───────────────────────
//  All synthetic events are posted from a private CGEventSource stamped with
//  a magic value in the eventSourceUserData field. This lets
//  GlobalPushToTalkShortcutMonitor's tap callback recognise and ignore them
//  (see that file's handleGlobalEventTap), and prevents Clicky's own
//  mouse-moved events from self-stalling the user-activity sampler inside
//  this service.
//

import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation
import os

// MARK: - Result type

/// The outcome of an `ActionExecutionService.execute(_:)` call.
///
/// Callers (U11, CompanionManager) translate this into spoken feedback
/// and/or overlay state changes.
enum ActionExecutionResult: Equatable {
    /// The action was performed and post-action verification confirmed the
    /// expected state change (e.g. the text field now contains the typed value).
    case performed

    /// The action was performed but post-action verification was not possible
    /// (e.g. the element's value attribute is not readable). The action likely
    /// succeeded but Clicky cannot confirm it.
    case performedUnverified

    /// The action was attempted but every stage in the chain failed.
    /// `reason` is a short human-readable description suitable for speaking.
    case failed(reason: String)

    /// The action was not attempted because a hard-refusal rule fired before
    /// any stage ran. `reason` explains which rule (secure field, control char,
    /// denylisted process, etc.) for speaking and for analytics.
    case refused(reason: String)

    /// Re-validation found the element's handle stale (AX error) or its frame
    /// had moved beyond the epsilon threshold since the inventory walk. Nothing
    /// was sent to the target app. The caller should ask the user to re-try
    /// after the screen has settled.
    case staleTarget

    /// The action was aborted mid-chain because `abortCurrentAction()` was
    /// called (e.g. the user pressed Esc or PTT while the chain was executing).
    case aborted
}

// MARK: - Action type

/// Describes what the user wants done to a specific element.
///
/// Both cases carry the target `AccessibleElement` (with its live AX handle
/// and validated-at-walk-time cgFrame). The handle is re-validated inside
/// `execute(_:)` before any input is synthesised.
enum PlannedElementAction {
    /// Click the element (prefer AXPress, fall back to CGEvent).
    case click(target: AccessibleElement)

    /// Type `textToType` into the element (prefer kAXValueAttribute set, fall
    /// back to CGEvent keyboard typing). The text must never contain control
    /// characters — callers are expected to pre-validate, and this service
    /// applies the same check as a safety net.
    case type(target: AccessibleElement, textToType: String)
}

// MARK: - Internal stage tracking

/// Which stage of the click or type fallback chain is currently being attempted.
/// Used both internally to advance the chain and in pure unit tests.
enum ActionExecutionClickStage {
    /// AXUIElementPerformAction(kAXPressAction) — preferred for AX-discovered
    /// elements; most reliable for native controls.
    case axPress
    /// CGEvent click pair posted to the target process's PID — second choice;
    /// works for most native apps; Chromium web content sometimes rejects it.
    case cgEventPostToPid
    /// CGEvent click via the HID event tap — last resort; cursor visibly moves.
    case cgEventPostToHIDTap
}

enum ActionExecutionTypeStage {
    /// AXUIElementSetAttributeValue(kAXValueAttribute) — layout-independent,
    /// instant; only works when the value attribute is settable.
    case axValueSet
    /// CGEvent keyboard typing via CGEventKeyboardSetUnicodeString — works for
    /// any text field that accepts keyboard input regardless of layout.
    case cgEventKeyboard
}

// MARK: - Service

/// Executes a single `PlannedElementAction` safely, following the safety chain
/// and fallback chain documented at the top of this file.
///
/// Usage (from U11, after confirmation):
/// ```swift
/// let result = await ActionExecutionService.shared.execute(.click(target: element))
/// ```
///
/// The service is a shared singleton. It serialises actions — if `execute` is
/// called concurrently, the second call will find `isActionCurrentlyRunning` true.
/// U11 prevents concurrent calls by disabling the confirmation UI until the
/// previous action resolves.
@MainActor
final class ActionExecutionService {

    static let shared = ActionExecutionService()

    // MARK: - Synthetic-event tagging constants

    /// Magic value stamped into `CGEventField.eventSourceUserData` on every
    /// synthetic event posted by this service. The value is arbitrary but must
    /// be non-zero (0 is the default for real hardware events) and unlikely to
    /// collide with other software that stamps userData.
    ///
    /// Chosen as a memorable ASCII-hex value: "CLKY" = 0x434C4B59.
    static let syntheticEventUserDataMagicValue: Int64 = 0x434C4B59

    /// Returns `true` if `event` was posted by Clicky's `ActionExecutionService`.
    ///
    /// Used by `GlobalPushToTalkShortcutMonitor.handleGlobalEventTap` to skip
    /// Clicky's own synthetic events, and by the user-activity sampler inside
    /// this service to exclude its own events from the HID-quiescence check.
    static func isClickySyntheticEvent(_ event: CGEvent) -> Bool {
        return event.getIntegerValueField(.eventSourceUserData) == syntheticEventUserDataMagicValue
    }

    // MARK: - Constants

    /// Re-validation epsilon in points. If the element's live frame center has
    /// moved more than this many points from the stored cgFrame center (in either
    /// axis), the element is considered stale and execution is refused.
    ///
    /// 8 points is roughly two CSS pixels on a Retina display — small enough to
    /// catch a toolbar that has reflowed, large enough to tolerate sub-pixel
    /// rendering jitter or rounding differences across AX reads.
    static let revalidationFrameDriftEpsilonInPoints: CGFloat = 8.0

    /// Delay between the left-mouse-down and left-mouse-up events in a synthetic
    /// click pair, in seconds. Mimics a realistic click duration so apps that
    /// wait for the up event inside a down handler do not race.
    static let syntheticClickMouseButtonHoldDurationInSeconds: TimeInterval = 0.030

    /// Maximum number of UTF-16 units per CGEvent keyboard chunk. Apple's
    /// documentation for CGEventKeyboardSetUnicodeString notes that the string
    /// is limited — empirically 20 units is the safe ceiling before some apps
    /// start dropping characters. We never split a surrogate pair across chunks.
    static let maximumUTF16UnitsPerKeyboardChunk: Int = 20

    /// Delay between consecutive keyboard chunks, in seconds. A short inter-chunk
    /// pause lets the target app process each chunk's key event before the next
    /// arrives. Empirically 16 ms (one 60 Hz frame) is sufficient; 20 ms gives
    /// comfortable headroom.
    static let interKeyboardChunkDelayInSeconds: TimeInterval = 0.020

    /// How long (in seconds) to wait in each poll loop iteration before checking
    /// the abort flag or the HID quiescence condition again.
    static let actionPollingIntervalInSeconds: TimeInterval = 0.050

    /// The maximum time (in seconds) to wait for HID quiescence before proceeding
    /// anyway. If the user is continuously typing/moving for longer than this
    /// threshold, the action proceeds rather than waiting indefinitely — a long
    /// wait with no progress is worse than a small collision.
    static let maximumHIDQuiescenceWaitInSeconds: TimeInterval = 3.0

    /// Seconds-since-last-HID-event threshold for the user-activity check.
    /// If the last real (non-Clicky-synthetic) mouse-moved or key-down event was
    /// more recent than this, the user is considered active and the action waits.
    ///
    /// HONEST LIMITS: CGEventSource.secondsSinceLastEventType(for: .combinedSessionState)
    /// counts ALL events of that type, including Clicky's own synthetic ones. We
    /// partially mitigate this by tagging synthetic events and filtering them via
    /// the event tap, but the CGEventSource counter is a system-wide accumulator
    /// that we cannot de-tag retroactively. The result is that a Clicky-posted
    /// mouse-moved event will appear to "reset the clock" from the sampler's point
    /// of view for the brief window before the next real HID event. In practice this
    /// means the pause may be slightly shorter than intended (the action fires a few
    /// milliseconds sooner) but never longer — it is a conservative-side inaccuracy.
    static let hidQuiescenceThresholdInSeconds: Double = 0.4

    /// The set of process executable names (not bundle IDs) that Clicky refuses
    /// to act upon. These are security-UI processes that display authentication
    /// dialogs, lock screens, or permission prompts. Synthetic input targeting
    /// them would be a security violation.
    ///
    /// WHY BY NAME, NOT BUNDLE ID
    /// ──────────────────────────
    /// These processes may run as daemons or agents that do not have a bundle ID
    /// accessible via NSRunningApplication.bundleIdentifier. The executable name
    /// (NSRunningApplication.executableURL.lastPathComponent) is more reliable
    /// for this set of system security processes.
    ///
    /// ORDINARY APPLE APPS ARE EXPLICITLY ALLOWED
    /// ────────────────────────────────────────────
    /// Finder (com.apple.finder), Safari (com.apple.Safari), System Settings
    /// (com.apple.systempreferences), and other everyday Apple apps are NOT on
    /// this list. They are exactly the apps walkthroughs teach users to navigate.
    /// The OS already hardens truly sensitive actions inside those apps (e.g.
    /// Safari's password field raises AXSecureTextField, which is caught by the
    /// role check). This denylist covers only the processes that ARE the security UI.
    static let deniedProcessExecutableNames: Set<String> = [
        "SecurityAgent",       // macOS authentication dialog (sudo, keychain)
        "loginwindow",         // lock screen and login window
        "coreautha",           // LocalAuthentication UI (Touch ID prompt)
        "screencaptureui"      // Screen Recording permission approval dialog
    ]

    // MARK: - Private state

    /// Thread-safe abort flag. Wraps a `Bool` inside an `OSAllocatedUnfairLock`
    /// (available on macOS 13+; this app targets 14.2). This is necessary because
    /// `abortCurrentAction()` is called on the MainActor while the typing loop
    /// checks the flag from AX-serial-queue closures dispatched via
    /// `performOnAXSerialQueue`. A plain Bool has no cross-thread visibility
    /// guarantee in Swift's memory model — even with @MainActor isolation on the
    /// write side, reads on a different OS thread can observe a stale value.
    ///
    /// Usage: read with `abortFlag.withLock { $0 }`, set with
    /// `abortFlag.withLock { $0 = true }`.
    private let abortFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Convenience accessor — returns `true` if the abort flag has been set.
    /// Safe to call from any thread.
    private var isAbortFlagSet: Bool {
        abortFlag.withLock { $0 }
    }

    /// True while an action is executing. Prevents concurrent calls.
    /// Set to `true` at the start of `execute(_:)` and back to `false` on
    /// every exit path (via `defer`). Readable by `CompanionManager+PendingAction`
    /// to detect an in-flight action for the kill-switch handler.
    private(set) var isActionCurrentlyRunning = false

    private init() {}

    // MARK: - Public API

    /// Executes `action` following the full safety chain.
    ///
    /// This method is safe to call from `@MainActor` code (U11, CompanionManager).
    /// All AX work is dispatched to the shared serial AX queue via
    /// `AccessibilityElementInventoryService.shared.performOnAXSerialQueue`.
    /// The method suspends while AX work is in flight and resumes on MainActor.
    ///
    /// Concurrent calls: if called while a previous execution is still running,
    /// returns `.refused(reason: "Another action is already in progress")`.
    func execute(_ action: PlannedElementAction) async -> ActionExecutionResult {
        guard !isActionCurrentlyRunning else {
            return .refused(reason: "Another action is already in progress.")
        }

        isActionCurrentlyRunning = true
        abortFlag.withLock { $0 = false }

        defer {
            isActionCurrentlyRunning = false
        }

        // Extract the target element regardless of action type.
        let targetElement: AccessibleElement
        switch action {
        case .click(let target):
            targetElement = target
        case .type(let target, _):
            targetElement = target
        }

        // ── HARD REFUSALS ────────────────────────────────────────────────
        // These are checked BEFORE touching the live AX handle or synthesising
        // any input. If any fires, we return immediately with .refused.
        let hardRefusalResult = ActionExecutionService.evaluateHardRefusals(
            action: action,
            targetElement: targetElement
        )
        if let refusalResult = hardRefusalResult {
            return refusalResult
        }

        // ── ABORT CHECK ───────────────────────────────────────────────────
        if isAbortFlagSet { return .aborted }

        // ── USER-ACTIVITY PAUSE ───────────────────────────────────────────
        // Wait until the user stops actively typing/moving the mouse, or until
        // the maximum wait time elapses. This prevents synthetic input from
        // colliding with in-progress user input.
        let userActivityWaitResult = await waitForUserInputQuiescence()
        if userActivityWaitResult == .aborted { return .aborted }

        // ── ABORT CHECK ───────────────────────────────────────────────────
        if isAbortFlagSet { return .aborted }

        // ── PRE-STAGE RE-VALIDATION ───────────────────────────────────────
        // Run on the shared AX serial queue. Reads the live element role and
        // frame and compares against the stored cgFrame.
        let revalidationResult = await AccessibilityElementInventoryService.shared
            .performOnAXSerialQueue {
                ActionExecutionService.revalidateTargetElement(targetElement)
            }

        switch revalidationResult {
        case .staleTarget:
            return .staleTarget
        case .aborted:
            return .aborted
        case .proceed:
            break // All good — continue to the action chain.
        }

        // ── ABORT CHECK ───────────────────────────────────────────────────
        if isAbortFlagSet { return .aborted }

        // ── ACTION CHAIN ──────────────────────────────────────────────────
        switch action {
        case .click(let target):
            return await executeClickChain(target: target)
        case .type(let target, let textToType):
            return await executeTypeChain(target: target, textToType: textToType)
        }
    }

    /// Sets the abort flag. Checked between every chain stage and every
    /// keyboard chunk. Thread-safe — writes through `OSAllocatedUnfairLock`
    /// so the update is immediately visible to the AX serial queue and any
    /// other thread that reads `isAbortFlagSet`.
    ///
    /// Called by U11's kill-switch handler when the user presses Esc or PTT
    /// while an action is in flight.
    func abortCurrentAction() {
        abortFlag.withLock { $0 = true }
    }

    // MARK: - Pure static: hard refusal evaluation

    /// Evaluates all hard-refusal rules and returns the first matching refusal
    /// result, or `nil` if no refusal applies.
    ///
    /// PURE STATIC: this function is extracted for unit testability. It has no
    /// side effects and does not touch any AX handles or HID state.
    ///
    /// - Parameters:
    ///   - action: The proposed action.
    ///   - targetElement: The element the action targets.
    /// - Returns: An `ActionExecutionResult.refused(reason:)` if any rule fires,
    ///   or `nil` if execution may proceed.
    static func evaluateHardRefusals(
        action: PlannedElementAction,
        targetElement: AccessibleElement
    ) -> ActionExecutionResult? {

        // Rule 1: Secure text field role or subrole.
        // AXSecureTextField is the standard role for password fields. Some apps
        // use AXTextField with subrole kAXSecureTextFieldSubrole instead.
        // We catch both patterns.
        let isSecureRole = targetElement.role == "AXSecureTextField"
        let isSecureSubrole = targetElement.subrole == kAXSecureTextFieldSubrole as String
        if isSecureRole || isSecureSubrole {
            return .refused(
                reason: "This field is a secure password field. Clicky never types into password fields."
            )
        }

        // Rule 2: System-wide secure input mode — TYPE actions only.
        // IsSecureEventInputEnabled() returns true when any app (including
        // Terminal's Secure Keyboard Entry, or a system password dialog) has
        // enabled secure keyboard input. In secure input mode, synthetic keyboard
        // events are suppressed by the OS — CGEvent typing would silently fail.
        // More importantly, if not suppressed, Clicky would be typing into a
        // secure context, which we explicitly refuse.
        //
        // This rule applies to TYPE actions only. CGEvent mouse clicks are NOT
        // blocked by secure keyboard input — refusing a CLICK when secure input
        // is active is overly conservative and produces a misleading spoken reason
        // ("will not type") for a non-typing action.
        if case .type = action {
            if IsSecureEventInputEnabled() {
                return .refused(
                    reason: "Secure keyboard input is active on this system. Clicky will not type while secure input is enabled."
                )
            }
        }

        // Rule 3: Control characters in TYPE payloads.
        // Typing never synthesises Return, newlines, tabs, or any other control
        // character. A "type this text" action must never silently become "type
        // this text and submit the form". The caller (U11) shows the text
        // verbatim in the confirmation UI; what is confirmed is exactly what
        // gets typed.
        if case .type(_, let textToType) = action {
            if ActionExecutionService.textContainsControlCharacters(textToType) {
                return .refused(
                    reason: "The text to type contains a control character (newline, tab, or similar). Clicky does not synthesise Return or other control keys in v1."
                )
            }
        }

        // Rule 4: Denylisted security-UI process — fail closed.
        // Resolve the owning process's executable name from its PID via
        // proc_pidpath (primary) + NSWorkspace (supplement). If the name
        // matches the denylist, refuse. If the process CANNOT be identified
        // at all (nil), also refuse — an unresolvable PID is more suspicious
        // than a known-safe process name, and failing open here would silently
        // bypass the denylist for any process that evades enumeration.
        guard let processExecutableName = ActionExecutionService.resolveExecutableName(
            forProcessID: targetElement.owningProcessID
        ) else {
            return .refused(
                reason: "Clicky could not identify the owning process (PID \(targetElement.owningProcessID)). Refusing to act for safety."
            )
        }

        if ActionExecutionService.deniedProcessExecutableNames.contains(processExecutableName) {
            return .refused(
                reason: "Clicky does not act on '\(processExecutableName)' — this is a security UI process."
            )
        }

        return nil // No refusal — execution may proceed.
    }

    // MARK: - Pure static: control character check

    /// Returns `true` if `text` contains any character that must be blocked
    /// from TYPE payloads because it could act as a form-submit trigger or
    /// otherwise break the "type exactly what the user confirmed" invariant.
    ///
    /// Specifically rejects:
    ///   U+0000–U+001F  C0 controls (NULL, TAB U+0009, LF U+000A, CR U+000D,
    ///                  ESC U+001B, etc.)
    ///   U+007F         DEL
    ///   U+0080–U+009F  C1 controls (including NEL U+0085 — a newline-equivalent
    ///                  that some text targets treat as a line break / submit)
    ///   U+2028         Unicode LINE SEPARATOR — acts as a line break in many
    ///                  text rendering engines and some web inputs interpret it
    ///                  as a submit trigger (same risk class as LF/CR)
    ///   U+2029         Unicode PARAGRAPH SEPARATOR — same risk class as U+2028
    ///
    /// PURE STATIC for unit testability.
    static func textContainsControlCharacters(_ text: String) -> Bool {
        return text.unicodeScalars.contains { scalar in
            scalar.value <= 0x001F
                || scalar.value == 0x007F
                || (0x0080...0x009F).contains(scalar.value)
                || scalar.value == 0x2028
                || scalar.value == 0x2029
        }
    }

    // MARK: - Pure static: executable name resolution

    /// Returns the executable name (last path component) for the process with
    /// the given PID, or `nil` if the name cannot be determined by any mechanism.
    ///
    /// Resolution strategy (primary first):
    ///
    /// 1. `proc_pidpath()` — a Darwin syscall that returns the full filesystem
    ///    path of the process's executable image directly from the kernel.
    ///    Works for daemons, agents, and system processes (SecurityAgent,
    ///    loginwindow, coreautha) that may not appear in NSWorkspace's app list
    ///    because they are launchd services without a bundle or UI presentation.
    ///
    /// 2. `NSWorkspace.shared.runningApplications` bundle-ID supplement — used
    ///    when proc_pidpath succeeds but returns an empty or slash-only path,
    ///    which is theoretically possible for processes whose executable image
    ///    has been unmapped. In practice proc_pidpath is almost always definitive.
    ///
    /// Returning `nil` means the process identity could not be established at all.
    /// The call site treats `nil` as a fail-closed condition (refusal), so this
    /// function should only return `nil` in genuine inability-to-resolve cases,
    /// not as a "process looks safe" signal.
    ///
    /// Called from the MainActor context before dispatching to the AX queue,
    /// so NSWorkspace access is safe.
    static func resolveExecutableName(forProcessID processID: pid_t) -> String? {
        // Primary: proc_pidpath — works for daemons and security agents that
        // NSWorkspace does not enumerate.
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let returnedLength = proc_pidpath(processID, &pathBuffer, UInt32(pathBuffer.count))
        if returnedLength > 0 {
            let fullPath = String(cString: pathBuffer)
            let executableName = (fullPath as NSString).lastPathComponent
            if !executableName.isEmpty && executableName != "/" {
                return executableName
            }
        }

        // Supplement: NSWorkspace bundle-based lookup for GUI apps whose
        // proc_pidpath result was unexpectedly empty.
        if let workspaceResult = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == processID })
            .flatMap({ $0.executableURL?.lastPathComponent }),
           !workspaceResult.isEmpty {
            return workspaceResult
        }

        // Cannot identify the process by any mechanism.
        return nil
    }

    // MARK: - Pure static: re-validation decision

    /// The three possible outcomes of a pre-stage re-validation attempt.
    enum RevalidationOutcome: Equatable {
        /// Re-validation passed — the handle is live and the frame is stable.
        case proceed
        /// The element's handle is stale or its frame has moved beyond epsilon.
        case staleTarget
        /// The abort flag was set before re-validation completed (checked
        /// at the call site, not inside this pure function).
        case aborted
    }

    /// Re-reads the target element's role and frame from the live AX handle and
    /// compares the frame center against the stored cgFrame center.
    ///
    /// MUST be called on the AX serial queue (passed via
    /// `AccessibilityElementInventoryService.shared.performOnAXSerialQueue`).
    ///
    /// PURE STATIC (aside from AX side-effects): extracted so the decision logic
    /// can be unit-tested with simulated inputs via
    /// `evaluateRevalidationDecision(axReadSucceeded:liveCGFrameCenter:storedCGFrameCenter:)`.
    ///
    /// - Parameter targetElement: The element as captured during the inventory walk.
    /// - Returns: `.proceed`, `.staleTarget`, or `.aborted`.
    nonisolated static func revalidateTargetElement(_ targetElement: AccessibleElement) -> RevalidationOutcome {
        let axHandle = targetElement.axElementHandle

        // Tighten the messaging timeout before issuing attribute reads so a hung
        // app does not stall the shared AX serial queue for the process-default ~6s.
        //
        // IMPORTANT: we set the timeout on a fresh app-level AX element
        // (AXUIElementCreateApplication), NOT on the retained `axHandle`.
        // Per AX documentation, a timeout set on the app element scopes all
        // calls made to any descendant within that app process — so the reads
        // below are still covered by the 1s limit.
        //
        // Why not set it on axHandle directly: the retained element handle in
        // `targetElement.axElementHandle` is shared by all code that holds this
        // AccessibleElement (attemptAXPressAction, isValueAttributeSettable,
        // attemptAXValueSet, etc.). Mutating it here would permanently cap those
        // later calls to 1s too, causing spurious failures for apps whose AX
        // stack responds correctly but takes 1–2s (e.g. slow Electron main thread).
        // A fresh app-level element is ephemeral — not stored, not reused — so the
        // 1s cap is strictly local to this revalidation call.
        let appElementForTimeout = AXUIElementCreateApplication(targetElement.owningProcessID)
        AXUIElementSetMessagingTimeout(appElementForTimeout, 1.0)

        // Re-read role — verifies the handle is still alive and pointing to the
        // right kind of element. An AX error here (kAXErrorInvalidUIElement,
        // kAXErrorCannotComplete, etc.) means the element no longer exists.
        var roleValue: AnyObject?
        let roleReadResult = AXUIElementCopyAttributeValue(
            axHandle,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleReadResult == .success else {
            // AX error → handle is stale. Return staleTarget.
            return .staleTarget
        }

        // Re-read position and size to get the current frame.
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        let positionReadResult = AXUIElementCopyAttributeValue(
            axHandle,
            kAXPositionAttribute as CFString,
            &positionValue
        )
        let sizeReadResult = AXUIElementCopyAttributeValue(
            axHandle,
            kAXSizeAttribute as CFString,
            &sizeValue
        )

        // If we cannot read position/size, treat it as stale — we cannot safely
        // compute a click target without knowing where the element is now.
        guard positionReadResult == .success,
              sizeReadResult == .success,
              let positionRaw = positionValue,
              let sizeRaw = sizeValue else {
            return .staleTarget
        }

        // AXValue is a CoreFoundation opaque type: `as? AXValue` always succeeds
        // (the compiler warns "conditional downcast will always succeed") because
        // Swift cannot verify CF type identity at compile time. The correct pattern
        // is to guard on the runtime CFTypeID before doing an unconditional cast.
        guard CFGetTypeID(positionRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else {
            return .staleTarget
        }
        let positionAXValue = positionRaw as! AXValue
        let sizeAXValue = sizeRaw as! AXValue

        var livePosition = CGPoint.zero
        var liveSize = CGSize.zero
        AXValueGetValue(positionAXValue, .cgPoint, &livePosition)
        AXValueGetValue(sizeAXValue, .cgSize, &liveSize)
        let liveCGFrame = CGRect(origin: livePosition, size: liveSize)
        let liveCGFrameCenter = CGPoint(
            x: liveCGFrame.midX,
            y: liveCGFrame.midY
        )
        let storedCGFrameCenter = CGPoint(
            x: targetElement.cgFrame.midX,
            y: targetElement.cgFrame.midY
        )

        return ActionExecutionService.evaluateRevalidationDecision(
            axReadSucceeded: true,
            liveCGFrameCenter: liveCGFrameCenter,
            storedCGFrameCenter: storedCGFrameCenter
        )
    }

    /// Pure decision function over re-validation inputs — extracted for unit
    /// testability without requiring a live AX handle.
    ///
    /// - Parameters:
    ///   - axReadSucceeded: Whether the AX attribute reads returned `.success`.
    ///   - liveCGFrameCenter: The element's current frame center in CG space.
    ///   - storedCGFrameCenter: The element's frame center from the inventory walk.
    /// - Returns: `.proceed` if the frame is stable within epsilon, `.staleTarget`
    ///   if the AX read failed or the frame drifted beyond epsilon.
    nonisolated static func evaluateRevalidationDecision(
        axReadSucceeded: Bool,
        liveCGFrameCenter: CGPoint,
        storedCGFrameCenter: CGPoint
    ) -> RevalidationOutcome {
        guard axReadSucceeded else { return .staleTarget }

        let horizontalDrift = abs(liveCGFrameCenter.x - storedCGFrameCenter.x)
        let verticalDrift = abs(liveCGFrameCenter.y - storedCGFrameCenter.y)

        if horizontalDrift > revalidationFrameDriftEpsilonInPoints
            || verticalDrift > revalidationFrameDriftEpsilonInPoints {
            return .staleTarget
        }

        return .proceed
    }

    // MARK: - Pure static: Unicode chunking

    /// Splits `text` into chunks of at most `maximumUTF16UnitsPerKeyboardChunk`
    /// UTF-16 code units, never splitting a surrogate pair across a chunk boundary.
    ///
    /// WHY UTF-16 CHUNKING
    /// ────────────────────
    /// CGEventKeyboardSetUnicodeString works on UTF-16 code units. Apple's
    /// documentation notes a practical limit on how many characters can be passed
    /// per event (~20 units). Emoji and other characters outside the BMP (Basic
    /// Multilingual Plane) are encoded as surrogate pairs in UTF-16 — a high
    /// surrogate (U+D800–U+DBFF) must always be followed by a low surrogate
    /// (U+DC00–U+DFFF). Splitting between the two halves of a pair produces
    /// garbled output in the target app.
    ///
    /// PURE STATIC for unit testability.
    ///
    /// - Parameter text: The full string to type.
    /// - Returns: An array of UTF-16 unit arrays, each ≤ maximumUTF16UnitsPerKeyboardChunk
    ///   units, with no surrogate pair split across a chunk boundary.
    static func splitTextIntoKeyboardChunks(_ text: String) -> [[UInt16]] {
        let utf16Units = Array(text.utf16)
        var chunks: [[UInt16]] = []
        var currentIndex = 0

        while currentIndex < utf16Units.count {
            let remainingCount = utf16Units.count - currentIndex
            var chunkSize = min(maximumUTF16UnitsPerKeyboardChunk, remainingCount)

            // The last unit of this tentative chunk must not be a high surrogate
            // (0xD800–0xDBFF) — if it is, the corresponding low surrogate sits at
            // chunkSize and would be stranded in the next chunk. Shrink by one
            // unit to keep the pair together in the next chunk.
            if chunkSize > 0 {
                let lastUnitInChunk = utf16Units[currentIndex + chunkSize - 1]
                let isHighSurrogate = lastUnitInChunk >= 0xD800 && lastUnitInChunk <= 0xDBFF
                if isHighSurrogate {
                    chunkSize -= 1
                }
            }

            // If chunkSize is now 0 (the single remaining unit was a high surrogate
            // with no following low surrogate — truncated/corrupt input), advance by
            // min(2, remainingCount) rather than a bare 2. A bare 2 would slice
            // beyond the array end when only 1 unit remains, causing a fatal
            // index-out-of-range crash. Clamping to remainingCount is safe: we send
            // the orphaned surrogate as-is (the target app will handle or discard it)
            // rather than crashing.
            if chunkSize == 0 { chunkSize = min(2, remainingCount) }

            let chunk = Array(utf16Units[currentIndex..<(currentIndex + chunkSize)])
            chunks.append(chunk)
            currentIndex += chunkSize
        }

        return chunks
    }

    // MARK: - Pure static: typing path selection

    /// Returns `true` if the type action should prefer `AXUIElementSetAttributeValue`
    /// on `kAXValueAttribute` (the fast, layout-independent path), or `false` if it
    /// should fall back to CGEvent keyboard typing.
    ///
    /// The value-set path is used when `kAXValueAttribute` is settable. It is more
    /// reliable than keyboard events for programmatic text entry because it does not
    /// depend on the current keyboard layout.
    ///
    /// MUST be called on the AX serial queue.
    ///
    /// - Parameter axElementHandle: The live AX handle for the target element.
    /// - Returns: `true` if the value attribute is settable.
    nonisolated static func isValueAttributeSettable(axElementHandle: AXUIElement) -> Bool {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            axElementHandle,
            kAXValueAttribute as CFString,
            &isSettable
        )
        return result == .success && isSettable.boolValue
    }

    // MARK: - Click chain execution

    /// Executes the click fallback chain for `target`.
    ///
    /// CLICK CHAIN (in order):
    ///   Stage 1: AXUIElementPerformAction(kAXPressAction)
    ///            — Preferred for AX-discovered elements. Most reliable for native
    ///              macOS controls; fires the accessibility action directly.
    ///              Returns `.performed` only when post-action AX verification
    ///              confirms a state change; otherwise `.performedUnverified`.
    ///   Stage 2: CGEvent .leftMouseDown + .leftMouseUp posted to target PID
    ///            — Works for most native apps; Chromium web content sometimes
    ///              rejects pid-targeted events silently (post returns Void —
    ///              there is no rejection signal). Always returns
    ///              `.performedUnverified` because CGEvent post cannot be
    ///              confirmed as accepted.
    ///   Stage 3: CGEvent via .cghidEventTap
    ///            — Last resort; the cursor visibly moves to the element center.
    ///              Same blind-post limitation as Stage 2; always returns
    ///              `.performedUnverified`.
    ///
    /// HONEST FALLBACK ORDER: Stages 2→3 are best-effort, not failure-driven.
    /// Stage 3 runs only when Stage 2's post itself cannot be constructed (guard
    /// failed to create the CGEvent), or when post-verification shows no effect
    /// in contexts where verification is readable. For the common case where
    /// Stage 2's events are silently rejected by Chromium web content, Stage 3
    /// still runs and also posts blind — neither stage can confirm acceptance.
    ///
    /// Each stage is only attempted if the previous one failed or reported
    /// .unsupported. The abort flag is checked between stages.
    private func executeClickChain(target: AccessibleElement) async -> ActionExecutionResult {
        // Determine whether AXPress is available for this element.
        let hasPressAction = await AccessibilityElementInventoryService.shared
            .performOnAXSerialQueue {
                ActionExecutionService.checkElementHasPressAction(axHandle: target.axElementHandle)
            }

        if isAbortFlagSet { return .aborted }

        // Stage 1: AXPress
        if hasPressAction {
            let axPressResult = await AccessibilityElementInventoryService.shared
                .performOnAXSerialQueue {
                    ActionExecutionService.attemptAXPressAction(axHandle: target.axElementHandle)
                }

            switch axPressResult {
            case .succeeded:
                // Attempt post-action verification by re-reading what's readable.
                let wasVerified = await verifyClickActionIfPossible(target: target)
                return wasVerified ? .performed : .performedUnverified

            case .failed:
                break // Fall through to Stage 2.

            case .notSupported:
                break // Should not happen since hasPressAction was true; fall through anyway.
            }
        }

        if isAbortFlagSet { return .aborted }

        // Stage 2: CGEvent click posted to target PID.
        // CGEvent.postToPid returns Void — there is no signal if the target app
        // silently drops the event (e.g. Chromium web content). We cannot confirm
        // acceptance, so always return .performedUnverified regardless of what
        // verifyClickActionIfPossible reports (handle still live ≠ click accepted).
        let clickCenter = CGPoint(x: target.cgFrame.midX, y: target.cgFrame.midY)
        let pidClickResult = await performSyntheticClickAtPoint(
            clickCenter,
            postTarget: .pid(target.owningProcessID)
        )

        if pidClickResult {
            return .performedUnverified
        }

        if isAbortFlagSet { return .aborted }

        // Stage 3: CGEvent via HID tap (cursor visibly moves — last resort).
        // Same blind-post limitation as Stage 2.
        let hidClickResult = await performSyntheticClickAtPoint(
            clickCenter,
            postTarget: .hidTap
        )

        if hidClickResult {
            return .performedUnverified
        }

        return .failed(reason: "All click methods failed for this element.")
    }

    // MARK: - Type chain execution

    /// Executes the type fallback chain for `target` with `textToType`.
    ///
    /// TYPE CHAIN (in order):
    ///   Stage 1: AXUIElementSetAttributeValue(kAXValueAttribute)
    ///            — Layout-independent, instant. Does not require keyboard focus.
    ///              Only attempted when the attribute is settable. Verified by
    ///              re-reading the value afterwards.
    ///   Stage 2: CGEvent keyboard typing via CGEventKeyboardSetUnicodeString
    ///            — Chunked at ≤20 UTF-16 units; never splits surrogate pairs.
    ///              Inter-chunk delay prevents character dropping.
    ///              Before posting events, `checkAndEnsureTargetIsFocused` verifies
    ///              (and if needed, establishes) focus with a single click — this is
    ///              the ONLY click issued for a TYPE action.
    ///
    /// NOTE: There is deliberately no unconditional pre-step click here. The
    /// kAXValueAttribute path does not need focus. The keyboard path gates on
    /// focus via `checkAndEnsureTargetIsFocused`, which issues at most one
    /// click. A prior unconditional pre-step click was removed because it
    /// caused two clicks total (pre-step + focus-retry inside checkAndEnsure)
    /// on elements where the first click dismisses or toggles the field.
    private func executeTypeChain(
        target: AccessibleElement,
        textToType: String
    ) async -> ActionExecutionResult {

        if isAbortFlagSet { return .aborted }

        // Determine whether the value attribute is settable.
        let isValueSettable = await AccessibilityElementInventoryService.shared
            .performOnAXSerialQueue {
                ActionExecutionService.isValueAttributeSettable(axElementHandle: target.axElementHandle)
            }

        if isAbortFlagSet { return .aborted }

        // Stage 1: AXValueAttribute set.
        if isValueSettable {
            let valueSetResult = await AccessibilityElementInventoryService.shared
                .performOnAXSerialQueue {
                    ActionExecutionService.attemptAXValueSet(
                        axHandle: target.axElementHandle,
                        textToType: textToType
                    )
                }

            if valueSetResult == .succeeded {
                // Verify by re-reading the value attribute.
                let verificationPassed = await verifyTypedValueMatchesExpected(
                    target: target,
                    expectedText: textToType
                )
                return verificationPassed ? .performed : .performedUnverified
            }
            // If value-set failed, fall through to keyboard typing.
        }

        if isAbortFlagSet { return .aborted }

        // Stage 2: CGEvent keyboard typing.
        // The kAXValueAttribute path above targets the element handle directly
        // and does not require focus. The keyboard path, however, posts events
        // to whatever element currently has system keyboard focus — if focus
        // drifted away from the target (e.g. during the confirmation wait or the
        // AXValueAttribute attempt), the keystrokes would land in the wrong field.
        //
        // Safety check: read the system-wide focused element and compare it to
        // the target handle using CFEqual. If they do not match, attempt one more
        // focus click and re-check. If the target still is not focused after the
        // retry, refuse rather than typing into the wrong field.
        //
        // NOTE: The kAXValueAttribute set path above is UNAFFECTED — it targets
        // the handle directly regardless of keyboard focus.
        let focusCheckResult = await checkAndEnsureTargetIsFocused(target: target)
        switch focusCheckResult {
        case .failed(let reason):
            return .failed(reason: reason)
        case .aborted:
            return .aborted
        case .focused:
            break // Target has focus — safe to type.
        }

        let keyboardResult = await performCGEventKeyboardTyping(
            textToType: textToType
        )

        switch keyboardResult {
        case .completedAllChunks:
            // No reliable post-type verification via AX for keyboard events
            // (the element's value may not be readable, or it may contain
            // content we didn't type). Return performedUnverified.
            return .performedUnverified

        case .abortedMidChunk:
            return .aborted

        case .failed:
            return .failed(reason: "Keyboard typing failed to post events to the target app.")
        }
    }

    // MARK: - AX action helpers (run on AX serial queue)

    /// Returns true if the element exposes `kAXPressAction` in its action names.
    ///
    /// MUST be called on the AX serial queue.
    nonisolated static func checkElementHasPressAction(axHandle: AXUIElement) -> Bool {
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(axHandle, &actionNames) == .success,
              let names = actionNames as? [String] else {
            return false
        }
        return names.contains(kAXPressAction as String)
    }

    /// Possible results from an individual action stage attempt.
    enum StageAttemptResult: Equatable {
        case succeeded
        case failed
        case notSupported
    }

    /// Attempts `kAXPressAction` on the element.
    ///
    /// MUST be called on the AX serial queue.
    nonisolated static func attemptAXPressAction(axHandle: AXUIElement) -> StageAttemptResult {
        let result = AXUIElementPerformAction(axHandle, kAXPressAction as CFString)
        switch result {
        case .success:
            return .succeeded
        case .actionUnsupported:
            return .notSupported
        default:
            return .failed
        }
    }

    /// Attempts to set `kAXValueAttribute` on the element to `textToType`.
    ///
    /// MUST be called on the AX serial queue.
    nonisolated static func attemptAXValueSet(axHandle: AXUIElement, textToType: String) -> StageAttemptResult {
        let result = AXUIElementSetAttributeValue(
            axHandle,
            kAXValueAttribute as CFString,
            textToType as CFString
        )
        return result == .success ? .succeeded : .failed
    }

    // MARK: - Synthetic click helpers

    /// Where to post a synthetic CGEvent click pair.
    private enum SyntheticClickPostTarget {
        /// Post directly to the process via `CGEvent.postToPid`.
        case pid(pid_t)
        /// Post via the HID event tap — cursor visibly moves.
        case hidTap
    }

    /// Creates a private CGEventSource stamped with the Clicky magic value so
    /// events can be identified by `isClickySyntheticEvent(_:)`.
    private func makeTaggedCGEventSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return nil
        }
        source.userData = ActionExecutionService.syntheticEventUserDataMagicValue
        return source
    }

    /// Posts a synthetic left-click pair (mouse-moved → down → up, ~30ms hold)
    /// to `postTarget` at `point` in CG global coordinates.
    ///
    /// Returns `true` if both events were posted without error.
    ///
    /// NOTE: This function uses `Task.sleep` so it must be called from an async
    /// context. It does NOT run on the AX queue — CGEvent posting does not
    /// require the AX thread.
    private func performSyntheticClickAtPoint(
        _ point: CGPoint,
        postTarget: SyntheticClickPostTarget
    ) async -> Bool {
        guard let source = makeTaggedCGEventSource() else { return false }

        // Move the cursor to the target point first. This is required by some
        // apps (e.g. web content in Chromium) that use the cursor position to
        // decide which element receives the click. The mouse-moved event is
        // tagged as synthetic so GlobalPushToTalkShortcutMonitor ignores it.
        guard let mouseMoveEvent = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }

        // Post the mouse-moved event.
        switch postTarget {
        case .pid(let processID):
            mouseMoveEvent.postToPid(processID)
        case .hidTap:
            mouseMoveEvent.post(tap: .cghidEventTap)
        }

        // Left mouse down.
        guard let mouseDownEvent = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }

        switch postTarget {
        case .pid(let processID):
            mouseDownEvent.postToPid(processID)
        case .hidTap:
            mouseDownEvent.post(tap: .cghidEventTap)
        }

        // Hold the button down for a realistic duration (~30ms) so apps that
        // listen for mouseDown before mouseUp do not race.
        try? await Task.sleep(nanoseconds: UInt64(
            ActionExecutionService.syntheticClickMouseButtonHoldDurationInSeconds * 1_000_000_000
        ))

        if isAbortFlagSet { return false }

        // Left mouse up.
        guard let mouseUpEvent = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }

        switch postTarget {
        case .pid(let processID):
            mouseUpEvent.postToPid(processID)
        case .hidTap:
            mouseUpEvent.post(tap: .cghidEventTap)
        }

        return true
    }

    // MARK: - CGEvent keyboard typing

    /// Possible outcomes of the CGEvent keyboard typing stage.
    private enum KeyboardTypingResult {
        case completedAllChunks
        case abortedMidChunk
        case failed
    }

    /// Types `textToType` by posting CGEvent keyboard events, chunked at
    /// ≤20 UTF-16 units per event.
    ///
    /// Uses `CGEventKeyboardSetUnicodeString` which is layout-independent —
    /// unlike keycode mapping, this API sends the exact Unicode characters
    /// regardless of the user's keyboard layout.
    private func performCGEventKeyboardTyping(textToType: String) async -> KeyboardTypingResult {
        guard let source = makeTaggedCGEventSource() else { return .failed }

        let chunks = ActionExecutionService.splitTextIntoKeyboardChunks(textToType)

        for chunk in chunks {
            if isAbortFlagSet { return .abortedMidChunk }

            // CGEventKeyboardSetUnicodeString requires a key-down/key-up pair.
            // Key code 0 is used as a placeholder — the actual key code is
            // irrelevant when setting the Unicode string directly. The string
            // overrides the keycode interpretation entirely.
            guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return .failed
            }

            chunk.withUnsafeBufferPointer { bufferPointer in
                // `CGEventKeyboardSetUnicodeString` (free function) was replaced by
                // the instance method `CGEvent.keyboardSetUnicodeString(stringLength:unicodeString:)`
                // in macOS 14 SDK. Both take the same UTF-16 count and pointer arguments;
                // the instance form is called on the event object directly.
                keyDownEvent.keyboardSetUnicodeString(
                    stringLength: chunk.count,
                    unicodeString: bufferPointer.baseAddress
                )
                keyUpEvent.keyboardSetUnicodeString(
                    stringLength: chunk.count,
                    unicodeString: bufferPointer.baseAddress
                )
            }

            // Post to the focused app via the session event tap so the events
            // land on whichever window currently has keyboard focus.
            keyDownEvent.post(tap: .cgSessionEventTap)
            keyUpEvent.post(tap: .cgSessionEventTap)

            // Check abort AFTER posting — we already sent this chunk, but we
            // should stop before sending the next one rather than wait for the
            // pre-chunk check at the top of the loop (which only runs after
            // the sleep below). This tightens the abort response window.
            if isAbortFlagSet { return .abortedMidChunk }

            // Inter-chunk delay: give the target app time to process each chunk
            // before the next arrives. Without this delay, fast text can cause
            // dropped characters in apps with synchronous input processing.
            try? await Task.sleep(nanoseconds: UInt64(
                ActionExecutionService.interKeyboardChunkDelayInSeconds * 1_000_000_000
            ))
        }

        return .completedAllChunks
    }

    // MARK: - Focus safety check for keyboard typing

    /// Possible outcomes of the pre-keyboard focus check.
    private enum FocusCheckResult: Equatable {
        /// The target element has keyboard focus — safe to proceed with typing.
        case focused
        /// The target could not be focused; contains the reason for refusal.
        case failed(reason: String)
        /// The abort flag was set while waiting for the re-focus click.
        case aborted
    }

    /// Ensures `target` has keyboard focus before the CGEvent keyboard typing
    /// stage posts events to the system-wide focused element.
    ///
    /// Strategy:
    ///   1. Read `kAXFocusedUIElementAttribute` from the system-wide AX element.
    ///   2. Compare the focused element handle to `target.axElementHandle` via
    ///      `CFEqual` — handles to the same underlying element compare equal.
    ///   3. If not focused, attempt one focus click via the existing click chain.
    ///   4. Re-read the focused element and compare again.
    ///   5. If still not focused, return `.failed` — refusing to type is safer
    ///      than typing into an unintended field.
    ///
    /// MUST be called from an async context (the focus-click is async).
    /// AX reads run on the AX serial queue via performOnAXSerialQueue.
    private func checkAndEnsureTargetIsFocused(target: AccessibleElement) async -> FocusCheckResult {
        // Read the system-wide focused element on the AX serial queue.
        let isFocusedInitially = await AccessibilityElementInventoryService.shared
            .performOnAXSerialQueue {
                ActionExecutionService.isElementCurrentlyFocused(target.axElementHandle)
            }

        if isFocusedInitially { return .focused }

        if isAbortFlagSet { return .aborted }

        // Target is not focused — attempt one re-focus click using the existing chain.
        // We discard the click result; focus is what matters, not whether the click
        // itself was verified (the click may have come from a CGEvent stage and be
        // unverified, but focus state is readable independently).
        _ = await executeClickChain(target: target)

        if isAbortFlagSet { return .aborted }

        // Re-check focus after the click attempt.
        let isFocusedAfterRetry = await AccessibilityElementInventoryService.shared
            .performOnAXSerialQueue {
                ActionExecutionService.isElementCurrentlyFocused(target.axElementHandle)
            }

        if isFocusedAfterRetry { return .focused }

        return .failed(
            reason: "The target field could not be focused. Clicky will not type into an unfocused element to avoid sending keystrokes to the wrong app."
        )
    }

    /// Returns `true` if `elementHandle` is the current system-wide keyboard-focus
    /// element as reported by the AX framework.
    ///
    /// Uses `CFEqual` for handle comparison — two AXUIElement references pointing
    /// to the same underlying accessibility element compare equal even if they are
    /// different Swift object identities.
    ///
    /// MUST be called on the AX serial queue.
    nonisolated static func isElementCurrentlyFocused(_ elementHandle: AXUIElement) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: AnyObject?
        let readResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard readResult == .success,
              let focusedElement = focusedElementValue else {
            return false
        }
        // CFEqual compares AXUIElement handles by their underlying element identity,
        // not by Swift reference equality — correct for AX handle comparison.
        return CFEqual(focusedElement, elementHandle)
    }

    // MARK: - Post-action verification

    /// Attempts to verify that a click produced a state change by re-reading
    /// the element's enabled/pressed state after the action.
    ///
    /// Returns `true` if verification was possible and the state changed (or
    /// the element is still accessible, indicating the action was handled),
    /// `false` if the element's state could not be read.
    private func verifyClickActionIfPossible(target: AccessibleElement) async -> Bool {
        return await AccessibilityElementInventoryService.shared.performOnAXSerialQueue {
            var stateValue: AnyObject?
            // Re-reading role is a lightweight probe that succeeds if the handle
            // is still live (the element was not destroyed by the click, which
            // is normal for most buttons).
            let readResult = AXUIElementCopyAttributeValue(
                target.axElementHandle,
                kAXRoleAttribute as CFString,
                &stateValue
            )
            // If the element is still readable, the click was at least processed
            // (the handle is live). Return true = verified-enough.
            return readResult == .success
        }
    }

    /// Verifies that the element's current value matches `expectedText` after
    /// a type action using kAXValueAttribute.
    ///
    /// Returns `true` if the value matches exactly. Returns `false` if the
    /// attribute is unreadable or the value does not match (signalling the caller
    /// to fall back to keyboard typing or return `.performedUnverified`).
    private func verifyTypedValueMatchesExpected(
        target: AccessibleElement,
        expectedText: String
    ) async -> Bool {
        return await AccessibilityElementInventoryService.shared.performOnAXSerialQueue {
            var valueObject: AnyObject?
            guard AXUIElementCopyAttributeValue(
                target.axElementHandle,
                kAXValueAttribute as CFString,
                &valueObject
            ) == .success,
            let currentValue = valueObject as? String else {
                return false
            }
            return currentValue == expectedText
        }
    }

    // MARK: - User-activity pause

    /// Possible results from the HID quiescence wait.
    private enum UserActivityWaitResult {
        case quiesced
        case timedOut // Waited up to maximumHIDQuiescenceWaitInSeconds; proceeding anyway.
        case aborted
    }

    /// Waits until the user has not moved the mouse or pressed a key for
    /// `hidQuiescenceThresholdInSeconds`, or until
    /// `maximumHIDQuiescenceWaitInSeconds` elapses, whichever comes first.
    ///
    /// LIMITS: See `hidQuiescenceThresholdInSeconds` documentation above for the
    /// honest accounting of why Clicky's own synthetic events may slightly affect
    /// the measurement.
    private func waitForUserInputQuiescence() async -> UserActivityWaitResult {
        let startTime = Date()

        while true {
            if isAbortFlagSet { return .aborted }

            // Check elapsed time.
            let elapsedSeconds = Date().timeIntervalSince(startTime)
            if elapsedSeconds >= ActionExecutionService.maximumHIDQuiescenceWaitInSeconds {
                return .timedOut
            }

            // Sample seconds since last mouse-moved and key-down events.
            // `CGEventSource.secondsSinceLastEventType` reports the time since
            // the last matching event across the combined session state (all users
            // and all apps, including daemons). We cannot exclude other apps'
            // events, but that is conservative — we only synthesise input when
            // it is quiet, never when it might collide.
            let secondsSinceLastMouseMoved = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: .mouseMoved
            )
            let secondsSinceLastKeyDown = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: .keyDown
            )

            let userIsActivelyMovingMouse = secondsSinceLastMouseMoved < ActionExecutionService.hidQuiescenceThresholdInSeconds
            let userIsActivelyTyping = secondsSinceLastKeyDown < ActionExecutionService.hidQuiescenceThresholdInSeconds

            if !userIsActivelyMovingMouse && !userIsActivelyTyping {
                return .quiesced
            }

            // User is still active — wait one polling interval and check again.
            try? await Task.sleep(nanoseconds: UInt64(
                ActionExecutionService.actionPollingIntervalInSeconds * 1_000_000_000
            ))
        }
    }
}
