// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A snapshot of what the tablet is doing right now.
///
/// The preferences app cannot read the tablet itself — the agent has seized it —
/// so live feedback for the pressure curve and for "press a key to bind it" has
/// to come from the agent over XPC.
public struct TelemetrySnapshot: Codable, Sendable {
    public var isConnected = false

    /// Description of the tool in proximity, or nil when nothing is in range.
    public var toolType: String?
    public var isEraser = false

    /// Raw reading, 0...`Intuos3.maxPressure`.
    public var rawPressure = 0
    /// After the configured curve, 0...1.
    public var curvedPressure: Double = 0

    public var x = 0
    public var y = 0
    public var tiltX = 0
    public var tiltY = 0
    public var tipDown = false

    /// Bit *n* is ExpressKey *n*, so a row can light up as its key is pressed.
    public var padButtons: UInt8 = 0
    public var strip1Position: Double?
    public var strip2Position: Double?

    public init() {}
}

/// XPC surface the agent exposes to the preferences app.
///
/// Polling rather than pushing: a snapshot at UI refresh rate is all the app
/// needs, and it avoids the bidirectional-interface machinery a push design
/// would require for no visible benefit.
@objc public protocol WacomdriTelemetry {
    /// JSON-encoded `TelemetrySnapshot`, or nil if encoding fails.
    func fetchSnapshot(reply: @escaping (Data?) -> Void)
}

public enum TelemetryService {
    /// Must match the `MachServices` key in the LaunchAgent plist.
    public static let machServiceName = "tv.mediapro.wacomdri.telemetry"

    public static var interface: NSXPCInterface {
        NSXPCInterface(with: WacomdriTelemetry.self)
    }
}

/// Agent side: publishes snapshots over XPC.
public final class TelemetryPublisher: NSObject, WacomdriTelemetry, NSXPCListenerDelegate {
    /// Updated from the run loop that owns the driver, read from XPC connection
    /// queues, hence the lock.
    private var snapshot = TelemetrySnapshot()
    private let lock = NSLock()
    private var listener: NSXPCListener?

    public override init() { super.init() }

    public func start() {
        let listener = NSXPCListener(machServiceName: TelemetryService.machServiceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
    }

    public func stop() {
        listener?.invalidate()
        listener = nil
    }

    public func update(_ transform: (inout TelemetrySnapshot) -> Void) {
        lock.lock()
        transform(&snapshot)
        lock.unlock()
    }

    public func fetchSnapshot(reply: @escaping (Data?) -> Void) {
        lock.lock()
        let current = snapshot
        lock.unlock()
        reply(try? JSONEncoder().encode(current))
    }

    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = TelemetryService.interface
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

/// App side: polls the agent for snapshots.
public final class TelemetryClient {
    private var connection: NSXPCConnection?

    public init() {}

    /// Fetch the current snapshot. Returns nil when the agent is not running,
    /// which the UI shows as "agent not running" rather than as a dead tablet.
    public func fetch(completion: @escaping (TelemetrySnapshot?) -> Void) {
        let connection = self.connection ?? makeConnection()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            // The agent went away; drop the connection so the next poll rebuilds
            // it rather than reusing a dead one forever.
            self.connection = nil
            completion(nil)
        }) as? WacomdriTelemetry else {
            completion(nil)
            return
        }

        proxy.fetchSnapshot { data in
            guard let data, let snapshot = try? JSONDecoder().decode(TelemetrySnapshot.self, from: data)
            else {
                completion(nil)
                return
            }
            completion(snapshot)
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: TelemetryService.machServiceName)
        connection.remoteObjectInterface = TelemetryService.interface
        connection.invalidationHandler = { [weak self] in self?.connection = nil }
        connection.interruptionHandler = { [weak self] in self?.connection = nil }
        connection.resume()
        self.connection = connection
        return connection
    }
}
