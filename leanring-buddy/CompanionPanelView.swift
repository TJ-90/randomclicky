//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var emailInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show Clicky toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClickyCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            // Act mode section — shown when the user has completed onboarding
            // and all permissions are granted (same gate as the model picker).
            // Hidden during an active walkthrough so the section list stays clean.
            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
                && companionManager.walkthroughController.phase == .inactive {
                Spacer()
                    .frame(height: 12)

                actModeSection
                    .padding(.horizontal, 16)
            }

            // Active walkthrough section — shown whenever a walkthrough is in
            // progress (phase != .inactive). Cross-fades in/out by opacity so the
            // panel doesn't jump; the section is always in the view tree.
            if companionManager.walkthroughController.phase != .inactive {
                Spacer()
                    .frame(height: 16)

                activeWalkthroughSection
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
                && companionManager.walkthroughController.phase == .inactive {
                Spacer()
                    .frame(height: 16)

                dmFarzaButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Clicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Clicky.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Farza. This is Clicky.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Clicky will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            // Email capture removed — onboarding goes straight to Start.
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        let axHealthState = companionManager.accessibilityHealthState

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                        .frame(width: 16)

                    Text("Accessibility")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                if isGranted && axHealthState == .staleGrantNeedsReToggle {
                    // Stale-TCC hint: the grant exists in TCC but the AX subsystem
                    // is not servicing calls. Show a warning badge instead of
                    // the normal "Granted" green dot so the user knows to re-toggle.
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.warning)
                        Text("Stale")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.warning)
                    }
                } else if isGranted {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(DS.Colors.success)
                            .frame(width: 6, height: 6)
                        Text("Granted")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.success)
                    }
                } else {
                    HStack(spacing: 6) {
                        Button(action: {
                            // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                            // on first attempt, then opens System Settings on subsequent attempts.
                            WindowPositionManager.requestAccessibilityPermission()
                        }) {
                            Text("Grant")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textOnAccent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(DS.Colors.accent)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()

                        Button(action: {
                            // Reveals the app in Finder so the user can drag it into
                            // the Accessibility list if it doesn't appear automatically
                            // (common with unsigned dev builds).
                            WindowPositionManager.revealAppInFinder()
                            WindowPositionManager.openAccessibilitySettings()
                        }) {
                            Text("Find App")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
            .padding(.vertical, 6)

            // Stale-TCC hint row — shown ONLY when the grant is present but stale.
            // Opening System Settings and toggling the grant off then on forces macOS
            // to issue a fresh TCC entry, which cures the kAXErrorAPIDisabled failure.
            // The hint uses the deep-link URL pattern (same as requestAccessibilityPermission).
            if isGranted && axHealthState == .staleGrantNeedsReToggle {
                AccessibilityStaleGrantHintRow(
                    onOpenSettings: {
                        WindowPositionManager.openAccessibilitySettings()
                        // Re-run the self-check after the user returns from System
                        // Settings so the hint disappears automatically once they
                        // re-toggle the grant.
                        Task {
                            await companionManager.performAccessibilityHealthSelfCheck()
                        }
                    }
                )
                .padding(.bottom, 6)
            }
        }
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Act Mode Section (U12)

    /// Act-mode toggle section. Shown when the user has completed onboarding
    /// and all permissions are granted.
    ///
    /// Styling exactly matches the `settingsSection` / walkthrough section pattern:
    /// section header in PERMISSIONS label style, the toggle row uses the same
    /// padding and spacing as other rows, and the explanatory copy uses
    /// `textTertiary` at 11pt matching the "Quit and reopen after granting" hint
    /// in the screen recording row.
    private var actModeSection: some View {
        VStack(spacing: 2) {
            // Section header — matches PERMISSIONS label style exactly
            Text("ACT MODE")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            actModeToggleRow
        }
    }

    /// The toggle row for act mode.
    ///
    /// Uses `.tint(DS.Colors.accent)` and `.scaleEffect(0.8)` matching the
    /// `showClickyCursorToggleRow` pattern already in this file. Pointer cursor
    /// and hover feedback on every interactive element per AGENTS.md rules.
    private var actModeToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Act mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                // Toggle bound to the @Published wrapper on CompanionManager.
                // Writing through `setActModeEnabled` keeps UserDefaults and the
                // @Published state in sync and fires analytics.
                Toggle("", isOn: Binding(
                    get: { companionManager.isActModeEnabledPublished },
                    set: { companionManager.setActModeEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
                // Pointer cursor on the toggle itself so it communicates clickability.
                .pointerCursor()
            }
            .padding(.vertical, 4)

            // Explanatory copy — explains what act mode does and that every
            // action requires confirmation. Matches the screen recording row's
            // secondary hint style (11pt textTertiary).
            Text("clicky can click and type for you — every action needs your confirmation first")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Active Walkthrough Section

    /// Panel section shown while a guided walkthrough is in progress.
    /// Displays the current step progress, an "I did it" action button, and a
    /// "Cancel walkthrough" escape button.
    ///
    /// Styling follows the existing section/button patterns in this file exactly:
    /// section label uses the PERMISSIONS header style, action buttons use the
    /// same padding/corner-radius/hover pattern as the existing Grant/Start buttons,
    /// and the cancel uses the same tertiary text-button style as footer actions.
    private var activeWalkthroughSection: some View {
        let snapshot = companionManager.walkthroughController.currentSnapshot
        let currentStepDisplayNumber = snapshot.currentStepIndex + 1
        let totalStepCount = snapshot.totalStepCount
        let isVerifying = companionManager.walkthroughController.phase == .verifying

        return VStack(spacing: 2) {
            // Section header — same style as PERMISSIONS label
            Text("WALKTHROUGH IN PROGRESS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            // Step progress row
            HStack(spacing: 6) {
                // Step badge — matching the overlay chip badge style
                Text(totalStepCount > 0
                     ? "Step \(currentStepDisplayNumber) of \(totalStepCount)"
                     : "Step \(currentStepDisplayNumber)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(DS.Colors.overlayCursorBlue)
                    )
                    .fixedSize()

                // Current step instruction — read from declaredSteps
                if snapshot.currentStepIndex < snapshot.declaredSteps.count {
                    Text(snapshot.declaredSteps[snapshot.currentStepIndex].instruction)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)

            Spacer()
                .frame(height: 8)

            // "I did it" button — primary CTA for the walkthrough.
            // Disabled while a verification turn is in flight (.verifying phase)
            // to prevent double-submission.
            WalkthroughIDidiItButton(
                isVerifying: isVerifying,
                onTap: {
                    companionManager.runWalkthroughVerificationTurn()
                }
            )

            Spacer()
                .frame(height: 6)

            // "Cancel walkthrough" — low-emphasis escape hatch. Uses the same
            // footer button style as "Quit Clicky" to communicate low hierarchy.
            WalkthroughCancelButton(
                onTap: {
                    companionManager.cancelActiveWalkthrough()
                }
            )
        }
    }

    // MARK: - Show Clicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Clicky")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - DM Farza Button

    private var dmFarzaButton: some View {
        Button(action: {
            if let url = URL(string: "https://x.com/farzatv") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Got feedback? DM me")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, anything — I read every message.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Clicky")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Watch Onboarding Again")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {

        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}

// MARK: - Walkthrough Panel Buttons

/// "I did it" primary action button shown in the active-walkthrough panel section.
/// Calls companionManager.runWalkthroughVerificationTurn() on tap.
/// Disabled (visually and functionally) while phase == .verifying so the user
/// cannot double-submit before a verdict arrives.
private struct WalkthroughIDidiItButton: View {
    let isVerifying: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if isVerifying {
                    // Subtle spinner while Claude is checking — communicates
                    // that something is happening without hiding the label.
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                Text(isVerifying ? "Checking…" : "I did it")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isVerifying ? DS.Colors.textSecondary : DS.Colors.textOnAccent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(buttonFillColor)
            )
        }
        .buttonStyle(.plain)
        .disabled(isVerifying)
        // Only attach pointer cursor when enabled — disabled state keeps
        // the default arrow cursor so the user understands it's not clickable.
        .pointerCursor(isEnabled: !isVerifying)
        .onHover { hovering in
            guard !isVerifying else { return }
            isHovered = hovering
        }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        .animation(.easeOut(duration: DS.Animation.fast), value: isVerifying)
    }

    private var buttonFillColor: Color {
        if isVerifying {
            return DS.Colors.accent.opacity(0.35)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

/// "Cancel walkthrough" low-emphasis button shown in the active-walkthrough panel section.
/// Calls companionManager.cancelActiveWalkthrough() on tap.
/// Uses the footer button style (textTertiary -> textPrimary on hover) so it
/// communicates escape-hatch hierarchy without drawing too much attention.
private struct WalkthroughCancelButton: View {
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11, weight: .medium))
                Text("Cancel walkthrough")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        .padding(.vertical, 2)
    }
}

// MARK: - Stale accessibility grant hint row (U12)

/// Hint row shown inside `accessibilityPermissionRow` when
/// `accessibilityHealthState == .staleGrantNeedsReToggle`.
///
/// The TCC entry exists (`AXIsProcessTrusted()` returns true) but the AX
/// subsystem is refusing calls — a common symptom after re-signing a dev build
/// or after a macOS update that invalidates the cached grant. The fix is to
/// toggle the grant off and back on in System Settings → Privacy & Security →
/// Accessibility.
///
/// Styled as a compact warning hint: amber text, indented under the row icon,
/// smaller than normal rows so it reads as contextual help rather than a
/// primary action.
private struct AccessibilityStaleGrantHintRow: View {
    /// Called when the user taps "Open Settings". The parent re-runs the
    /// self-check after the user returns so the hint disappears automatically.
    let onOpenSettings: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("accessibility looks granted but isn't responding — toggle it off and on in System Settings → Privacy & Security → Accessibility")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onOpenSettings) {
                Text("Open Settings")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isHovered ? DS.Colors.warning : DS.Colors.warningText)
                    .underline()
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hoveringOverLink in
                isHovered = hoveringOverLink
            }
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        }
        // Indent to align under the "Accessibility" label text (icon width 16 + spacing 8)
        .padding(.leading, 24)
        .padding(.top, 2)
    }
}
