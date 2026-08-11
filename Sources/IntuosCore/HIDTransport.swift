// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// Owns the USB side: finds the tablet, keeps it in tablet mode, and delivers
/// raw reports.
///
/// Neither reading reports nor seizing the device needs root — Input Monitoring
/// is sufficient, and `kIOHIDOptionsTypeSeizeDevice` succeeds as a normal user.
/// Verified on macOS 26.5: while seized, sweeping the pen across the tablet
/// moved the cursor not at all, confirming Apple's generic HID driver is
/// detached and there is no duplicate cursor motion.
public final class HIDTransport {
    public enum Event {
        case connected
        case disconnected
        case report([UInt8])
    }

    /// Called on the run loop the transport is scheduled on.
    public var onEvent: ((Event) -> Void)?

    /// Take exclusive ownership so macOS's own driver stops moving the cursor.
    /// Disable only for diagnostics.
    public let seize: Bool

    private let vendorID: Int
    private let productID: Int
    private let manager: IOHIDManager
    private var reportBuffer = [UInt8](repeating: 0, count: 64)
    private var device: IOHIDDevice?

    public init(
        vendorID: Int = Intuos3.vendorID,
        productID: Int = Intuos3.productID,
        seize: Bool = true
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.seize = seize
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Whether macOS will let this process read HID input at all.
    public static func hasInputMonitoringAccess() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Prompt for Input Monitoring if it has not been decided yet.
    @discardableResult
    public static func requestInputMonitoringAccess() -> Bool {
        if hasInputMonitoringAccess() { return true }
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Begin watching for the tablet on the current run loop. Returns without
    /// error when the tablet is absent — it will be picked up when plugged in.
    public func start() {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func stop() {
        if let device { close(device) }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - Device lifecycle

    private func attach(_ device: IOHIDDevice) {
        // Ignore a second match; the tablet publishes one HID device and taking
        // two references would double every report.
        guard self.device == nil else { return }

        let options: IOOptionBits = seize
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        guard IOHIDDeviceOpen(device, options) == kIOReturnSuccess else { return }

        self.device = device

        reportBuffer.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer.baseAddress!, buffer.count,
                { context, result, _, _, _, report, length in
                    guard let context, result == kIOReturnSuccess, length > 0 else { return }
                    let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
                    Unmanaged<HIDTransport>.fromOpaque(context)
                        .takeUnretainedValue()
                        .deliver(bytes)
                },
                Unmanaged.passUnretained(self).toOpaque())
        }

        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        switchToTabletMode(device)
        onEvent?(.connected)
    }

    private func detach(_ device: IOHIDDevice) {
        guard self.device === device else { return }
        self.device = nil
        onEvent?(.disconnected)
    }

    private func close(_ device: IOHIDDevice) {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
    }

    /// The tablet powers up emulating a mouse; this switches it into full tablet
    /// mode. Without it no pressure or tilt is ever reported.
    private func switchToTabletMode(_ device: IOHIDDevice) {
        var payload = Intuos3Mode.payload
        _ = IOHIDDeviceSetReport(
            device, kIOHIDReportTypeFeature, CFIndex(Intuos3Mode.reportID),
            &payload, payload.count)
    }

    /// Reports arrive with the leading report ID included and are 10 bytes,
    /// confirmed on hardware, so they already match the layout `Intuos3Decoder`
    /// expects and need no reframing.
    private func deliver(_ bytes: [UInt8]) {
        onEvent?(.report(bytes))
    }
}
