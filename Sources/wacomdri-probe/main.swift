// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import IOKit
import IOKit.hid
import IntuosCore

// Milestone 1 de-risking tool. It answers three questions that the rest of the
// driver depends on and that cannot be settled by reading documentation:
//
//   1. Does the input-report buffer include the leading report-ID byte? The
//      Linux decoder indexes `data[0]` as the report ID, so if macOS strips it
//      every byte offset shifts by one.
//   2. Does seizing the device actually evict Apple's generic HID driver?
//   3. Does the mode-switch feature report take effect (i.e. do we get pressure
//      reports at all)?

// MARK: - Options

struct Options {
    var listAll = false
    var seize = true
    var switchMode = true
    var vendorID = Intuos3.vendorID
    var productID = Intuos3.productID
    var showHelp = false
}

func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--list", "-l": o.listAll = true
        case "--no-seize": o.seize = false
        case "--no-mode-switch": o.switchMode = false
        case "--help", "-h": o.showHelp = true
        case "--vid":
            i += 1
            if i < args.count { o.vendorID = parseInt(args[i]) ?? o.vendorID }
        case "--pid":
            i += 1
            if i < args.count { o.productID = parseInt(args[i]) ?? o.productID }
        default:
            FileHandle.standardError.write("unknown option: \(args[i])\n".data(using: .utf8)!)
            exit(2)
        }
        i += 1
    }
    return o
}

/// Accepts `0x00b1`, `00b1` and `177` so pasting values from `ioreg` or from the
/// Linux source both work.
func parseInt(_ s: String) -> Int? {
    if s.hasPrefix("0x") || s.hasPrefix("0X") {
        return Int(s.dropFirst(2), radix: 16)
    }
    return Int(s) ?? Int(s, radix: 16)
}

let usage = """
wacomdri-probe — raw HID dump for the Wacom Intuos3 (PTZ-630)

USAGE
  sudo wacomdri-probe [options]

OPTIONS
  -l, --list          List every HID device on the system and exit
      --vid <id>      Vendor ID to match (default 0x056a)
      --pid <id>      Product ID to match (default 0x00b1)
      --no-seize      Open shared instead of seizing the device
      --no-mode-switch  Skip the feature report that leaves mouse-emulation mode
  -h, --help          Show this help

NOTES
  Seizing normally requires root, hence sudo. Without --no-mode-switch the
  tablet is switched into full tablet mode; run once with --no-mode-switch to
  see the difference in what it reports.

  Capture fixtures with:  sudo wacomdri-probe | tee fixtures/raw.txt
"""

// MARK: - Formatting helpers

// This tool exists to be piped into a file (`make probe | tee fixtures/raw.txt`),
// and stdio buffers when stdout is not a terminal — which would hide every
// report until the process exits, or lose them entirely on Ctrl-C.
setvbuf(stdout, nil, _IONBF, 0)

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func hex16(_ value: Int) -> String { String(format: "0x%04x", value) }

let startTime = Date()
func stamp() -> String {
    String(format: "%8.3f", Date().timeIntervalSince(startTime))
}

func note(_ s: String) { print("# \(s)") }

func cfInt(_ device: IOHIDDevice, _ key: String) -> Int? {
    IOHIDDeviceGetProperty(device, key as CFString) as? Int
}

func cfString(_ device: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(device, key as CFString) as? String
}

// MARK: - Device listing

func listAllDevices() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, nil)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
        note("no HID devices visible (is Input Monitoring granted?)")
        return
    }

    print("VID     PID     UsagePg Usage  Product")
    print("------  ------  ------- -----  -------------------------------------")
    for device in devices.sorted(by: {
        (cfInt($0, kIOHIDVendorIDKey) ?? 0, cfInt($0, kIOHIDProductIDKey) ?? 0)
            < (cfInt($1, kIOHIDVendorIDKey) ?? 0, cfInt($1, kIOHIDProductIDKey) ?? 0)
    }) {
        let vid = cfInt(device, kIOHIDVendorIDKey) ?? 0
        let pid = cfInt(device, kIOHIDProductIDKey) ?? 0
        let page = cfInt(device, kIOHIDPrimaryUsagePageKey) ?? 0
        let usage = cfInt(device, kIOHIDPrimaryUsageKey) ?? 0
        let product = cfString(device, kIOHIDProductKey) ?? "?"
        let mark = (vid == Intuos3.vendorID) ? " <- Wacom" : ""
        print("\(hex16(vid))  \(hex16(pid))  \(hex16(page))  \(String(format: "0x%02x", usage))"
            + "   \(product)\(mark)")
    }
}

// MARK: - Probe

/// Holds the state the C callbacks need. A single instance is kept alive for the
/// lifetime of the process and handed to IOKit as an opaque context pointer.
final class Probe {
    private let options: Options
    private let manager: IOHIDManager
    private var reportBuffer = [UInt8](repeating: 0, count: 256)
    private var openedDevices: [IOHIDDevice] = []

    /// Set once, the first time a report arrives, so the verdict is only printed
    /// on the report that actually establishes the layout.
    private var reportedLayoutVerdict = false
    private var reportCount = 0

    init(options: Options) {
        self.options = options
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        requestAccess()

        let matching: [String: Any] = [
            kIOHIDVendorIDKey: options.vendorID,
            kIOHIDProductIDKey: options.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            note("IOHIDManagerOpen failed: \(ioReturnDescription(openResult))")
        }

        note("waiting for \(hex16(options.vendorID)):\(hex16(options.productID)) — plug in the tablet if it is not already connected")
        note("press Ctrl-C to stop")
    }

    /// macOS 10.15+ gates raw HID input behind the Input Monitoring TCC service.
    /// Without it the matching callback fires but no reports ever arrive, which
    /// looks exactly like a dead tablet.
    private func requestAccess() {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted:
            note("Input Monitoring: granted")
        case kIOHIDAccessTypeDenied:
            note("Input Monitoring: DENIED — grant it in System Settings > Privacy & Security > Input Monitoring")
        default:
            note("Input Monitoring: not determined, requesting…")
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            note("Input Monitoring: \(granted ? "granted" : "not granted")")
        }
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        let product = cfString(device, kIOHIDProductKey) ?? "?"
        note("matched: \(product) (\(hex16(cfInt(device, kIOHIDVendorIDKey) ?? 0)):\(hex16(cfInt(device, kIOHIDProductIDKey) ?? 0)))")

        if let max = cfInt(device, kIOHIDMaxInputReportSizeKey) {
            note("  MaxInputReportSize:   \(max)")
        }
        if let max = cfInt(device, kIOHIDMaxFeatureReportSizeKey) {
            note("  MaxFeatureReportSize: \(max)")
        }

        let options: IOOptionBits = self.options.seize
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        let result = IOHIDDeviceOpen(device, options)
        if result != kIOReturnSuccess {
            note("  IOHIDDeviceOpen(\(self.options.seize ? "seize" : "shared")) FAILED: \(ioReturnDescription(result))")
            note("  (seizing usually requires root — try sudo)")
            return
        }
        note("  opened \(self.options.seize ? "with seize" : "shared")")
        openedDevices.append(device)

        reportBuffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceRegisterInputReportCallback(
                device, buf.baseAddress!, buf.count,
                { context, result, _, type, reportID, report, length in
                    guard let context, result == kIOReturnSuccess else { return }
                    let bytes = Array(UnsafeBufferPointer(start: report, count: max(0, Int(length))))
                    Unmanaged<Probe>.fromOpaque(context)
                        .takeUnretainedValue()
                        .inputReport(type: type, reportID: reportID, bytes: bytes)
                },
                Unmanaged.passUnretained(self).toOpaque())
        }

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        if self.options.switchMode {
            switchToTabletMode(device)
        } else {
            note("  mode switch skipped (--no-mode-switch)")
        }

        note("")
        note("time      id  len  bytes")
    }

    /// Mirrors `wacom_set_device_mode()`: write the mode feature report, then
    /// read it back to confirm the tablet accepted it.
    private func switchToTabletMode(_ device: IOHIDDevice) {
        var payload = Intuos3Mode.payload
        let result = IOHIDDeviceSetReport(
            device, kIOHIDReportTypeFeature, CFIndex(Intuos3Mode.reportID),
            &payload, payload.count)

        if result == kIOReturnSuccess {
            note("  mode switch: sent feature report \(hex(Intuos3Mode.payload)) -> OK")
        } else {
            note("  mode switch: FAILED: \(ioReturnDescription(result))")
        }

        var readback = [UInt8](repeating: 0, count: 8)
        var length = readback.count
        let getResult = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, CFIndex(Intuos3Mode.reportID),
            &readback, &length)
        if getResult == kIOReturnSuccess {
            note("  mode readback: \(hex(Array(readback.prefix(length))))")
        } else {
            note("  mode readback: \(ioReturnDescription(getResult)) (not fatal — some units do not answer)")
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        note("device removed")
        openedDevices.removeAll { $0 === device }
    }

    private func inputReport(type: IOHIDReportType, reportID: UInt32, bytes: [UInt8]) {
        reportCount += 1

        if !reportedLayoutVerdict {
            reportedLayoutVerdict = true
            printLayoutVerdict(reportID: reportID, bytes: bytes)
        }

        let label: String
        switch UInt8(truncatingIfNeeded: reportID) {
        case Intuos3Report.pen: label = "pen "
        case Intuos3Report.pad: label = "pad "
        default: label = "??  "
        }

        print("\(stamp())  \(label)\(String(format: "%2d", reportID))  \(String(format: "%3d", bytes.count))  \(hex(bytes))")
    }

    /// The whole port hinges on this: print it loudly, once.
    private func printLayoutVerdict(reportID: UInt32, bytes: [UInt8]) {
        note("")
        note("=== BUFFER LAYOUT VERDICT ===")
        note("first report: id=\(reportID) length=\(bytes.count) bytes=[\(hex(bytes))]")

        let idInBuffer = bytes.first.map { $0 == UInt8(truncatingIfNeeded: reportID) } ?? false
        if idInBuffer && bytes.count == Intuos3Report.penLengthWithID {
            note("buffer STARTS WITH the report ID and is \(bytes.count) bytes.")
            note("=> Linux byte offsets apply directly: data[0] is the report ID.")
        } else if bytes.count == Intuos3Report.penLengthWithID - 1 {
            note("buffer EXCLUDES the report ID (\(bytes.count) bytes).")
            note("=> Every Linux offset must shift by -1: Linux data[n] == bytes[n-1].")
        } else {
            note("UNEXPECTED: length \(bytes.count), first byte \(String(format: "0x%02x", bytes.first ?? 0)).")
            note("=> Inspect several reports by hand before writing the decoder.")
        }
        note("=============================")
        note("")
    }

    func shutdown() {
        note("")
        note("received \(reportCount) reports; closing")
        for device in openedDevices {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

func ioReturnDescription(_ code: IOReturn) -> String {
    let name: String
    switch code {
    case kIOReturnSuccess: name = "success"
    case kIOReturnNotPrivileged: name = "not privileged (needs root)"
    case kIOReturnExclusiveAccess: name = "exclusive access (another process holds it)"
    case kIOReturnNotPermitted: name = "not permitted (TCC?)"
    case kIOReturnUnsupported: name = "unsupported"
    case kIOReturnNoDevice: name = "no device"
    default: name = "unknown"
    }
    return "\(name) (0x\(String(format: "%08x", UInt32(bitPattern: code))))"
}

// MARK: - Entry point

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

if options.showHelp {
    print(usage)
    exit(0)
}

if options.listAll {
    listAllDevices()
    exit(0)
}

note("wacomdri-probe — target \(Intuos3.name)")
note("running as uid \(getuid())")
if getuid() != 0 && options.seize {
    note("WARNING: not running as root; seizing the device will probably fail")
}

let probe = Probe(options: options)

// Close the device on Ctrl-C so Apple's generic HID driver takes it back and the
// cursor keeps working.
let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signalSource.setEventHandler {
    probe.shutdown()
    exit(0)
}
signal(SIGINT, SIG_IGN)
signalSource.resume()

probe.start()
CFRunLoopRun()
