//
//  CompanionResponseOverlay.swift
//  leanring-buddy
//
//  Cursor-following overlay that displays streaming AI response text.
//  Uses a non-activating NSPanel so it floats above all apps without
//  stealing focus, and repositions itself near the mouse cursor each frame.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var streamingResponseText: String = ""
    @Published var isShowingResponse: Bool = false
}

// MARK: - Overlay Manager

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var cursorTrackingTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?

    /// The horizontal offset from the cursor to the left edge of the overlay panel.
    private let cursorOffsetX: CGFloat = 22
    /// The vertical offset from the cursor downward to the top edge of the overlay panel.
    private let cursorOffsetY: CGFloat = 6
    /// Maximum width of the overlay panel.
    private let overlayMaxWidth: CGFloat = 340

    func showOverlayAndBeginStreaming() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        overlayViewModel.streamingResponseText = ""
        overlayViewModel.isShowingResponse = true
        createOverlayPanelIfNeeded()
        startCursorTracking()
        overlayPanel?.alphaValue = 1
        overlayPanel?.orderFrontRegardless()
    }

    func updateStreamingText(_ accumulatedText: String) {
        overlayViewModel.streamingResponseText = accumulatedText
        resizePanelToFitContent()
    }

    func finishStreaming() {
        // Keep the response visible for a few seconds after streaming ends,
        // then fade out so the user has time to read the last chunk.
        let hideWork = DispatchWorkItem { [weak self] in
            self?.fadeOutAndHide()
        }
        autoHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: hideWork)
    }

    func hideOverlay() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        stopCursorTracking()
        overlayViewModel.isShowingResponse = false
        overlayViewModel.streamingResponseText = ""
        overlayPanel?.orderOut(nil)
    }

    // MARK: - Private

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: overlayMaxWidth, height: 40)
        let responseOverlayPanel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        responseOverlayPanel.level = .statusBar
        responseOverlayPanel.isOpaque = false
        responseOverlayPanel.backgroundColor = .clear
        responseOverlayPanel.hasShadow = false
        responseOverlayPanel.ignoresMouseEvents = true
        responseOverlayPanel.hidesOnDeactivate = false
        responseOverlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        responseOverlayPanel.isExcludedFromWindowsMenu = true

        let hostingView = NSHostingView(
            rootView: CompanionResponseOverlayView(viewModel: overlayViewModel)
                .frame(maxWidth: overlayMaxWidth)
        )
        hostingView.frame = initialFrame
        responseOverlayPanel.contentView = hostingView

        overlayPanel = responseOverlayPanel
    }

    private func startCursorTracking() {
        // 60fps cursor tracking so the panel stays glued to the mouse
        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanelNearCursor()
            }
        }
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
    }

    private func repositionPanelNearCursor() {
        guard let overlayPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let panelSize = overlayPanel.frame.size

        // Position the panel to the right of and slightly below the cursor.
        // In macOS screen coordinates, Y increases upward, so "below" means
        // subtracting from the cursor Y.
        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelSize.height

        // Clamp to the visible frame of the screen containing the cursor
        // so the panel never goes off-screen.
        if let currentScreen = screenContainingPoint(mouseLocation) {
            let visibleFrame = currentScreen.visibleFrame

            // If the panel would go off the right edge, flip it to the left of the cursor
            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelSize.width
            }

            // If the panel would go below the bottom edge, push it above the cursor
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }

            // Final clamp
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        overlayPanel.setFrameOrigin(CGPoint(x: panelOriginX, y: panelOriginY))
    }

    private func resizePanelToFitContent() {
        guard let overlayPanel, let contentView = overlayPanel.contentView else { return }

        let fittingSize = contentView.fittingSize
        let newWidth = min(fittingSize.width, overlayMaxWidth)
        let newHeight = fittingSize.height

        // Keep the panel origin relative to the cursor (the timer handles that),
        // but update the frame size so the content fits.
        var frame = overlayPanel.frame
        let heightDelta = newHeight - frame.height
        frame.size = CGSize(width: newWidth, height: newHeight)
        // Adjust origin Y so the panel grows upward (toward the cursor), not downward
        frame.origin.y -= heightDelta
        overlayPanel.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func fadeOutAndHide() {
        guard let overlayPanel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            overlayPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.hideOverlay()
            }
        })
    }

    private func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

// MARK: - SwiftUI View

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel

    var body: some View {
        if viewModel.isShowingResponse {
            Text(viewModel.streamingResponseText.isEmpty ? "..." : viewModel.streamingResponseText)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
                )
        }
    }
}

// MARK: - Walkthrough Step Chip

/// A persistent chip displayed near the buddy cursor that shows the current
/// walkthrough step number, instruction, and — during verification — a subtle
/// "checking…" affordance.
///
/// Rendered as a ZStack layer in BlueCursorView and cross-faded by opacity
/// based on walkthroughController.phase (never inserted/removed from the tree).
/// Positioned relative to the buddy's current cursorPosition so it stays
/// glued to the cursor just like the response text bubble.
///
/// DESIGN RATIONALE
/// The chip uses DS.Colors.surface1 as its fill (same as the response bubble)
/// with the overlay blue accent for the step-number badge and a verifying-state
/// shimmer. This keeps it visually consistent with the rest of the cursor
/// overlay without competing with annotation shapes or the response text bubble.
struct WalkthroughStepChipView: View {
    /// The walkthrough phase drives chip visibility and the "checking…" affordance.
    let walkthroughPhase: WalkthroughPhase

    /// 1-based display step number shown in the badge ("Step 2").
    let currentDisplayStepNumber: Int

    /// Total steps in the walkthrough ("of 4").
    let totalStepCount: Int

    /// The short imperative instruction for the current step ("Open System Settings").
    let currentStepInstruction: String

    /// The buddy cursor's current position in this screen's SwiftUI local
    /// coordinate space. The chip is positioned relative to this so it
    /// tracks the buddy without a separate timer.
    let buddyCursorPosition: CGPoint

    /// Whether the chip should be visible at all (i.e. this screen is the
    /// one showing the buddy). Passed from the parent BlueCursorView so the
    /// chip only renders once — on the screen where the buddy lives.
    let isVisibleOnThisScreen: Bool

    /// Pulses the "checking…" ellipsis animation while verifying.
    @State private var verifyingEllipsisPhase: Int = 0

    /// Timer driving the ellipsis animation during .verifying phase.
    @State private var ellipsisTimer: Timer?

    var body: some View {
        chipBody
            .opacity(chipOpacity)
            .animation(.easeInOut(duration: 0.25), value: walkthroughPhase)
            .animation(.easeInOut(duration: 0.25), value: chipOpacity)
            // Position the chip below and to the right of the buddy cursor,
            // offset enough to clear the buddy triangle (16px) and the
            // navigation bubble above it.
            .position(
                x: buddyCursorPosition.x + chipHorizontalOffset,
                y: buddyCursorPosition.y + chipVerticalOffset
            )
            .onChange(of: walkthroughPhase) { _, newPhase in
                updateEllipsisTimer(for: newPhase)
            }
            .onAppear {
                updateEllipsisTimer(for: walkthroughPhase)
            }
            .onDisappear {
                ellipsisTimer?.invalidate()
                ellipsisTimer = nil
            }
    }

    // MARK: - Layout constants

    /// Horizontal offset from cursor centre to the chip's centre.
    /// Matches the response bubble's cursorOffsetX (22pt) so the two never collide.
    private let chipHorizontalOffset: CGFloat = 14

    /// Vertical offset places the chip below the buddy cursor so it doesn't
    /// obscure the navigation bubble above the cursor.
    private let chipVerticalOffset: CGFloat = 34

    // MARK: - Chip content

    @ViewBuilder
    private var chipBody: some View {
        HStack(spacing: 6) {
            // Step-number badge — accent-coloured pill
            Text(stepBadgeText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(DS.Colors.overlayCursorBlue)
                )
                .fixedSize()

            // Instruction text — truncated to keep the chip compact
            Text(instructionDisplayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 200, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(chipBorderColor, lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 4)
        )
        .fixedSize()
    }

    // MARK: - Derived display strings

    /// Returns a pure static string for the step badge label.
    /// Called "static" in spirit — this is the pure function the plan requires,
    /// extracted as a named computed property so it can be exercised from tests
    /// by constructing a WalkthroughStepChipView and reading the property.
    var stepBadgeText: String {
        if totalStepCount > 0 {
            return "Step \(currentDisplayStepNumber) of \(totalStepCount)"
        } else {
            return "Step \(currentDisplayStepNumber)"
        }
    }

    /// The instruction text shown next to the badge. During .verifying we
    /// append an animated "checking…" ellipsis to communicate that a fresh
    /// Claude turn is in flight.
    var instructionDisplayText: String {
        switch walkthroughPhase {
        case .verifying:
            let ellipsis = String(repeating: ".", count: verifyingEllipsisPhase + 1)
            return "checking\(ellipsis)"
        default:
            return currentStepInstruction
        }
    }

    // MARK: - Visibility

    /// The chip is visible while a walkthrough is active AND the buddy is on
    /// this screen. Cross-fade animation is driven by the opacity value so
    /// the view is always in the SwiftUI tree (never inserted/removed).
    private var chipOpacity: Double {
        guard isVisibleOnThisScreen else { return 0 }
        switch walkthroughPhase {
        case .inactive:
            return 0
        case .presentingStep, .awaitingUserAction, .verifying:
            return 1
        }
    }

    // MARK: - Visual state

    private var chipBorderColor: Color {
        switch walkthroughPhase {
        case .verifying:
            // Slightly brighter border during verification to communicate activity
            return DS.Colors.overlayCursorBlue.opacity(0.4)
        default:
            return DS.Colors.borderSubtle.opacity(0.6)
        }
    }

    // MARK: - Ellipsis animation

    private func updateEllipsisTimer(for phase: WalkthroughPhase) {
        ellipsisTimer?.invalidate()
        ellipsisTimer = nil
        verifyingEllipsisPhase = 0

        guard phase == .verifying else { return }

        // Cycle through 0, 1, 2 to produce "checking.", "checking..", "checking..."
        ellipsisTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            verifyingEllipsisPhase = (verifyingEllipsisPhase + 1) % 3
        }
    }
}
