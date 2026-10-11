import Foundation
@preconcurrency import OSLog

enum RateSyncDiagnosticLogging {
#if RATESYNC_LOCAL_DIAGNOSTIC_LOG
    static let localFileEnabled = true
#else
    static let localFileEnabled = false
#endif
}

/// Mirrors switching diagnostics to macOS Unified Log and a short-lived local log.
enum RateSyncLog {
    static let switching = RateSyncLogger(
        subsystem: "com.biking.RateSync",
        category: "switching"
    )
}

struct RateSyncLogger {
    private let systemLogger: Logger

    init(subsystem: String, category: String) {
        systemLogger = Logger(subsystem: subsystem, category: category)
    }

    func info(_ message: RateSyncLogMessage) {
        emit(message, level: "INFO")
        systemLogger.info("\(message.rendered, privacy: .public)")
    }

    func error(_ message: RateSyncLogMessage) {
        emit(message, level: "ERROR")
        systemLogger.error("\(message.rendered, privacy: .public)")
    }

    private func emit(_ message: RateSyncLogMessage, level: String) {
        guard RateSyncDiagnosticLogging.localFileEnabled else { return }
        LocalDiagnosticLog.shared.append(level: level, message: message.rendered)
    }
}

enum RateSyncLogPrivacy {
    case `public`
    case `private`
}

struct RateSyncLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    struct StringInterpolation: StringInterpolationProtocol {
        typealias StringLiteralType = String

        private(set) var rendered = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            rendered.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        mutating func appendLiteral(_ literal: String) {
            rendered.append(contentsOf: literal)
        }

        mutating func appendInterpolation<Value: BinaryInteger>(_ value: Value) {
            rendered.append(contentsOf: String(describing: value))
        }

        mutating func appendInterpolation<Value: BinaryFloatingPoint>(_ value: Value) {
            rendered.append(contentsOf: String(describing: value))
        }

        mutating func appendInterpolation<Value>(_ value: Value) {
            _ = value
            rendered.append("<private>")
        }

        mutating func appendInterpolation<Value>(
            _ value: Value,
            privacy: RateSyncLogPrivacy
        ) {
            switch privacy {
            case .public:
                rendered.append(contentsOf: String(describing: value))
            case .private:
                rendered.append("<private>")
            }
        }
    }

    let rendered: String

    init(stringLiteral value: String) {
        rendered = value
    }

    init(stringInterpolation: StringInterpolation) {
        rendered = stringInterpolation.rendered
    }
}

final class LocalDiagnosticLog {
    static let retentionInterval: TimeInterval = 12 * 60 * 60
    private static let cleanupInterval: TimeInterval = 60
    private static let fallbackLogger = Logger(
        subsystem: "com.biking.RateSync",
        category: "diagnostic-file"
    )

    static let shared = LocalDiagnosticLog(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RateSync", isDirectory: true)
            .appendingPathComponent("RateSync-debug.log"),
        now: { Date() },
        startsMaintenanceTimer: true
    )

    let fileURL: URL

    private let fileManager: FileManager
    private let now: () -> Date
    private let queue: DispatchQueue
    private let timestampFormatter: ISO8601DateFormatter
    private var lastCleanupDate = Date.distantPast
    private var maintenanceTimer: DispatchSourceTimer?

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { Date() },
        startsMaintenanceTimer: Bool = false
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.now = now
        queue = DispatchQueue(label: "com.biking.RateSync.diagnostic-log")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter = formatter

        queue.sync {
            pruneExpiredEntries(at: now())
        }

        if startsMaintenanceTimer {
            startMaintenanceTimer()
        }
    }

    func append(level: String, message: String, at timestamp: Date? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let date = timestamp ?? now()
            cleanupIfDue(at: date)
            appendLine(level: level, message: message, at: date)
        }
    }

    func cleanupExpiredEntries(at date: Date) {
        queue.sync {
            pruneExpiredEntries(at: date)
        }
    }

    func flush() {
        queue.sync {}
    }

    private func startMaintenanceTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            pruneExpiredEntries(at: now())
        }
        timer.resume()
        maintenanceTimer = timer
    }

    private func cleanupIfDue(at date: Date) {
        guard date.timeIntervalSince(lastCleanupDate) >= Self.cleanupInterval else { return }
        pruneExpiredEntries(at: date)
    }

    private func pruneExpiredEntries(at date: Date) {
        lastCleanupDate = date
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.split(whereSeparator: \.isNewline)
            let retainedLines = lines.filter { line in
                guard let timestamp = timestamp(in: line) else { return false }
                return date.timeIntervalSince(timestamp) <= Self.retentionInterval
            }

            guard retainedLines.count != lines.count else { return }
            guard !retainedLines.isEmpty else {
                try fileManager.removeItem(at: fileURL)
                return
            }

            let retainedContent = retainedLines.joined(separator: "\n") + "\n"
            try Data(retainedContent.utf8).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Self.fallbackLogger.error("Unable to prune local diagnostic log: \(String(describing: error), privacy: .private)")
        }
    }

    private func timestamp(in line: Substring) -> Date? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        return timestampFormatter.date(from: String(line[..<separator]))
    }

    private func appendLine(level: String, message: String, at date: Date) {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

            let safeMessage = message
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
            let line = "\(timestampFormatter.string(from: date)) [\(level)] \(safeMessage)\n"
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            Self.fallbackLogger.error("Unable to append local diagnostic log: \(String(describing: error), privacy: .private)")
        }
    }
}
