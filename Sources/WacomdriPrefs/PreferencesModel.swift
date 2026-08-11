// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import CoreGraphics
import Foundation
import IntuosCore

/// Backs the whole preferences window.
///
/// Settings are persisted to the config file, which the agent watches and
/// reloads in place — so there is no "apply" button and no need to restart
/// anything. Live tablet state comes back the other way over XPC, because the
/// agent holds the device exclusively and the app cannot read it directly.
@MainActor
final class PreferencesModel: ObservableObject {
    @Published var configuration: Configuration {
        didSet { scheduleSave() }
    }

    @Published private(set) var snapshot = TelemetrySnapshot()
    @Published private(set) var isAgentRunning = false
    @Published private(set) var displays: [(id: CGDirectDisplayID, bounds: CGRect)] = []

    private let client = TelemetryClient()
    private var pollTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?

    init() {
        configuration = Configuration.load(from: Configuration.userURL)
        displays = DisplayList.activeDisplays()
    }

    func start() {
        // 30 Hz: fast enough that the pressure bar tracks the nib, slow enough
        // that polling costs nothing noticeable.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        // Make sure a pending edit is not lost when the window closes.
        flushSave()
        client.invalidate()
    }

    private func poll() {
        client.fetch { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                if let snapshot {
                    self.snapshot = snapshot
                    self.isAgentRunning = true
                } else {
                    self.isAgentRunning = false
                    self.snapshot = TelemetrySnapshot()
                }
            }
        }
        displays = DisplayList.activeDisplays()
    }

    // MARK: - Persistence

    /// Dragging a curve handle produces a stream of edits; writing on each one
    /// would have the agent reloading dozens of times a second.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flushSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    private func save() {
        do {
            try configuration.save(to: Configuration.userURL)
        } catch {
            NSLog("wacomdri: could not save preferences: \(error.localizedDescription)")
        }
    }

    // MARK: - Convenience

    /// Which ExpressKey is held right now, for highlighting a row.
    func isKeyPressed(_ index: Int) -> Bool {
        snapshot.padButtons & (1 << UInt8(index)) != 0
    }

    var displayLabel: [(tag: ScreenTarget, name: String)] {
        var options: [(ScreenTarget, String)] = [
            (.main, "Main display"),
            (.desktop, "All displays"),
        ]
        for (index, display) in displays.enumerated() {
            let size = "\(Int(display.bounds.width))×\(Int(display.bounds.height))"
            options.append((.displayIndex(index), "Display \(index + 1) — \(size)"))
        }
        return options
    }
}
