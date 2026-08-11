// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation

/// Wires the transport, decoder, injector and pad mapper into a running driver.
///
/// Deliberately free of process concerns — no launchd, no signals, no run loop
/// of its own — so the same object serves the agent and any test harness.
public final class DriverService {
    public private(set) var configuration: Configuration
    public private(set) var isConnected = false

    /// Diagnostics sink. Left nil the service is silent.
    public var onLog: ((String) -> Void)?

    /// Fires on every decoded event, for live telemetry in the preferences app.
    public var onTabletEvent: ((TabletEvent) -> Void)?

    private let transport: HIDTransport
    private var decoder = Intuos3Decoder()
    private let injector: EventInjector
    private let padMapper: PadMapper
    private var displayReconfigurationRegistered = false

    public init(configuration: Configuration = Configuration(), seize: Bool = true) {
        self.configuration = configuration
        self.transport = HIDTransport(seize: seize)
        self.injector = EventInjector(
            mapper: configuration.makeMapper(),
            pressureCurve: configuration.pressureCurve,
            barrelButton1: configuration.barrelButton1,
            barrelButton2: configuration.barrelButton2)
        self.padMapper = PadMapper(configuration: configuration.pad)
    }

    public func start() {
        if !HIDTransport.hasInputMonitoringAccess() {
            log("Input Monitoring not granted — requesting")
            HIDTransport.requestInputMonitoringAccess()
        }
        if !EventInjector.canPostEvents {
            // Not fatal, but nothing will reach any application until it is
            // granted, and the silence is otherwise baffling.
            log("WARNING: Accessibility not granted — posted events will be discarded")
        }

        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
        transport.start()
        observeDisplayChanges()
        log("started; waiting for tablet")
    }

    public func stop() {
        // Let go of any held buttons or keys first: stopping mid-stroke would
        // otherwise leave the desktop in a drag nothing can end.
        injector.reset()
        padMapper.reset()
        transport.stop()
    }

    /// Swap in new settings without dropping the device.
    public func apply(_ configuration: Configuration) {
        self.configuration = configuration
        injector.mapper = configuration.makeMapper()
        injector.pressureCurve = configuration.pressureCurve
        injector.barrelButton1 = configuration.barrelButton1
        injector.barrelButton2 = configuration.barrelButton2
        padMapper.configuration = configuration.pad
        log("configuration reloaded")
    }

    // MARK: - Event flow

    private func handle(_ event: HIDTransport.Event) {
        switch event {
        case .connected:
            isConnected = true
            decoder.reset()
            log("tablet connected\(transport.seize ? " (seized)" : "")")

        case .disconnected:
            isConnected = false
            // Unplugging mid-stroke must not wedge a button or modifier down.
            injector.reset()
            padMapper.reset()
            decoder.reset()
            log("tablet disconnected")

        case .report(let bytes):
            guard let decoded = decoder.decode(bytes) else { return }
            onTabletEvent?(decoded)

            if case .pad(let sample) = decoded {
                padMapper.handle(sample)
            } else {
                injector.handle(decoded)
            }
        }
    }

    // MARK: - Display layout

    /// Screen geometry is baked into the mapper, so it has to be rebuilt when
    /// displays change — otherwise plugging in a monitor leaves the pen mapped
    /// to a rectangle that no longer exists.
    private func observeDisplayChanges() {
        guard !displayReconfigurationRegistered else { return }
        displayReconfigurationRegistered = true

        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            // Only act once the change has taken effect.
            guard let context, flags.contains(.setModeFlag)
                || flags.contains(.addFlag) || flags.contains(.removeFlag)
                || flags.contains(.desktopShapeChangedFlag) else { return }
            Unmanaged<DriverService>.fromOpaque(context)
                .takeUnretainedValue()
                .displaysChanged()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func displaysChanged() {
        injector.mapper = configuration.makeMapper()
        log("display layout changed; remapped")
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
