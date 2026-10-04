import Foundation
import MMC

/// One log file per run of the app, in ~/Library/Logs/Burn, keeping the last five.
///
/// Every drive's command log and the app's own events go to it line by line as they happen, and so
/// does anything written to standard error, which includes Swift's message when the app traps. So a
/// crash or a hang still leaves a log behind.
enum SessionLog {
    static let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Burn", isDirectory: true)
    static let kept = 5

    /// This run's file.
    static let file: URL = start()

    /// Events that aren't about a drive, such as checking and repairing files in Verify.
    static let events = CommandLog(mirror: file)

    /// A new log for a drive, written to this run's file.
    static func driveLog() -> CommandLog {
        CommandLog(mirror: file)
    }

    /// The most memory the app has held at once so far, for the log.
    static var peakMemory: String {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return "unknown" }
        // macOS gives the maximum resident size in bytes.
        return ByteCountFormatter.string(fromByteCount: Int64(usage.ru_maxrss), countStyle: .memory)
    }

    /// Keeps macOS from ending the app, napping it or letting the Mac sleep, until `release`.
    final class Hold {
        private let activity: any NSObjectProtocol

        init(_ reason: String) {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled,
                          .automaticTerminationDisabled],
                reason: reason)
        }

        func release() {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private static func start() -> URL {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Remove all but the newest few, leaving room for this run's.
        let old = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Burn ") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in old.dropFirst(kept - 1) {
            try? manager.removeItem(at: url)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = folder.appendingPathComponent("Burn \(formatter.string(from: Date())).log")

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        let header = "Burn \(version) (\(build), \(configuration)) on macOS "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        try? Data(header.utf8).write(to: url)

        // Standard error goes to the file too, unless it's a terminal someone is watching.
        if isatty(STDERR_FILENO) == 0 {
            let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
            if descriptor >= 0 {
                dup2(descriptor, STDERR_FILENO)
                close(descriptor)
            }
        }
        return url
    }
}
