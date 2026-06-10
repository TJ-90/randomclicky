//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Publishes a `Void` event whenever the Esc key (keyCode 53) is observed
    /// by the CGEvent tap. This is the act-mode kill-switch channel.
    ///
    /// WHY A SEPARATE PUBLISHER, NOT PART OF shortcutTransitionPublisher
    /// ─────────────────────────────────────────────────────────────────────────
    /// `shortcutTransitionPublisher` carries push-to-talk transitions (press /
    /// release of ctrl+option). Esc is a completely different semantic — it is
    /// an abort signal for pending act-mode actions — so a separate publisher
    /// keeps the two channels decoupled. Callers that don't care about act-mode
    /// abort (e.g. the TTS pipeline) don't need to filter a combined stream.
    ///
    /// LISTEN-ONLY TAP IS SUFFICIENT FOR ABORT
    /// ─────────────────────────────────────────────────────────────────────────
    /// The tap cannot swallow the Esc event. Esc may therefore also reach the
    /// target app (e.g. dismissing a dialog in the frontmost window). This is
    /// an accepted, documented side-effect: the user's intent is clearly "stop
    /// everything", and Esc reaching the target app is typically harmless (it
    /// dismisses dialogs, deselects text, etc.) or beneficial.
    let escKeyObservedPublisher = PassthroughSubject<Void, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore synthetic events posted by ActionExecutionService.
        // Without this guard the HID-level mouse-moved event that precedes a
        // synthetic click would be seen by this tap. If the user is currently
        // holding the push-to-talk shortcut, that stray event could cause a
        // spurious shortcut transition. More importantly, the user-activity
        // sampler inside ActionExecutionService watches HID event counters to
        // pause while the user is typing/moving; without this tag the service's
        // own mouse-moved event would reset that counter and make the pause
        // logic incorrectly believe the user is active, triggering a self-stall.
        if ActionExecutionService.isClickySyntheticEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Esc kill-switch observation for act-mode abort.
        // keyCode 53 = Escape on all standard Apple keyboards (US and international).
        // We only publish on keyDown to fire exactly once per press — flagsChanged
        // and keyUp for Esc are not meaningful for the abort semantic.
        // The tap is listen-only so the Esc may also reach the frontmost app — this
        // is acceptable and documented in escKeyObservedPublisher's comment above.
        let escapeKeyCode: UInt16 = 53
        if eventType == .keyDown && eventKeyCode == escapeKeyCode {
            escKeyObservedPublisher.send()
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
