// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import IntuosCore
import SwiftUI

/// The Mapping pane: which screen, which part of it, and which part of the
/// tablet.
public struct MappingView: View {
    @ObservedObject var model: PreferencesModel

    private enum RegionPreset: String, CaseIterable, Identifiable {
        case whole = "Whole"
        case left = "Left half"
        case right = "Right half"
        case custom = "Custom"
        var id: String { rawValue }

        var fraction: CGRect? {
            switch self {
            case .whole: return ScreenRegion.whole
            case .left: return ScreenRegion.leftHalf
            case .right: return ScreenRegion.rightHalf
            case .custom: return nil
            }
        }
    }

    private var currentPreset: RegionPreset {
        let fraction = model.configuration.screen.fraction
        return RegionPreset.allCases.first { $0.fraction == fraction } ?? .custom
    }

    /// Aspect ratio of the display being carved up, so the model in the editor
    /// is proportioned like the real thing.
    private var targetAspect: CGFloat {
        let bounds = ScreenRegion.baseBounds(for: model.configuration.screen.target)
        guard bounds.height > 0 else { return 16.0 / 10.0 }
        return bounds.width / bounds.height
    }

    /// Where the pen sits inside the mapped zone, for the live dot.
    private var penInZone: CGPoint? {
        guard model.snapshot.toolType != nil else { return nil }
        let area = model.configuration.makeMapper().effectiveArea
        guard area.width > 0, area.height > 0 else { return nil }
        return CGPoint(
            x: min(max(Double(model.snapshot.x - area.x) / Double(area.width), 0), 1),
            y: min(max(Double(model.snapshot.y - area.y) / Double(area.height), 0), 1))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Screen")
                .font(.headline)

            Picker("Map to", selection: Binding(
                get: { targetTag(model.configuration.screen.target) },
                set: { model.configuration.screen.target = targetFor(tag: $0) })
            ) {
                ForEach(Array(model.displayLabel.enumerated()), id: \.offset) { _, option in
                    Text(option.name).tag(targetTag(option.tag))
                }
            }
            .frame(width: 320)

            Picker("Area", selection: Binding(
                get: { currentPreset },
                set: { preset in
                    // "Custom" is where you already are once the zone stops
                    // matching a preset, so selecting it changes nothing.
                    if let fraction = preset.fraction {
                        model.configuration.screen.fraction = fraction
                    }
                })
            ) {
                ForEach(RegionPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)

            Text("Drag the zone to move it, or its corner to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScreenRegionEditor(
                fraction: $model.configuration.screen.fraction,
                displayAspect: targetAspect,
                penPosition: penInZone)

            Toggle("Keep proportions", isOn: $model.configuration.preserveAspectRatio)
            Text("The tablet is 4:3. Keeping proportions crops the tablet rather "
                + "than the screen, so a circle stays a circle and every pixel "
                + "stays reachable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 380, alignment: .leading)

            Divider().padding(.vertical, 4)

            Text("Preview")
                .font(.headline)
            mappingPreview

            Spacer()
        }
        .padding(20)
    }

    /// Shows the tablet rectangle, the part of it actually in use after aspect
    /// correction, and where the pen is right now.
    private var mappingPreview: some View {
        let mapper = model.configuration.makeMapper()
        let effective = mapper.effectiveArea

        return GeometryReader { geometry in
            let scale = min(
                geometry.size.width / CGFloat(Intuos3.maxX),
                120 / CGFloat(Intuos3.maxY))
            let width = CGFloat(Intuos3.maxX) * scale
            let height = CGFloat(Intuos3.maxY) * scale

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: width, height: height)

                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                    .frame(
                        width: CGFloat(effective.width) * scale,
                        height: CGFloat(effective.height) * scale)
                    .offset(
                        x: CGFloat(effective.x) * scale,
                        y: CGFloat(effective.y) * scale)

                if model.snapshot.toolType != nil {
                    Circle()
                        .fill(model.snapshot.tipDown ? Color.orange : Color.orange.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .offset(
                            x: CGFloat(model.snapshot.x) * scale - 4,
                            y: CGFloat(model.snapshot.y) * scale - 4)
                }
            }
            .frame(width: width, height: height)
        }
        .frame(height: 130)
    }

    // MARK: - Tag plumbing

    /// `ScreenTarget` is not Hashable, so pickers work on a string tag.
    private func targetTag(_ target: ScreenTarget) -> String {
        switch target {
        case .main: return "main"
        case .desktop: return "desktop"
        case .displayIndex(let index): return "index:\(index)"
        case .displayID(let id): return "id:\(id)"
        }
    }

    private func targetFor(tag: String) -> ScreenTarget {
        if tag == "desktop" { return .desktop }
        if tag.hasPrefix("index:"), let index = Int(tag.dropFirst(6)) {
            return .displayIndex(index)
        }
        if tag.hasPrefix("id:"), let id = UInt32(tag.dropFirst(3)) {
            return .displayID(id)
        }
        return .main
    }
}
