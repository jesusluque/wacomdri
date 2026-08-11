// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import IntuosCore
import SwiftUI

/// Draws a scale model of the chosen display and lets the mapped zone be
/// dragged and resized inside it.
///
/// The zone is stored as fractions of the display rather than pixels, so it
/// survives a resolution change — and the editor works in the same units, which
/// is why it needs no notion of how large the real screen is.
public struct ScreenRegionEditor: View {
    @Binding var fraction: CGRect

    /// Aspect ratio of the display being carved up, so the model is not a lie.
    let displayAspect: CGFloat

    /// Where the pen currently is within the zone, in 0...1 of the zone.
    let penPosition: CGPoint?

    private let handleSize: CGFloat = 12
    private let minimumFraction: CGFloat = 0.1

    public init(fraction: Binding<CGRect>, displayAspect: CGFloat, penPosition: CGPoint?) {
        self._fraction = fraction
        self.displayAspect = displayAspect
        self.penPosition = penPosition
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = modelSize(fitting: geometry.size)

            ZStack(alignment: .topLeading) {
                // The display.
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                    .frame(width: size.width, height: size.height)

                zone(in: size)
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 190)
    }

    private func modelSize(fitting available: CGSize) -> CGSize {
        let height = min(available.height, 170)
        let width = height * displayAspect
        if width <= available.width { return CGSize(width: width, height: height) }
        return CGSize(width: available.width, height: available.width / displayAspect)
    }

    private func zone(in size: CGSize) -> some View {
        let rect = CGRect(
            x: fraction.minX * size.width,
            y: fraction.minY * size.height,
            width: fraction.width * size.width,
            height: fraction.height * size.height)

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.22))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .gesture(moveGesture(in: size))

            if let penPosition {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .offset(
                        x: penPosition.x * rect.width - 3.5,
                        y: penPosition.y * rect.height - 3.5)
                    .allowsHitTesting(false)
            }

            // Bottom-right grip, the conventional place to resize from.
            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                .frame(width: handleSize, height: handleSize)
                .offset(x: rect.width - handleSize / 2, y: rect.height - handleSize / 2)
                .gesture(resizeGesture(in: size))
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    /// Dragging the body moves the zone, keeping its size and staying inside the
    /// display.
    private func moveGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                var updated = fraction
                updated.origin.x = clamp(fraction.minX + dx, max: 1 - fraction.width)
                updated.origin.y = clamp(fraction.minY + dy, max: 1 - fraction.height)
                fraction = updated
            }
    }

    /// Dragging the grip resizes from the top-left corner, which stays put.
    private func resizeGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let width = value.location.x / size.width
                let height = value.location.y / size.height
                var updated = fraction
                // A zone smaller than a tenth of the screen is almost certainly
                // a slip, and a degenerate one would divide by zero downstream.
                updated.size.width = clamp(width, min: minimumFraction, max: 1 - fraction.minX)
                updated.size.height = clamp(height, min: minimumFraction, max: 1 - fraction.minY)
                fraction = updated
            }
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat = 0, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), Swift.max(upper, lower))
    }
}
