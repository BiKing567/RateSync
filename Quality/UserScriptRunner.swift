//
//  UserScriptRunner.swift
//  RateSync
//

import Foundation
import OSLog

enum UserScriptValidator {
    /// A script must be an executable, regular file owned by the current user
    /// with no symlink in its path.
    static func isValid(at path: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            RateSyncLog.switching.error("[Script] rejected: not found or is directory \(path, privacy: .public)")
            return false
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            RateSyncLog.switching.error("[Script] rejected: not executable \(path, privacy: .public)")
            return false
        }
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            RateSyncLog.switching.error("[Script] rejected: symlink \(path, privacy: .public)")
            return false
        }
        let resolved = url.resolvingSymlinksInPath().path
        let standardized = url.standardized.path
        guard resolved == standardized else {
            RateSyncLog.switching.error("[Script] rejected: intermediate symlink \(path, privacy: .public) -> \(resolved, privacy: .public)")
            return false
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountName] as? String else {
            RateSyncLog.switching.error("[Script] rejected: cannot determine owner \(path, privacy: .public)")
            return false
        }
        let currentUser = NSUserName()
        guard owner == currentUser else {
            RateSyncLog.switching.error("[Script] rejected: owner \(owner, privacy: .public) != \(currentUser, privacy: .public)")
            return false
        }
        return true
    }
}

enum UserScriptRunner {
    static func run(sampleRate: Float64, bitDepth: Int?) {
        let livePath = UserDefaults.standard.string(forKey: "KeyShellScriptPath")
        guard let scriptPath = livePath ?? Defaults.shared.shellScriptPath else { return }
        guard UserScriptValidator.isValid(at: scriptPath) else {
            RateSyncLog.switching.error("[Script] validation failed, not executing \(scriptPath, privacy: .public)")
            if livePath != nil {
                UserDefaults.standard.removeObject(forKey: "KeyShellScriptPath")
                DispatchQueue.main.async {
                    Defaults.shared.shellScriptPath = nil
                }
            }
            return
        }

        var arguments = [String(Int(sampleRate))]
        if let bitDepth {
            arguments.append(String(bitDepth))
        }

        Task.detached {
            do {
                let task = try NSUserUnixTask(url: URL(fileURLWithPath: scriptPath))
                try await task.execute(withArguments: arguments)
            } catch {
                RateSyncLog.switching.info("TASK ERR \(error)")
            }
        }
    }
}
