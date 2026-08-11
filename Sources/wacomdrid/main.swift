// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import IntuosCore

// The driver agent. Runs in the user's login session as a LaunchAgent rather
// than a root LaunchDaemon: seizing the tablet and reading its reports both work
// unprivileged, and posting events needs a session anyway.

setvbuf(stdout, nil, _IONBF, 0)

struct Options {
    var configURL = Configuration.userURL
    var seize = true
    var verbose = false
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--config":
        index += 1
        if index < arguments.count {
            options.configURL = URL(fileURLWithPath: arguments[index])
        }
    case "--no-seize":
        // Leaves Apple's driver attached, so the cursor moves twice. Diagnostics
        // only.
        options.seize = false
    case "--verbose", "-v":
        options.verbose = true
    case "--help", "-h":
        print("""
        wacomdrid — Wacom Intuos3 (PTZ-630) driver agent

        USAGE
          wacomdrid [--config <path>] [--verbose] [--no-seize]

        The config file is watched and reloaded in place; there is no need to
        restart the agent after changing settings.

        Default config: \(Configuration.userURL.path)
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown option: \(arguments[index])\n".data(using: .utf8)!)
        exit(2)
    }
    index += 1
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("\(stamp) \(message)")
}

let service = DriverService(
    configuration: Configuration.load(from: options.configURL),
    seize: options.seize)

service.onLog = { log($0) }

if options.verbose {
    service.onTabletEvent = { event in
        switch event {
        case .proximityEnter(let tool):
            log("prox enter \(tool.type) id=0x\(String(tool.toolID, radix: 16))")
        case .proximityExit(let tool):
            log("prox exit \(tool.type)")
        case .pen(let sample, _):
            log("pen \(sample.x),\(sample.y) p=\(sample.pressure) "
                + "tilt=\(sample.tiltX),\(sample.tiltY) tip=\(sample.tipDown)")
        case .pad(let sample):
            log("pad buttons=\(String(sample.buttons, radix: 2)) "
                + "strips=\(sample.strip1Position.map { "\($0)" } ?? "-"),"
                + "\(sample.strip2Position.map { "\($0)" } ?? "-")")
        }
    }
}

log("wacomdrid starting; config \(options.configURL.path)")
service.start()

// Reload on change. Editors usually replace the file rather than writing in
// place, so watch the containing directory too — a source watching only the
// original inode goes deaf after the first save.
let configWatcher = FileWatcher(url: options.configURL) {
    service.apply(Configuration.load(from: options.configURL))
}
configWatcher.start()

// Release held buttons on the way out; being killed mid-stroke would otherwise
// leave the desktop stuck in a drag. The sources must outlive this scope or
// they are cancelled the moment they go out of it.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        log("shutting down")
        service.stop()
        exit(0)
    }
    signal(signalNumber, SIG_IGN)
    source.resume()
    signalSources.append(source)
}

CFRunLoopRun()
