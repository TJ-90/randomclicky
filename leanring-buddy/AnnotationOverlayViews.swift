//
//  AnnotationOverlayViews.swift
//  leanring-buddy
//
//  SwiftUI shape views for BOX, CIRCLE, ARROW, and HIGHLIGHT annotations that
//  Claude can draw on the user's screen. These views are purely presentational:
//  they receive pre-converted SwiftUI-local rects and render the appropriate
//  shape with DS design-system tokens. All coordinate math lives in
//  OverlayWindow.swift (the rect-to-SwiftUI conversion helper) and
//  CompanionManager.swift (AppKit-global resolution), never here.
//
//  ANIMATION DISCIPLINE
//  ─────────────────────────────────────────────────────────────────────────────
//  Annotations animate with pure SwiftUI opacity (cross-fade) and a gentle
//  scale-in on appearance, both applied via standard SwiftUI modifiers.
//  We deliberately never:
//    - Use Timers to drive animation — that is the bezier flight's mechanism
//    - Call withAnimation(...) that wraps a transaction affecting cursorPosition
//    - Disable or enable implicit animations globally (doing so would break the
//      bezier flight's own transaction discipline in OverlayWindow.swift)
//  The annotations are always in the ZStack (never inserted/removed) and
//  cross-fade by opacity, consistent with the file's documented discipline.
//
//  DS TOKEN USAGE
//  ─────────────────────────────────────────────────────────────────────────────
//  All colors reference DS.Colors:
//    - Stroke/fill: DS.Colors.overlayCursorBlue (same blue as the buddy cursor)
//    - Highlight fill: DS.Colors.overlayAnnotationHighlightFill (20% opacity blue)
//  This keeps annotations visually cohesive with the cursor overlay aesthetic.
//

import SwiftUI

// MARK: - ArrowShape

/// A custom Shape that draws a short directional arrow pointing inward toward
/// the center of the annotation rect from outside one of its edges.
///
/// The arrow consists of a shaft (line from outside the rect to its center)
/// and two arrowhead lines forming a V at the tip (the rect center). The
/// shaft length is capped so the arrow head stays near the top-left corner
/// of the given rect frame rather than spanning the whole frame — the rect
/// frame is used only to position the arrowhead tip.
///
/// Why the arrowhead tip points at the rect center: annotations are sized to
/// fit the element, so pointing at the center gives a clear "this thing" gesture
/// regardless of the element's aspect ratio.
struct AnnotationArrowShape: Shape {

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // The arrowhead tip is the center of the bounding rect — where we're pointing.
        let arrowheadTipPoint = CGPoint(x: rect.midX, y: rect.midY)

        // The arrow shaft starts from the top-left area, offset outward so the
        // arrow visually "approaches" the target from outside. We keep the shaft
        // short (max 32pt) so it reads as a pointer gesture, not a line crossing
        // the entire element.
        let shaftLengthInPoints: CGFloat = min(min(rect.width, rect.height) * 0.5, 32)
        let arrowShaftStartPoint = CGPoint(
            x: rect.minX - shaftLengthInPoints,
            y: rect.minY - shaftLengthInPoints
        )

        // Direction vector from shaft start to tip (unit vector)
        let directionX = arrowheadTipPoint.x - arrowShaftStartPoint.x
        let directionY = arrowheadTipPoint.y - arrowShaftStartPoint.y
        let magnitude = sqrt(directionX * directionX + directionY * directionY)
        let unitDirectionX = magnitude > 0 ? directionX / magnitude : 1
        let unitDirectionY = magnitude > 0 ? directionY / magnitude : 0

        // Draw the shaft
        path.move(to: arrowShaftStartPoint)
        path.addLine(to: arrowheadTipPoint)

        // Draw two arrowhead lines — each 10pt long, splayed 35° from the shaft.
        // We compute the two wing directions by rotating the reverse-unit vector
        // ±35 degrees.
        let arrowheadLengthInPoints: CGFloat = 10.0
        let arrowheadSpreadAngleInRadians: CGFloat = 35.0 * (.pi / 180.0)

        // Reverse unit direction (from tip back toward start)
        let reverseUnitX = -unitDirectionX
        let reverseUnitY = -unitDirectionY

        // Wing 1: rotate +35°
        let wing1X = reverseUnitX * cos(arrowheadSpreadAngleInRadians) - reverseUnitY * sin(arrowheadSpreadAngleInRadians)
        let wing1Y = reverseUnitX * sin(arrowheadSpreadAngleInRadians) + reverseUnitY * cos(arrowheadSpreadAngleInRadians)

        // Wing 2: rotate -35°
        let wing2X = reverseUnitX * cos(-arrowheadSpreadAngleInRadians) - reverseUnitY * sin(-arrowheadSpreadAngleInRadians)
        let wing2Y = reverseUnitX * sin(-arrowheadSpreadAngleInRadians) + reverseUnitY * cos(-arrowheadSpreadAngleInRadians)

        path.move(to: arrowheadTipPoint)
        path.addLine(to: CGPoint(
            x: arrowheadTipPoint.x + wing1X * arrowheadLengthInPoints,
            y: arrowheadTipPoint.y + wing1Y * arrowheadLengthInPoints
        ))

        path.move(to: arrowheadTipPoint)
        path.addLine(to: CGPoint(
            x: arrowheadTipPoint.x + wing2X * arrowheadLengthInPoints,
            y: arrowheadTipPoint.y + wing2Y * arrowheadLengthInPoints
        ))

        return path
    }
}

// MARK: - Individual annotation shape views

/// Draws a rounded-rect stroke outline (BOX annotation) with an optional
/// label chip positioned above the top-left corner of the rect.
private struct BoxAnnotationView: View {
    let localRect: CGRect
    let labelText: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Rounded rectangle stroke — 2.5pt lineWidth consistent with the
            // spinner's 2.5pt stroke in BlueCursorSpinnerView (file precedent).
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(DS.Colors.overlayCursorBlue, lineWidth: 2.5)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.4), radius: 4, x: 0, y: 0)
                .frame(width: localRect.width, height: localRect.height)
                .position(x: localRect.midX, y: localRect.midY)

            if let labelText {
                AnnotationLabelChipView(labelText: labelText)
                    // Position the chip's top-left at the rect's top-left corner,
                    // offset slightly above so it doesn't overlap the stroke.
                    .position(
                        x: localRect.minX + AnnotationLabelChipView.chipHorizontalPaddingInPoints,
                        y: localRect.minY - AnnotationLabelChipView.chipHeightEstimateInPoints / 2 - 2
                    )
            }
        }
    }
}

/// Draws an elliptical stroke outline (CIRCLE annotation) inscribed in the
/// annotation rect, with an optional label chip above.
private struct CircleAnnotationView: View {
    let localRect: CGRect
    let labelText: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Ellipse()
                .stroke(DS.Colors.overlayCursorBlue, lineWidth: 2.5)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.4), radius: 4, x: 0, y: 0)
                .frame(width: localRect.width, height: localRect.height)
                .position(x: localRect.midX, y: localRect.midY)

            if let labelText {
                AnnotationLabelChipView(labelText: labelText)
                    .position(
                        x: localRect.midX,
                        y: localRect.minY - AnnotationLabelChipView.chipHeightEstimateInPoints / 2 - 2
                    )
            }
        }
    }
}

/// Draws an arrow pointing at the center of the annotation rect, with an
/// optional label chip near the arrowhead base.
private struct ArrowAnnotationView: View {
    let localRect: CGRect
    let labelText: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            AnnotationArrowShape()
                .stroke(
                    DS.Colors.overlayCursorBlue,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.4), radius: 4, x: 0, y: 0)
                .frame(width: localRect.width, height: localRect.height)
                .position(x: localRect.midX, y: localRect.midY)

            if let labelText {
                AnnotationLabelChipView(labelText: labelText)
                    .position(
                        x: localRect.minX - 16,
                        y: localRect.minY - AnnotationLabelChipView.chipHeightEstimateInPoints / 2 - 18
                    )
            }
        }
    }
}

/// Draws a translucent filled rectangle (HIGHLIGHT annotation) with a
/// hairline stroke border, with an optional label chip above.
private struct HighlightAnnotationView: View {
    let localRect: CGRect
    let labelText: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Translucent fill — uses the dedicated DS token so the opacity
            // is controlled from the design system, not a magic number here.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(DS.Colors.overlayAnnotationHighlightFill)
                .frame(width: localRect.width, height: localRect.height)
                .position(x: localRect.midX, y: localRect.midY)

            // Hairline stroke — 1pt, slightly more opaque than the fill, to
            // give the highlight a defined edge without dominating the shape.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(DS.Colors.overlayCursorBlue.opacity(0.45), lineWidth: 1)
                .frame(width: localRect.width, height: localRect.height)
                .position(x: localRect.midX, y: localRect.midY)

            if let labelText {
                AnnotationLabelChipView(labelText: labelText)
                    .position(
                        x: localRect.minX + AnnotationLabelChipView.chipHorizontalPaddingInPoints,
                        y: localRect.minY - AnnotationLabelChipView.chipHeightEstimateInPoints / 2 - 2
                    )
            }
        }
    }
}

// MARK: - Label chip

/// A small text chip displayed near an annotation to name the annotated element.
/// Uses the same visual style as the navigation speech bubble in BlueCursorView
/// (same font, same overlayCursorBlue fill, same shadow) so annotations feel
/// like a natural extension of the cursor's visual language.
private struct AnnotationLabelChipView: View {
    let labelText: String

    /// Approximate chip height used for positioning. Actual height depends on
    /// the text, but for positioning math a fixed estimate avoids a GeometryReader
    /// dependency that would add complexity without meaningfully improving accuracy.
    static let chipHeightEstimateInPoints: CGFloat = 22
    /// Horizontal padding on each side of the chip label text.
    static let chipHorizontalPaddingInPoints: CGFloat = 8

    var body: some View {
        Text(labelText)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, Self.chipHorizontalPaddingInPoints)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue)
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
            )
            .fixedSize()
    }
}

// MARK: - AnnotationLayerView (container for one screen's annotations)

/// Renders all annotations assigned to a single screen. Each annotation's rect
/// has already been converted to SwiftUI-local coordinates by the caller
/// (`BlueCursorView.convertAppKitGlobalRectToSwiftUILocalRect`).
///
/// This view is pure presentation: it receives local rects and renders shapes.
/// It contains no coordinate math, no NSScreen references, and no CompanionManager
/// observations — all of that lives in BlueCursorView, which prepares the rects
/// before passing them here.
///
/// Fade/scale-in: each annotation fades in and scales from 0.85x to 1.0x when
/// it first appears. This uses standard SwiftUI `.transition` with `.opacity`
/// combined with a `.scaleEffect` animated by `.spring`. The ZStack containing
/// all layers in BlueCursorView uses opacity cross-fading for the whole layer,
/// so individual annotation scale-in animates ON TOP of the layer opacity fade.
///
/// We use `id:` on the ForEach so SwiftUI can independently track each annotation
/// by its rect (a stable identifier within a single response's lifetime).
struct AnnotationLayerView: View {

    /// Annotation data ready for rendering on this screen.
    struct AnnotationForRendering {
        let kind: ScreenAnnotationKind
        let localRect: CGRect
        let label: String?
    }

    let annotationsForThisScreen: [AnnotationForRendering]

    var body: some View {
        // ZStack so all annotations for this screen overlay each other correctly.
        // allowsHitTesting(false) is not set here — that is enforced at the window
        // level (ignoresMouseEvents = true on the OverlayWindow NSPanel), so no
        // individual view inside the overlay can intercept clicks regardless.
        ZStack {
            ForEach(Array(annotationsForThisScreen.enumerated()), id: \.offset) { _, annotation in
                annotationView(for: annotation)
                    // Scale-in entrance: spring from 0.9x to 1.0x so the shape
                    // "materialises" rather than popping in hard. The spring
                    // parameters match the navigation bubble's spring (response 0.4,
                    // dampingFraction 0.6) for visual consistency.
                    .scaleEffect(1.0)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        // Use .animation here so the entrance/exit transitions are driven by
        // a single animation spec. We choose easeInOut so they feel deliberate
        // without being sluggish.
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: annotationsForThisScreen.count)
    }

    /// Returns the correct shape view for the given annotation kind.
    @ViewBuilder
    private func annotationView(for annotation: AnnotationForRendering) -> some View {
        switch annotation.kind {
        case .box:
            BoxAnnotationView(localRect: annotation.localRect, labelText: annotation.label)
        case .circle:
            CircleAnnotationView(localRect: annotation.localRect, labelText: annotation.label)
        case .arrow:
            ArrowAnnotationView(localRect: annotation.localRect, labelText: annotation.label)
        case .highlight:
            HighlightAnnotationView(localRect: annotation.localRect, labelText: annotation.label)
        }
    }
}
