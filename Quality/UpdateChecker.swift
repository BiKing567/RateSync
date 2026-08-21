//
//  UpdateChecker.swift
//  Quality
//
//  Created by BiKing567 on 15/8/26.
//

import Foundation
import AppKit

/// Checks for new releases against the GitHub Releases API and prompts the user.
class UpdateChecker {
    static let shared = UpdateChecker()
    
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/BiKing567/RateSync/releases?per_page=1")!
    
    /// Check for updates.
    /// - Parameter showUpToDate: whether to show a "you are up to date" alert when
    ///   no update is found (manual check = true, automatic startup check = false).
    func checkForUpdates(showUpToDate: Bool = false) {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RateSync/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            guard let data = data, error == nil else {
                if showUpToDate {
                    self.showAlert(title: "检查更新失败", message: "无法连接到更新服务器，请检查网络连接后重试。")
                }
                return
            }
            
            guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let latest = array.first,
                  let tagName = latest["tag_name"] as? String,
                  let htmlURL = latest["html_url"] as? String else {
                if showUpToDate {
                    self.showAlert(title: "检查更新失败", message: "无法获取更新信息，请稍后重试。")
                }
                return
            }
            
            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let hasUpdate = self.compareVersions(remoteVersion, currentVersion) > 0
            
            DispatchQueue.main.async {
                if hasUpdate {
                    let alert = NSAlert()
                    alert.messageText = "发现新版本 \(remoteVersion)"
                    alert.informativeText = "当前版本：\(currentVersion)\n是否前往下载新版本？"
                    alert.addButton(withTitle: "前往下载")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: htmlURL) {
                        NSWorkspace.shared.open(url)
                    }
                } else if showUpToDate {
                    self.showAlert(title: "已是最新版本", message: "当前已是最新版本 \(currentVersion)。")
                }
            }
        }.resume()
    }
    
    /// Version comparison. Returns 1 if v1 > v2, -1 if v1 < v2, 0 if equal.
    /// Handles dotted numeric versions of arbitrary length (e.g. "2.2" vs "2.10").
    private func compareVersions(_ v1: String, _ v2: String) -> Int {
        let a = v1.split(separator: ".").compactMap { Int($0) }
        let b = v2.split(separator: ".").compactMap { Int($0) }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
    
    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
