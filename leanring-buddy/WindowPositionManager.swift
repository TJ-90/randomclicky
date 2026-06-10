//
//  WindowPositionManager.swift
//  leanring-buddy
//
//  Manages positioning the app window on the right edge of the screen
//  and shrinking overlapping windows from other apps via the Accessibility API.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit

enum PermissionRequestPresentationDestination: Equatable {
    case alreadyGranted
    case systemPrompt
    case systemSettings
}

// MARK: - Accessibility health state (U12 stale-TCC self-check)

/// Describes the health of the Accessibility (TCC) grant from the perspective
/// of Clicky's runtime.
///
/// macOS sometimes leaves `AXIsProcessTrusted()` returning `true` even though
/// the grant is effectively stale — this happens after re-signing a dev build or
/// after a macOS update that invalidates the cached grant. In that state, all AX
/// API calls fail silently or return `kAXErrorAPIDisabled`. The `.staleGrantNeedsReToggle`
/// case catches exactly this situation so the panel can surface a "re-toggle
/// Accessibility" hint instead of failing silently.
enum AccessibilityHealthState: Equatable {
    /// `AXIsProcessTrusted()` is true AND a trivial AX read succeeded.
    /// Normal operation — no action needed.
    case healthy

    /// `AXIsProcessTrusted()` is true BUT a trivial AX read failed.
    /// The TCC entry is stale (common after re-signing dev builds or macOS updates).
    /// User must toggle the grant off and back on in System Settings.
    case staleGrantNeedsReToggle

    /// `AXIsProcessTrusted()` is false. The grant was never given or was revoked.
    /// Show the normal "Grant" accessibility permission row.
    case notGranted
}

@MainActor
class WindowPositionManager {
    private static var hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch = false
    private static var hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch = false
    private static let hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"

    /// Returns true when the Mac currently has more than one connected display.
    /// Uses AppKit's screen list, which is available without ScreenCaptureKit's
    /// shareable-content permission prompt.
    static func currentMacHasMultipleDisplays() -> Bool {
        NSScreen.screens.count > 1
    }

    // MARK: - Accessibility Permission

    /// Returns true if the app has Accessibility permission.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Presents exactly one permission path per tap: the system prompt on the first
    /// attempt, then System Settings on later attempts after macOS has already shown
    /// its one-time alert.
    @discardableResult
    static func requestAccessibilityPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasAccessibilityPermission(),
            hasAttemptedSystemPrompt: hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .systemSettings:
            openAccessibilitySettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Accessibility pane.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveals the running app bundle in Finder so the user can drag it into
    /// the Accessibility list if it doesn't appear automatically.
    static func revealAppInFinder() {
        guard let appURL = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    // MARK: - Screen Recording Permission

    /// Returns true if Screen Recording permission is granted.
    static func hasScreenRecordingPermission() -> Bool {
        let hasScreenRecordingPermissionNow = CGPreflightScreenCaptureAccess()
        if hasScreenRecordingPermissionNow {
            UserDefaults.standard.set(true, forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
        }
        return hasScreenRecordingPermissionNow
    }

    /// Returns true when the app should proceed with session launch without showing
    /// the permission gate again. This intentionally falls back to the last known
    /// granted state because CGPreflightScreenCaptureAccess() can sometimes return a
    /// false negative even though the user has already approved the app.
    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() -> Bool {
        shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: hasScreenRecordingPermission(),
            hasPreviouslyConfirmedScreenRecordingPermission: UserDefaults.standard.bool(forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
        )
    }

    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
        hasScreenRecordingPermissionNow: Bool,
        hasPreviouslyConfirmedScreenRecordingPermission: Bool
    ) -> Bool {
        hasScreenRecordingPermissionNow || hasPreviouslyConfirmedScreenRecordingPermission
    }

    static func clearPreviouslyConfirmedScreenRecordingPermission() {
        UserDefaults.standard.removeObject(forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
    }

    /// Prompts the system dialog for Screen Recording permission.
    /// Uses the system prompt once, then opens System Settings on later attempts so
    /// the user never gets the prompt and the Settings pane at the same time.
    @discardableResult
    static func requestScreenRecordingPermission() -> PermissionRequestPresentationDestination {
        let presentationDestination = permissionRequestPresentationDestination(
            hasPermissionNow: hasScreenRecordingPermission(),
            hasAttemptedSystemPrompt: hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch = true
            _ = CGRequestScreenCaptureAccess()
        case .systemSettings:
            openScreenRecordingSettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Screen Recording pane.
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    static func permissionRequestPresentationDestination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool
    ) -> PermissionRequestPresentationDestination {
        if hasPermissionNow {
            return .alreadyGranted
        }

        if hasAttemptedSystemPrompt {
            return .systemSettings
        }

        return .systemPrompt
    }

    // MARK: - Stale-TCC self-check (U12)

    /// Pure decision function for the Accessibility health self-check.
    ///
    /// This is the U12 stale-TCC check described in the plan's KTD
    /// "Permissions: reuse, but self-check". It is a pure static function so it
    /// is directly unit-testable without any live AX calls.
    ///
    /// The three outcomes map directly to the panel's UI response:
    /// - `.healthy`                → show "Granted" badge as normal
    /// - `.staleGrantNeedsReToggle` → show a re-toggle hint row instead of the
    ///   normal "Granted" badge — the user must toggle the grant off/on in
    ///   System Settings → Privacy & Security → Accessibility
    /// - `.notGranted`             → show the existing "Grant" button row
    ///
    /// - Parameters:
    ///   - isProcessTrusted: The result of `AXIsProcessTrusted()` at call time.
    ///   - trivialAXReadSucceeded: Whether a cheap one-attribute AX read against
    ///     the frontmost application returned a non-error result. Obtained by
    ///     `CompanionManager.performAccessibilityHealthSelfCheck()` on the shared
    ///     AX serial queue. Pass `false` when the read returned any
    ///     `kAXError*` code, true when it returned `.success` or any data value.
    /// - Returns: The `AccessibilityHealthState` the panel should reflect.
    static func accessibilityHealthState(
        isProcessTrusted: Bool,
        trivialAXReadSucceeded: Bool
    ) -> AccessibilityHealthState {
        // If the OS does not consider the process trusted at all, the grant is
        // simply absent — show the normal request flow.
        guard isProcessTrusted else {
            return .notGranted
        }

        // Trusted + read succeeded → everything is working normally.
        if trivialAXReadSucceeded {
            return .healthy
        }

        // Trusted + read FAILED → stale grant. The TCC entry exists but the AX
        // subsystem won't service calls. The user needs to toggle the grant off
        // and on in System Settings to refresh the permission.
        return .staleGrantNeedsReToggle
    }

    // MARK: - Window Positioning

    /// Positions the app's main window pinned to the right edge of the screen
    /// that contains the given display ID, vertically centered.
    static func pinMainWindowToRight(onDisplayID displayID: CGDirectDisplayID?) {
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }

        // Find the NSScreen matching the selected display, or fall back to the screen
        // the window is currently on, or finally the main screen.
        let targetScreen: NSScreen
        if let displayID,
           let matchingScreen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            targetScreen = matchingScreen
        } else if let currentScreen = mainWindow.screen {
            targetScreen = currentScreen
        } else if let mainScreen = NSScreen.main {
            targetScreen = mainScreen
        } else {
            return
        }

        let visibleFrame = targetScreen.visibleFrame
        let windowSize = mainWindow.frame.size

        let x = visibleFrame.maxX - windowSize.width
        let y = visibleFrame.minY + (visibleFrame.height - windowSize.height) / 2.0

        mainWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Shrink Overlapping Windows

    /// Checks if the frontmost (non-self) app's focused window overlaps our app window
    /// on the same monitor and, if so, shrinks it so it no longer overlaps.
    /// Only operates if both windows are on the same screen as `targetDisplayID`.
    static func shrinkOverlappingFocusedWindow(targetDisplayID: CGDirectDisplayID?) {
        guard hasAccessibilityPermission() else { return }
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        guard let mainScreen = mainWindow.screen else { return }

        // Only operate if the main window is on the target display
        if let targetDisplayID, mainScreen.displayID != targetDisplayID {
            return
        }

        // Get the frontmost application that isn't us
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get the focused window of the front app
        var focusedWindowValue: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)
        guard focusedResult == .success, let focusedWindow = focusedWindowValue else { return }

        // Get position and size of the focused window
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return
        }

        var otherPosition = CGPoint.zero
        var otherSize = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &otherPosition),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &otherSize) else {
            return
        }

        // The other window's frame in screen coordinates (top-left origin from AX API).
        // Convert to check if it's on the same screen as our window.
        let otherRight = otherPosition.x + otherSize.width
        let ourLeft = mainWindow.frame.origin.x

        // Check that the other window is on the same screen by verifying its origin
        // falls within the target screen's bounds.
        let screenFrame = mainScreen.frame
        let otherCenterX = otherPosition.x + otherSize.width / 2
        // AX uses top-left origin, NSScreen uses bottom-left. Convert AX Y to NSScreen Y.
        let otherNSScreenY = screenFrame.maxY - otherPosition.y - otherSize.height
        let otherCenterY = otherNSScreenY + otherSize.height / 2
        let otherCenter = NSPoint(x: otherCenterX, y: otherCenterY)

        guard screenFrame.contains(otherCenter) else { return }

        // If the other window's right edge extends past our window's left edge, shrink it.
        if otherRight > ourLeft {
            let newWidth = ourLeft - otherPosition.x
            guard newWidth > 200 else { return } // Don't shrink too small

            var newSize = CGSize(width: newWidth, height: otherSize.height)
            guard let newSizeValue = AXValueCreate(.cgSize, &newSize) else { return }
            AXUIElementSetAttributeValue(focusedWindow as! AXUIElement, kAXSizeAttribute as CFString, newSizeValue)
        }
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// The CGDirectDisplayID for this screen.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}
