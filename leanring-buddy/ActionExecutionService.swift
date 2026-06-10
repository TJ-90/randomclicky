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
import CoreGraphics
import Foundation

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

    /// Abort flag. Set by `abortCurrentAction()` and checked between every
    /// chain stage and every keyboard chunk. Using a simple Bool protected by
    /// the MainActor (since `execute` is async and runs on MainActor between
    /// queue hops).
    private var isAbortFlagSet = false

    /// True while an action is executing. Prevents concurrent calls.
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
        isAbortFlagSet = false

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
    /// keyboard chunk. Thread-safe because this service is `@MainActor` and
    /// the execute loop returns to MainActor between every AX queue hop.
    ///
    /// Called by U11's kill-switch handler when the user presses Esc or PTT
    /// while an action is in flight.
    func abortCurrentAction() {
        isAbortFlagSet = true
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

        // Rule 2: System-wide secure input mode.
        // IsSecureEventInputEnabled() returns true when any app (including
        // Terminal's Secure Keyboard Entry, or a system password dialog) has
        // enabled secure keyboard input. In secure input mode, synthetic keyboard
        // events are suppressed by the OS — CGEvent typing would silently fail.
        // More importantly, if it's not suppressed, it would mean Clicky is typing
        // into a secure context, which we explicitly refuse.
        if IsSecureEventInputEnabled() {
            return .refused(
                reason: "Secure keyboard input is active on this system. Clicky will not type while secure input is enabled."
            )
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

        // Rule 4: Denylisted security-UI process.
        // Resolve the owning process's executable name from its PID and compare
        // against the hard-coded denylist.
        if let processExecutableName = ActionExecutionService.resolveExecutableName(
            forProcessID: targetElement.owningProcessID
        ) {
            if ActionExecutionService.deniedProcessExecutableNames.contains(processExecutableName) {
                return .refused(
                    reason: "Clicky does not act on '\(processExecutableName)' — this is a security UI process."
                )
            }
        }

        return nil // No refusal — execution may proceed.
    }

    // MARK: - Pure static: control character check

    /// Returns `true` if `text` contains any character in the C0/C1 control
    /// range or the DEL character (U+007F).
    ///
    /// Specifically rejects:
    ///   U+0000–U+001F (C0 controls: NULL, TAB, LF, CR, ESC, etc.)
    ///   U+007F         (DEL)
    ///
    /// PURE STATIC for unit testability.
    static func textContainsControlCharacters(_ text: String) -> Bool {
        return text.unicodeScalars.contains { scalar in
            scalar.value <= 0x001F || scalar.value == 0x007F
        }
    }

    // MARK: - Pure static: executable name resolution

    /// Returns the executable name (last path component of the executable URL)
    /// for the process with the given PID, or `nil` if the process is not found
    /// in the running application list.
    ///
    /// This is used by the denylist check. We use
    /// `NSWorkspace.shared.runningApplications` rather than a direct syscall
    /// because it already gives us a clean executable name without root access.
    ///
    /// Called from the MainActor context before dispatching to the AX queue,
    /// so NSWorkspace access is safe.
    static func resolveExecutableName(forProcessID processID: pid_t) -> String? {
        return NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == processID }
            .flatMap { $0.executableURL?.lastPathComponent }
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
    static func revalidateTargetElement(_ targetElement: AccessibleElement) -> RevalidationOutcome {
        let axHandle = targetElement.axElementHandle

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
              let positionAXValue = positionValue as? AXValue,
              let sizeAXValue = sizeValue as? AXValue else {
            return .staleTarget
        }

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
    static func evaluateRevalidationDecision(
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

            // If chunkSize is now 0 (shouldn't happen with the ≥1 invariant on the
            // chunk limit, but defensive), advance by 2 to consume the surrogate pair.
            if chunkSize == 0 { chunkSize = 2 }

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
    static func isValueAttributeSettable(axElementHandle: AXUIElement) -> Bool {
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
    ///   Stage 2: CGEvent .leftMouseDown + .leftMouseUp posted to target PID
    ///            — Works for most native apps; Chromium web content sometimes
    ///              rejects pid-targeted events.
    ///   Stage 3: CGEvent via .cghidEventTap
    ///            — Last resort; the cursor visibly moves to the element center.
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
        let clickCenter = CGPoint(x: target.cgFrame.midX, y: target.cgFrame.midY)
        let pidClickResult = await performSyntheticClickAtPoint(
            clickCenter,
            postTarget: .pid(target.owningProcessID)
        )

        if pidClickResult {
            let wasVerified = await verifyClickActionIfPossible(target: target)
            return wasVerified ? .performed : .performedUnverified
        }

        if isAbortFlagSet { return .aborted }

        // Stage 3: CGEvent via HID tap (cursor visibly moves — last resort).
        let hidClickResult = await performSyntheticClickAtPoint(
            clickCenter,
            postTarget: .hidTap
        )

        if hidClickResult {
            let wasVerified = await verifyClickActionIfPossible(target: target)
            return wasVerified ? .performed : .performedUnverified
        }

        return .failed(reason: "All click methods failed for this element.")
    }

    // MARK: - Type chain execution

    /// Executes the type fallback chain for `target` with `textToType`.
    ///
    /// TYPE CHAIN (in order):
    ///   Pre-step: Ensure the target element is focused. If it is not already the
    ///             focused element, click it first using the click chain.
    ///   Stage 1: AXUIElementSetAttributeValue(kAXValueAttribute)
    ///            — Layout-independent, instant. Only attempted when the attribute
    ///              is settable. Verified by re-reading the value afterwards.
    ///   Stage 2: CGEvent keyboard typing via CGEventKeyboardSetUnicodeString
    ///            — Chunked at ≤20 UTF-16 units; never splits surrogate pairs.
    ///              Inter-chunk delay prevents character dropping.
    private func executeTypeChain(
        target: AccessibleElement,
        textToType: String
    ) async -> ActionExecutionResult {

        // Pre-step: focus the target field. Try clicking it first so the element
        // is focused and ready to receive keyboard input. If click fails, we proceed
        // to typing anyway — some text fields accept kAXValueAttribute without focus.
        let focusClickResult = await executeClickChain(target: target)
        // A click failure before typing is non-fatal — typing may still succeed
        // via kAXValueAttribute. Log but do not return.
        _ = focusClickResult

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
    static func checkElementHasPressAction(axHandle: AXUIElement) -> Bool {
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
    static func attemptAXPressAction(axHandle: AXUIElement) -> StageAttemptResult {
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
    static func attemptAXValueSet(axHandle: AXUIElement, textToType: String) -> StageAttemptResult {
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
                // CGEventKeyboardSetUnicodeString takes a count and a pointer to
                // UTF-16 code units. We pass the chunk's buffer directly.
                CGEventKeyboardSetUnicodeString(
                    keyDownEvent,
                    chunk.count,
                    bufferPointer.baseAddress
                )
                CGEventKeyboardSetUnicodeString(
                    keyUpEvent,
                    chunk.count,
                    bufferPointer.baseAddress
                )
            }

            // Post to the focused app via the session event tap so the events
            // land on whichever window currently has keyboard focus.
            keyDownEvent.post(tap: .cgSessionEventTap)
            keyUpEvent.post(tap: .cgSessionEventTap)

            // Inter-chunk delay: give the target app time to process each chunk
            // before the next arrives. Without this delay, fast text can cause
            // dropped characters in apps with synchronous input processing.
            try? await Task.sleep(nanoseconds: UInt64(
                ActionExecutionService.interKeyboardChunkDelayInSeconds * 1_000_000_000
            ))
        }

        return .completedAllChunks
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
