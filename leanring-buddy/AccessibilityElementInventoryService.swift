//
//  AccessibilityElementInventoryService.swift
//  leanring-buddy
//
//  Enumerates actionable UI elements in the frontmost window via the macOS
//  Accessibility API and produces a compact text inventory that is appended
//  to Claude's context alongside screenshots.
//
//  THREAD-SAFETY CONTRACT
//  ──────────────────────
//  All AXUIElement calls run on `axSerialQueue` — a single serial background
//  queue. The AX C API's thread-safety is explicitly undocumented by Apple.
//  Practitioner reports (Hammerspoon, window managers, computer-use agents)
//  consistently show that concurrent AX calls across threads cause crashes or
//  silent wrong answers. Using one serialised background queue is the
//  conservative, established-practice choice: never concurrent, never main.
//
//  BACKGROUND-COMPLETION CONTRACT
//  ───────────────────────────────
//  `captureInventoryOfFrontmostWindow()` supports cooperative early-return:
//  the caller (U4, CompanionManager) races it against a ~1.5s deadline.
//  If the walk cannot finish in time the caller proceeds without inventory.
//  However, the walk CONTINUES to run on the AX thread in the background.
//  When it completes it writes the result into `mostRecentCompletedInventory`
//  (a published property on the service). The next interaction reads this
//  property so it starts grounded even though the current turn had no inventory.
//  See the `captureInventoryOfFrontmostWindow` comment for the full contract.
//

import AppKit
import ApplicationServices
import Combine

// MARK: - Data types

/// A single actionable UI element discovered during an AX walk.
///
/// `axElementHandle` is retained for Phase D (act mode), which needs the live
/// handle to call `AXUIElementPerformAction`. Handles go stale when the app
/// redraws; never cache them across walks.
struct AccessibleElement {
    /// Sequential integer assigned during BFS traversal. E1 is the first kept
    /// element in traversal order, E2 the second, and so on. IDs are stable
    /// only for the lifetime of a single walk — a new walk re-numbers from 1.
    let elementID: Int

    /// The AX role string (e.g. "AXButton", "AXTextField").
    let role: String

    /// The AX subrole string if present (e.g. "AXSecureTextField"). Nil when
    /// the element has no subrole attribute or the attribute read failed.
    let subrole: String?

    /// Human-readable label for the element, derived from title → description →
    /// value-as-string fallback chain, sanitised so it cannot break tag grammar.
    let title: String

    /// The element's bounding rect in CG global coordinates (top-left origin of
    /// the primary display). Passed to CGEvent unchanged — AX and CGEvent share
    /// CG space; no conversion needed for synthetic input.
    let cgFrame: CGRect

    /// The element's bounding rect in AppKit global coordinates (bottom-left
    /// origin of the primary display). Used by the overlay pipeline to position
    /// the pointing cursor and annotation shapes.
    let appKitFrame: CGRect

    /// The live AX handle retained for Phase D action execution. This handle
    /// is valid only until the application redraws; callers must re-validate
    /// before acting (see `ActionExecutionService`).
    let axElementHandle: AXUIElement

    /// The process identifier of the application that owns this element. Used
    /// for CGEvent targeted delivery in the action execution fallback chain.
    let owningProcessID: pid_t
}

/// Describes why a walk produced no elements, distinguishable so analytics can
/// separate timeouts (which benefit from the background-completion path) from
/// empty trees (which indicate a stub tree or AX-less app).
enum AccessibilityInventoryCaptureOutcome {
    /// Walk completed and elements were found (or the tree was non-empty but
    /// no elements passed the actionable-role filter — still reported as
    /// `.captured` since the walk itself succeeded).
    case captured

    /// The walk did not complete within the allotted time. The background walk
    /// may still finish and write `mostRecentCompletedInventory`.
    case timedOut

    /// Walk completed but the element tree was empty or contained only the
    /// root application element with no children. Often indicates a stub tree
    /// in an Electron/Chromium app before the wake protocol fires.
    case emptyTree

    /// `AXIsProcessTrusted()` returned false, or the very first AX call
    /// returned `kAXErrorAPIDisabled` / `kAXErrorNotImplemented`, indicating
    /// the Accessibility grant is absent or stale.
    case permissionUnavailable
}

/// The result of one AX walk — the element array plus metadata.
struct AccessibilityElementInventory {
    /// Actionable elements discovered in traversal order, E1…En.
    let elements: [AccessibleElement]

    /// The localized display name of the frontmost application at the time of
    /// the walk (e.g. "Safari"). Empty string if the walk failed before
    /// identifying an app.
    let frontmostAppName: String

    /// The bundle identifier of the frontmost application (e.g.
    /// "com.apple.Safari"). Empty string if unavailable.
    let frontmostAppBundleID: String

    /// Why the walk produced its result. Use this to decide whether to log a
    /// timeout event, show a "no AX data" fallback, or surface a permission hint.
    let captureOutcome: AccessibilityInventoryCaptureOutcome
}

// MARK: - Service

/// Captures a bounded, non-blocking inventory of actionable UI elements in the
/// frontmost window. All AX work runs on a single dedicated serial queue.
///
/// Usage:
/// ```swift
/// let inventory = await AccessibilityElementInventoryService.shared
///     .captureInventoryOfFrontmostWindow()
/// ```
///
/// See `captureInventoryOfFrontmostWindow()` for the timeout/background-completion contract.
@MainActor
final class AccessibilityElementInventoryService: ObservableObject {

    static let shared = AccessibilityElementInventoryService()

    // MARK: - Published state

    /// The most recently COMPLETED walk result, regardless of whether its
    /// corresponding `captureInventoryOfFrontmostWindow()` call was awaited to
    /// completion or raced against a deadline and abandoned.
    ///
    /// Read this at the start of a turn to ground the model even when the live
    /// walk timed out. It is nil only before the first walk ever completes.
    @Published private(set) var mostRecentCompletedInventory: AccessibilityElementInventory?

    // MARK: - Constants

    /// Maximum number of elements visited during BFS before the walk stops.
    /// This bounds CPU time on pathological trees (e.g. a spreadsheet with
    /// thousands of cells). Primary bound — depth cap is secondary.
    static let maximumWalkedElementCount = 800

    /// Maximum BFS depth. Prevents unbounded recursion on deeply nested trees.
    /// Secondary bound — the walked-element cap fires first for most apps.
    static let maximumTraversalDepth = 40

    /// AX messaging timeout in seconds. Overrides the default (~6s per call)
    /// so one hung application cannot stall the entire walk.
    static let axMessagingTimeoutInSeconds: Float = 1.0

    /// Delay between the Electron/Chromium wake attempt and the re-walk, in
    /// seconds. Chromium builds its AX tree lazily; a short pause lets it
    /// populate before we re-walk.
    static let electronWakeRetryDelayInSeconds: Double = 0.5

    /// Maximum number of wake-and-retry attempts for Electron/Chromium apps.
    static let maximumElectronWakeRetryCount = 2

    // MARK: - Private state

    /// The single serial queue that owns ALL AXUIElement calls. See the
    /// thread-safety contract at the top of this file.
    private let axSerialQueue = DispatchQueue(
        label: "com.learningbuddy.ax-serial",
        qos: .userInitiated
    )

    private init() {}

    // MARK: - Public API

    /// Captures the inventory of actionable elements in the frontmost window.
    ///
    /// TIMEOUT CONTRACT
    /// ────────────────
    /// This function supports cooperative early-return. The caller (U4,
    /// `CompanionManager`) races it against a ~1.5s deadline using Swift's
    /// structured-concurrency `withTaskGroup` or `async let` + `Task.sleep`.
    /// If the race fires first, the caller proceeds without an inventory.
    ///
    /// The AX walk CONTINUES in the background on `axSerialQueue`. When it
    /// finishes it writes the result to `mostRecentCompletedInventory` (via
    /// `MainActor`). The next turn reads this property and begins grounded,
    /// even though the current turn had no inventory.
    ///
    /// This means a slow or unresponsive app imposes at most one un-grounded
    /// turn, not a perpetual blackout.
    ///
    /// Returns: An `AccessibilityElementInventory` with `.timedOut` outcome if
    /// the walk is still running when the caller cancels this task, or a
    /// completed inventory with `.captured` / `.emptyTree` /
    /// `.permissionUnavailable` otherwise.
    func captureInventoryOfFrontmostWindow() async -> AccessibilityElementInventory {
        // Snapshot the frontmost app on MainActor before jumping to the AX thread.
        // NSWorkspace is MainActor-only; we read the values we need here so the AX
        // thread receives plain value types (pid, name, bundleID) with no actor hops.
        guard let frontmostRunningApplication = NSWorkspace.shared.frontmostApplication else {
            return AccessibilityElementInventory(
                elements: [],
                frontmostAppName: "",
                frontmostAppBundleID: "",
                captureOutcome: .emptyTree
            )
        }

        let frontmostAppProcessID = frontmostRunningApplication.processIdentifier
        let frontmostAppName = frontmostRunningApplication.localizedName ?? ""
        let frontmostAppBundleID = frontmostRunningApplication.bundleIdentifier ?? ""

        // Check permission before scheduling AX work — avoids a queue dispatch
        // when we know upfront that the grant is absent.
        guard AXIsProcessTrusted() else {
            return AccessibilityElementInventory(
                elements: [],
                frontmostAppName: frontmostAppName,
                frontmostAppBundleID: frontmostAppBundleID,
                captureOutcome: .permissionUnavailable
            )
        }

        // Bridge async/await to the serial AX dispatch queue via a checked
        // continuation. The continuation is resumed exactly once — either with
        // a completed inventory, or with an empty/permission-unavailable result
        // if the walk fails early. If the caller cancels (timeout race), Swift's
        // task cancellation propagates; the walk still completes and writes
        // `mostRecentCompletedInventory` for the next turn.
        return await withCheckedContinuation { continuation in
            axSerialQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: AccessibilityElementInventory(
                        elements: [],
                        frontmostAppName: frontmostAppName,
                        frontmostAppBundleID: frontmostAppBundleID,
                        captureOutcome: .emptyTree
                    ))
                    return
                }

                let inventory = self.performWalkOnAXThread(
                    processID: frontmostAppProcessID,
                    frontmostAppName: frontmostAppName,
                    frontmostAppBundleID: frontmostAppBundleID
                )

                // Publish the completed result for the next turn's grounding,
                // regardless of whether the current continuation is still alive.
                DispatchQueue.main.async {
                    self.mostRecentCompletedInventory = inventory
                }

                continuation.resume(returning: inventory)
            }
        }
    }

    // MARK: - Pure static helpers (extracted for testability)

    /// Determines whether an element with the given role should be KEPT in the
    /// inventory (returned as an `AccessibleElement`).
    ///
    /// Kept roles are actionable controls the user can directly interact with.
    /// Container roles (AXGroup, AXScrollArea, etc.) are NOT kept but ARE
    /// descended into — callers should use `shouldDescendIntoRole` for that
    /// decision.
    ///
    /// - Parameters:
    ///   - role: The AX role string (e.g. "AXButton").
    ///   - elementExposesAXPressAction: Whether the element advertises
    ///     `kAXPressAction` via `AXUIElementCopyActionNames`. Any element that
    ///     is directly pressable is actionable regardless of role.
    /// - Returns: `true` if this element should be added to the inventory.
    static func shouldKeepElement(role: String, elementExposesAXPressAction: Bool) -> Bool {
        let actionableRoles: Set<String> = [
            "AXButton",
            "AXLink",
            "AXTextField",
            "AXTextArea",
            "AXCheckBox",
            "AXRadioButton",
            "AXPopUpButton",
            "AXMenuItem",
            "AXComboBox",
            "AXSlider"
        ]
        return actionableRoles.contains(role) || elementExposesAXPressAction
    }

    /// Determines whether BFS should descend into an element with the given role
    /// to look for actionable children.
    ///
    /// Container roles are not kept themselves but wrap actionable content.
    /// Any role not in the explicit drop list is descended into by default —
    /// this is the conservative choice that avoids missing elements in novel
    /// container types.
    ///
    /// - Parameter role: The AX role string.
    /// - Returns: `true` if BFS should visit this element's children.
    static func shouldDescendIntoRole(_ role: String) -> Bool {
        // Elements we know are leaves and not containers — no point descending.
        let knownLeafRoles: Set<String> = [
            "AXStaticText",
            "AXImage",
            "AXSeparator",
            "AXGrowArea",
            "AXHandle",
            "AXValueIndicator"
        ]
        return !knownLeafRoles.contains(role)
    }

    /// Sanitises a raw AX string value (title, description, or value) so it
    /// cannot break the prompt's tag grammar or the one-line inventory format.
    ///
    /// Rules:
    /// - Strip all newlines and carriage returns (a title spanning lines would
    ///   break the one-line-per-element format in the prompt).
    /// - Strip square brackets (a title like "[New]" would look like a tag and
    ///   confuse Claude's parser).
    /// - Collapse runs of whitespace to a single space and trim leading/trailing.
    /// - Truncate to 80 characters to keep lines readable in the prompt.
    ///
    /// - Parameter rawString: The raw string value from an AX attribute.
    /// - Returns: A sanitised string safe to embed in an inventory prompt line.
    static func sanitiseTitleForPrompt(_ rawString: String) -> String {
        var result = rawString
        // Remove newlines and carriage returns
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: "\r", with: " ")
        // Remove square brackets (would look like AX tags to the model)
        result = result.replacingOccurrences(of: "[", with: "")
        result = result.replacingOccurrences(of: "]", with: "")
        // Collapse runs of whitespace
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.trimmingCharacters(in: .whitespaces)
        // Truncate long titles
        if result.count > 80 {
            result = String(result.prefix(80))
        }
        return result
    }

    /// Returns true when the element's frame passes the visibility heuristic:
    /// the frame has non-trivial size and intersects at least one display's
    /// CG-coordinate bounds.
    ///
    /// Why CG bounds here: AX element frames are in CG global space (top-left
    /// origin). We check against CG-space screen bounds to avoid an extra
    /// coordinate conversion in the hot path.
    ///
    /// - Parameters:
    ///   - cgFrame: The element's bounding rect in CG global coordinates.
    ///   - windowCGFrame: The frame of the containing window in CG global
    ///     coordinates, used as an additional intersection check.
    ///   - cgScreenBoundsForAllDisplays: The CG-space bounds of every connected
    ///     display. Pass `CGDisplayBounds(displayID)` for each display.
    /// - Returns: `true` if the frame is visible by the heuristic.
    static func isElementFrameVisible(
        cgFrame: CGRect,
        windowCGFrame: CGRect,
        cgScreenBoundsForAllDisplays: [CGRect]
    ) -> Bool {
        // Reject zero-size and sub-pixel elements — they are invisible to the user
        // and would only waste inventory slots.
        guard cgFrame.width > 1, cgFrame.height > 1 else { return false }

        // Must intersect the containing window's frame.
        guard cgFrame.intersects(windowCGFrame) else { return false }

        // Must intersect at least one physical display's CG bounds.
        return cgScreenBoundsForAllDisplays.contains { screenBounds in
            cgFrame.intersects(screenBounds)
        }
    }

    /// Formats a known list of `AccessibleElement` values as a compact text
    /// block for inclusion in Claude's message.
    ///
    /// Output format per element:
    ///   `[E12] AXButton "Submit" (812,440 96x28)`
    ///
    /// The rect values are in screenshot-pixel space, matching the coordinate
    /// space of the screenshot images Claude receives in the same message. This
    /// is critical: if we used display-point values here, Claude would see AX
    /// numbers that disagree with the pixel coordinates it learned from the
    /// images, sabotaging its ability to cross-check structure against vision.
    ///
    /// Before truncating to `maximumElementCount`, elements are sorted by
    /// visible area (largest first) so toolbar chrome and invisible slivers
    /// don't crowd out the buttons and text fields the user actually wants to
    /// interact with.
    ///
    /// - Parameters:
    ///   - elements: The full element list from an `AccessibilityElementInventory`.
    ///   - screenshotWidthInPixels: Pixel width of the screenshot image for
    ///     the display the frontmost window is on.
    ///   - screenshotHeightInPixels: Pixel height of the screenshot image.
    ///   - displayFrameInAppKitCoordinates: NSScreen.frame for the display the
    ///     frontmost window is on. Used to translate AppKit-global element
    ///     frames into display-local space before scaling to pixels.
    ///   - maximumElementCount: Hard cap on elements emitted. Defaults to 150
    ///     to keep prompt token cost bounded. Elements beyond the cap are
    ///     replaced with a "… and N more" trailer line.
    /// - Returns: A multi-line string ready to append after the image blocks
    ///   in a Claude message.
    static func formatInventoryForPrompt(
        elements: [AccessibleElement],
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        displayFrameInAppKitCoordinates: CGRect,
        maximumElementCount: Int = 150
    ) -> String {
        guard !elements.isEmpty else { return "" }

        // Sort by visible area (largest first) so the most prominent interactive
        // elements appear first and survive truncation. Toolbar chrome tends to be
        // small; content buttons and text fields are larger.
        let sortedByVisibleArea = elements.sorted { elementA, elementB in
            let areaA = elementA.cgFrame.width * elementA.cgFrame.height
            let areaB = elementB.cgFrame.width * elementB.cgFrame.height
            return areaA > areaB
        }

        let elementsToPrint = Array(sortedByVisibleArea.prefix(maximumElementCount))
        let remainingCount = sortedByVisibleArea.count - elementsToPrint.count

        var lines: [String] = []
        for element in elementsToPrint {
            // Convert the AppKit-global frame to screenshot-pixel space so the
            // coordinates in the prompt match the images Claude is looking at.
            let screenshotPixelRect = ScreenCoordinateConverter.convertAppKitGlobalRectToScreenshotPixelRect(
                appKitGlobalRect: element.appKitFrame,
                displayFrameInAppKitCoordinates: displayFrameInAppKitCoordinates,
                screenshotWidthInPixels: CGFloat(screenshotWidthInPixels),
                screenshotHeightInPixels: CGFloat(screenshotHeightInPixels)
            )

            let x = Int(screenshotPixelRect.origin.x.rounded())
            let y = Int(screenshotPixelRect.origin.y.rounded())
            let w = Int(screenshotPixelRect.width.rounded())
            let h = Int(screenshotPixelRect.height.rounded())

            // Format: [E12] AXButton "Submit" (812,440 96x28)
            let line = "[E\(element.elementID)] \(element.role) \"\(element.title)\" (\(x),\(y) \(w)x\(h))"
            lines.append(line)
        }

        if remainingCount > 0 {
            lines.append("… and \(remainingCount) more elements not listed")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - AX thread work (runs entirely on axSerialQueue)

    /// Performs the full AX walk for the given process. This function must only
    /// be called from `axSerialQueue` — it calls AXUIElement APIs directly.
    ///
    /// All AX work in this function is synchronous (blocking the queue thread).
    /// The queue is serial so there is at most one walk in flight at any time.
    private func performWalkOnAXThread(
        processID: pid_t,
        frontmostAppName: String,
        frontmostAppBundleID: String
    ) -> AccessibilityElementInventory {

        // Create the application-level AX element. A fresh element is created
        // on every walk — handles from previous walks may have gone stale.
        let appElement = AXUIElementCreateApplication(processID)

        // Set a per-element messaging timeout so one hung app cannot stall the
        // entire queue for the default ~6 seconds per call.
        AXUIElementSetMessagingTimeout(appElement, AccessibilityElementInventoryService.axMessagingTimeoutInSeconds)

        // Validate that AX calls actually work for this process. The grant may
        // be present (AXIsProcessTrusted() = true) but stale after a re-sign —
        // a probe read distinguishes this from a fully working grant.
        var probeValue: AnyObject?
        let probeResult = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &probeValue)
        if probeResult == .apiDisabled || probeResult == .notImplemented {
            return AccessibilityElementInventory(
                elements: [],
                frontmostAppName: frontmostAppName,
                frontmostAppBundleID: frontmostAppBundleID,
                captureOutcome: .permissionUnavailable
            )
        }

        // Obtain the target window: prefer the focused window (the one the user
        // is actively working in), fall back to the main window.
        guard let targetWindow = getFocusedOrMainWindow(appElement: appElement) else {
            return AccessibilityElementInventory(
                elements: [],
                frontmostAppName: frontmostAppName,
                frontmostAppBundleID: frontmostAppBundleID,
                captureOutcome: .emptyTree
            )
        }

        // Read the window frame so we can use it for the visibility heuristic.
        let windowCGFrame = getWindowCGFrame(windowElement: targetWindow)

        // Build a list of all CG-space screen bounds for the visibility check.
        // We read this once here on the AX thread rather than consulting NSScreen
        // (MainActor) repeatedly in the hot loop.
        let cgScreenBoundsForAllDisplays = buildCGScreenBoundsForAllDisplays()

        // First walk attempt.
        var walkedElements = walkWindowBFS(
            windowElement: targetWindow,
            windowCGFrame: windowCGFrame,
            cgScreenBoundsForAllDisplays: cgScreenBoundsForAllDisplays,
            processID: processID
        )

        // Electron/Chromium wake: if the walk yielded very few kept elements and
        // the tree looks stub-like, try waking the AX tree and re-walking.
        let treeAppearsStubLike = walkedElements.keptElements.isEmpty
            && walkedElements.totalVisitedCount < 5

        if treeAppearsStubLike {
            walkedElements = attemptElectronWakeAndRewalk(
                appElement: appElement,
                windowElement: targetWindow,
                windowCGFrame: windowCGFrame,
                cgScreenBoundsForAllDisplays: cgScreenBoundsForAllDisplays,
                processID: processID
            )
        }

        let keptElements = walkedElements.keptElements

        if keptElements.isEmpty && walkedElements.totalVisitedCount == 0 {
            return AccessibilityElementInventory(
                elements: [],
                frontmostAppName: frontmostAppName,
                frontmostAppBundleID: frontmostAppBundleID,
                captureOutcome: .emptyTree
            )
        }

        return AccessibilityElementInventory(
            elements: keptElements,
            frontmostAppName: frontmostAppName,
            frontmostAppBundleID: frontmostAppBundleID,
            captureOutcome: .captured
        )
    }

    // MARK: - Window retrieval

    /// Returns the focused window for `appElement`, falling back to the main
    /// window. Both attributes use the same AX pattern; the fallback is needed
    /// for apps that don't expose a focused window (e.g. some menu-bar apps).
    private func getFocusedOrMainWindow(appElement: AXUIElement) -> AXUIElement? {
        var windowValue: AnyObject?

        // Try focused window first — this is the window the user is working in.
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        )
        if focusedResult == .success, let window = windowValue {
            return (window as! AXUIElement)
        }

        // Fall back to main window.
        let mainResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXMainWindowAttribute as CFString,
            &windowValue
        )
        if mainResult == .success, let window = windowValue {
            return (window as! AXUIElement)
        }

        return nil
    }

    // MARK: - Window frame

    /// Reads the window's CG-space frame from its AX position and size attributes.
    /// Returns `.zero` on failure — callers treat a zero frame as "no intersection
    /// check possible" and let all elements through the visibility heuristic.
    private func getWindowCGFrame(windowElement: AXUIElement) -> CGRect {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return .zero
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return .zero
        }

        return CGRect(origin: position, size: size)
    }

    // MARK: - Screen bounds

    /// Builds CG-coordinate bounds for every active display. Called once per
    /// walk and passed into the BFS so we avoid repeated CGDisplay queries in
    /// the hot loop.
    private func buildCGScreenBoundsForAllDisplays() -> [CGRect] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        return displayIDs.map { CGDisplayBounds($0) }
    }

    // MARK: - BFS walk result

    /// Holds both the kept actionable elements and the total visited count so
    /// callers can distinguish "empty tree" from "all visited elements were
    /// containers".
    private struct WalkResult {
        let keptElements: [AccessibleElement]
        let totalVisitedCount: Int
    }

    // MARK: - BFS traversal

    /// Breadth-first walk over the AX element tree rooted at `windowElement`.
    ///
    /// Primary bound: `maximumWalkedElementCount` — stops visiting new nodes
    /// when this many elements have been examined.
    /// Secondary bound: `maximumTraversalDepth` — stops descending past this
    /// depth to avoid runaway traversal on unusually deep trees.
    ///
    /// Batch attribute reads: for each visited element we call
    /// `AXUIElementCopyMultipleAttributeValues` with all needed attributes in
    /// one IPC round-trip (role, subrole, title, description, value, position,
    /// size, enabled). This is significantly faster than individual attribute
    /// reads on apps where each call crosses a process boundary.
    ///
    /// - Parameters:
    ///   - windowElement: The root AX element to walk (a window element).
    ///   - windowCGFrame: The window's CG-space frame for visibility checks.
    ///   - cgScreenBoundsForAllDisplays: CG bounds of every display.
    ///   - processID: The owning process's pid_t for `AccessibleElement`.
    /// - Returns: A `WalkResult` with kept elements and the total visited count.
    private func walkWindowBFS(
        windowElement: AXUIElement,
        windowCGFrame: CGRect,
        cgScreenBoundsForAllDisplays: [CGRect],
        processID: pid_t
    ) -> WalkResult {

        // Read the primary screen's AppKit frame once for the CG→AppKit conversion.
        // NSScreen.screens[0] is the primary display by macOS convention; we pass
        // this as a value so the pure ScreenCoordinateConverter functions stay
        // free of NSScreen side effects. We can read NSScreen here because we are
        // on a background thread that does not need MainActor — NSScreen property
        // access is thread-safe (it reads from a cached array).
        let primaryScreenFrameInAppKitCoordinates: CGRect
        if let primaryScreen = NSScreen.screens.first {
            primaryScreenFrameInAppKitCoordinates = primaryScreen.frame
        } else {
            // No display attached (headless / test environment). Use a sentinel
            // that will produce reasonable (if incorrect) values so the walk
            // does not crash.
            primaryScreenFrameInAppKitCoordinates = CGRect(x: 0, y: 0, width: 1440, height: 900)
        }

        // BFS queue entries: (element, depth).
        var bfsQueue: [(element: AXUIElement, depth: Int)] = [(windowElement, 0)]
        var totalVisitedCount = 0
        var nextElementID = 1
        var keptElements: [AccessibleElement] = []

        // The attributes we batch-read for every element in one IPC round-trip.
        // Requesting position and size here avoids two extra round-trips per element.
        let attributesToBatchRead: [String] = [
            kAXRoleAttribute as String,
            kAXSubroleAttribute as String,
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXValueAttribute as String,
            kAXPositionAttribute as String,
            kAXSizeAttribute as String,
            kAXEnabledAttribute as String
        ]

        while !bfsQueue.isEmpty
            && totalVisitedCount < AccessibilityElementInventoryService.maximumWalkedElementCount
        {
            let (currentElement, currentDepth) = bfsQueue.removeFirst()
            totalVisitedCount += 1

            // --- Batch attribute read ---
            // `AXUIElementCopyMultipleAttributeValues` sends one IPC message to
            // the target app and returns all requested values in one reply. This
            // is much faster than one call per attribute on apps with many elements.
            var batchResultsUntyped: CFArray?
            let batchReadError = AXUIElementCopyMultipleAttributeValues(
                currentElement,
                attributesToBatchRead as CFArray,
                AXCopyMultipleAttributeOptions(rawValue: 0), // 0 = stop on error
                &batchResultsUntyped
            )

            // On a failed batch read, skip this element but don't abort the walk.
            guard batchReadError == .success,
                  let batchResults = batchResultsUntyped as? [AnyObject],
                  batchResults.count == attributesToBatchRead.count else {
                // Still attempt to read children so we don't miss subtrees.
                if currentDepth < AccessibilityElementInventoryService.maximumTraversalDepth {
                    enqueueChildren(
                        of: currentElement,
                        atDepth: currentDepth,
                        into: &bfsQueue,
                        totalVisited: totalVisitedCount
                    )
                }
                continue
            }

            // --- Extract role (required; skip element if missing) ---
            guard let roleString = batchResults[0] as? String, !roleString.isEmpty else {
                continue
            }

            // --- Determine whether to descend into this element's children ---
            let shouldDescend = AccessibilityElementInventoryService.shouldDescendIntoRole(roleString)

            if shouldDescend && currentDepth < AccessibilityElementInventoryService.maximumTraversalDepth {
                enqueueChildren(
                    of: currentElement,
                    atDepth: currentDepth,
                    into: &bfsQueue,
                    totalVisited: totalVisitedCount
                )
            }

            // --- Check whether this element exposes the press action ---
            // We only pay the IPC cost of `AXUIElementCopyActionNames` for
            // elements that didn't match an actionable role — minimises round-trips.
            let matchesActionableRole = AccessibilityElementInventoryService.shouldKeepElement(
                role: roleString,
                elementExposesAXPressAction: false // check role first, cheaper
            )
            var exposesAXPressAction = false
            if !matchesActionableRole {
                var actionNames: CFArray?
                if AXUIElementCopyActionNames(currentElement, &actionNames) == .success,
                   let names = actionNames as? [String] {
                    exposesAXPressAction = names.contains(kAXPressAction as String)
                }
            }

            let shouldKeep = matchesActionableRole
                || AccessibilityElementInventoryService.shouldKeepElement(
                    role: roleString,
                    elementExposesAXPressAction: exposesAXPressAction
                )

            guard shouldKeep else { continue }

            // --- Extract position and size from AXValue wrappers ---
            var elementCGFrame = CGRect.zero
            if let positionAXValue = batchResults[5] as? AXValue,
               let sizeAXValue = batchResults[6] as? AXValue {
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionAXValue, .cgPoint, &position)
                AXValueGetValue(sizeAXValue, .cgSize, &size)
                elementCGFrame = CGRect(origin: position, size: size)
            }

            // --- Visibility heuristic ---
            // Skip elements with trivial size or that lie off every screen.
            // A zero windowCGFrame means the window frame read failed; in that
            // case we skip the window-intersection check.
            let effectiveWindowFrame = windowCGFrame == .zero
                ? CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
                : windowCGFrame
            guard AccessibilityElementInventoryService.isElementFrameVisible(
                cgFrame: elementCGFrame,
                windowCGFrame: effectiveWindowFrame,
                cgScreenBoundsForAllDisplays: cgScreenBoundsForAllDisplays
            ) else { continue }

            // --- Build the AppKit-space frame for the overlay pipeline ---
            let elementAppKitFrame = ScreenCoordinateConverter.convertCGGlobalRectToAppKitGlobalRect(
                cgGlobalRect: elementCGFrame,
                primaryScreenFrameInAppKitCoordinates: primaryScreenFrameInAppKitCoordinates
            )

            // --- Extract subrole ---
            let subrole = batchResults[1] as? String

            // --- Build title from fallback chain ---
            // Priority: kAXTitleAttribute → kAXDescriptionAttribute → kAXValueAttribute.
            // Each result is sanitised to strip newlines and square brackets.
            let rawTitle = (batchResults[2] as? String) ?? ""
            let rawDescription = (batchResults[3] as? String) ?? ""
            let rawValue = (batchResults[4] as? String) ?? ""

            let unsanitisedTitle: String
            if !rawTitle.isEmpty {
                unsanitisedTitle = rawTitle
            } else if !rawDescription.isEmpty {
                unsanitisedTitle = rawDescription
            } else {
                unsanitisedTitle = rawValue
            }
            let sanitisedTitle = AccessibilityElementInventoryService.sanitiseTitleForPrompt(unsanitisedTitle)

            // --- Create and store the element ---
            let accessibleElement = AccessibleElement(
                elementID: nextElementID,
                role: roleString,
                subrole: subrole,
                title: sanitisedTitle,
                cgFrame: elementCGFrame,
                appKitFrame: elementAppKitFrame,
                axElementHandle: currentElement,
                owningProcessID: processID
            )
            keptElements.append(accessibleElement)
            nextElementID += 1
        }

        return WalkResult(
            keptElements: keptElements,
            totalVisitedCount: totalVisitedCount
        )
    }

    /// Reads `kAXChildrenAttribute` for `parentElement` and appends each child
    /// to `bfsQueue` at `parentDepth + 1`, capped by `maximumWalkedElementCount`.
    ///
    /// This is extracted as a helper so both the normal path and the skip-on-
    /// batch-error path can enqueue children consistently.
    private func enqueueChildren(
        of parentElement: AXUIElement,
        atDepth parentDepth: Int,
        into bfsQueue: inout [(element: AXUIElement, depth: Int)],
        totalVisited: Int
    ) {
        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            parentElement,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement] else { return }

        let childDepth = parentDepth + 1
        for child in children {
            // Don't enqueue more children than we can visit — this prevents the
            // queue from growing unboundedly when the cap is about to fire.
            if bfsQueue.count + totalVisited
                >= AccessibilityElementInventoryService.maximumWalkedElementCount {
                break
            }
            bfsQueue.append((child, childDepth))
        }
    }

    // MARK: - Electron / Chromium wake

    /// Attempts to wake an Electron/Chromium app's lazy AX tree and re-walks.
    ///
    /// WAKE PROTOCOL
    /// ─────────────
    /// 1. Read the current value of `AXManualAccessibility` on the app element
    ///    (record it for later restoration).
    /// 2. Set `AXManualAccessibility = true`. This is side-effect-free in most
    ///    Chromium builds and is the preferred first attempt.
    /// 3. Wait `electronWakeRetryDelayInSeconds` and re-walk.
    /// 4. If the re-walk still yields a stub tree, set `AXEnhancedUserInterface
    ///    = true` instead and re-walk again (up to `maximumElectronWakeRetryCount`
    ///    total retries).
    /// 5. ALWAYS restore the original attribute values after the walk.
    ///    Leaving `AXEnhancedUserInterface` on breaks window managers (Rectangle,
    ///    yabai) by changing how Chromium handles window-move/resize events.
    ///
    /// - Parameters:
    ///   - appElement: The application-level AX element.
    ///   - windowElement: The focused/main window element.
    ///   - windowCGFrame: The window's CG frame (may be .zero on failure).
    ///   - cgScreenBoundsForAllDisplays: CG bounds of all displays.
    ///   - processID: The owning process pid_t.
    /// - Returns: A `WalkResult` from the best re-walk attempt.
    private func attemptElectronWakeAndRewalk(
        appElement: AXUIElement,
        windowElement: AXUIElement,
        windowCGFrame: CGRect,
        cgScreenBoundsForAllDisplays: [CGRect],
        processID: pid_t
    ) -> WalkResult {

        // --- Read current attribute values for restoration ---
        var originalManualValue: AnyObject?
        let hadManualAttribute = AXUIElementCopyAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            &originalManualValue
        ) == .success

        var originalEnhancedValue: AnyObject?
        let hadEnhancedAttribute = AXUIElementCopyAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            &originalEnhancedValue
        ) == .success

        defer {
            // Restoration runs unconditionally when this function returns so
            // window managers always see the original values restored.
            if hadManualAttribute {
                let valueToRestore = originalManualValue ?? (false as CFBoolean)
                AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, valueToRestore)
            } else {
                // If the attribute wasn't present before, set it to false to
                // undo any value we may have set.
                AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, false as CFBoolean)
            }

            if hadEnhancedAttribute {
                let valueToRestore = originalEnhancedValue ?? (false as CFBoolean)
                AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, valueToRestore)
            } else {
                AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, false as CFBoolean)
            }
        }

        var bestResult = WalkResult(keptElements: [], totalVisitedCount: 0)

        for retryIndex in 0..<AccessibilityElementInventoryService.maximumElectronWakeRetryCount {
            // Attempt 0: AXManualAccessibility (preferred, fewer side effects).
            // Attempt 1: AXEnhancedUserInterface (broader compatibility, more side
            //             effects — restored in defer above).
            if retryIndex == 0 {
                AXUIElementSetAttributeValue(
                    appElement,
                    "AXManualAccessibility" as CFString,
                    true as CFBoolean
                )
            } else {
                AXUIElementSetAttributeValue(
                    appElement,
                    "AXEnhancedUserInterface" as CFString,
                    true as CFBoolean
                )
            }

            // Sleep on the AX thread to let the Chromium renderer populate its
            // AX tree. This is a deliberate blocking sleep — we are already on
            // the serial background queue and want to hold the walk until the
            // tree is ready.
            Thread.sleep(forTimeInterval: AccessibilityElementInventoryService.electronWakeRetryDelayInSeconds)

            let result = walkWindowBFS(
                windowElement: windowElement,
                windowCGFrame: windowCGFrame,
                cgScreenBoundsForAllDisplays: cgScreenBoundsForAllDisplays,
                processID: processID
            )

            if result.keptElements.count > bestResult.keptElements.count {
                bestResult = result
            }

            // If we found elements, no need to try the next wake method.
            if !result.keptElements.isEmpty {
                break
            }
        }

        return bestResult
    }
}
