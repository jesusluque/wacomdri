// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Watches a single file and reports when its contents may have changed.
///
/// Watching the file descriptor alone is not enough: most editors — and
/// `Configuration.save`, which writes atomically — replace the file rather than
/// modifying it, so the original inode is renamed away and a watcher holding it
/// goes deaf after the first save. This watches the containing directory as
/// well, and re-arms the file watch whenever the file reappears.
public final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue: DispatchQueue

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    /// Collapses the burst of events a single save produces into one callback.
    private var pendingNotification: DispatchWorkItem?
    private static let debounceInterval: DispatchTimeInterval = .milliseconds(150)

    public init(
        url: URL,
        queue: DispatchQueue = .main,
        onChange: @escaping () -> Void
    ) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
    }

    public func start() {
        watchDirectory()
        watchFile()
    }

    public func stop() {
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
        pendingNotification?.cancel()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    // MARK: - Sources

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil

        // Absent is fine: the directory watch will pick it up when created.
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.scheduleNotification()
            // The file we were holding has been replaced or removed; re-open so
            // later saves are still seen.
            if events.contains(.rename) || events.contains(.delete) {
                self.watchFile()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSource = source
    }

    private func watchDirectory() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write], queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            // An atomic save lands here as a directory write. Re-arm the file
            // watch onto the new inode, then report.
            if self.fileSource == nil, FileManager.default.fileExists(atPath: self.url.path) {
                self.watchFile()
            }
            self.scheduleNotification()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
    }

    private func scheduleNotification() {
        pendingNotification?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingNotification = work
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }
}
