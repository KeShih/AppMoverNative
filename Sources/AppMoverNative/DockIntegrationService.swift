import Foundation

enum DockIntegrationError: LocalizedError {
    case invalidDockPreferences
    case restartFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDockPreferences:
            return "Dock 偏好设置格式无效。"
        case let .restartFailed(message):
            return "刷新 Dock 失败：\(message)"
        }
    }
}

struct DockIntegrationService: Sendable {
    private let dockDomain = "com.apple.dock"

    @discardableResult
    func repairPinnedItem(
        for app: ManagedApp,
        targetURL: URL,
        matchingURLs: [URL] = []
    ) throws -> Bool {
        let targetURL = normalizedDirectoryURL(targetURL)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return false
        }

        var domain = UserDefaults.standard.persistentDomain(forName: dockDomain) ?? [:]
        guard var persistentApps = domain["persistent-apps"] as? [[String: Any]] else {
            throw DockIntegrationError.invalidDockPreferences
        }

        let bundleIdentifier = resolvedBundleIdentifier(for: targetURL) ?? app.bundleIdentifier
        let candidatePaths = Set(
            ([app.originalURL, app.currentURL, targetURL] + matchingURLs)
                .map(normalizedDirectoryURL(_:))
                .map(\.path)
        )

        var didUpdate = false

        for index in persistentApps.indices {
            guard persistentApps[index]["tile-type"] as? String == "file-tile" else {
                continue
            }
            guard let tileData = persistentApps[index]["tile-data"] as? [String: Any] else {
                continue
            }

            let existingBundleIdentifier = tileData["bundle-identifier"] as? String
            let existingLabel = tileData["file-label"] as? String
            let fileData = tileData["file-data"] as? [String: Any] ?? [:]
            let fileDataURL = dockURL(from: fileData)
            let pathMatches = fileDataURL.map { candidatePaths.contains(normalizedDirectoryURL($0).path) } ?? false
            let bundleMatches = bundleIdentifier != nil && existingBundleIdentifier == bundleIdentifier
            let labelMatches = existingLabel?.localizedStandardCompare(app.displayName) == .orderedSame

            guard pathMatches || (bundleMatches && labelMatches) else {
                continue
            }

            persistentApps[index] = makeFreshDockEntry(
                targetURL: targetURL,
                bundleIdentifier: bundleIdentifier,
                existingGUID: persistentApps[index]["GUID"] as? Int
            )
            didUpdate = true
        }

        guard didUpdate else {
            return false
        }

        domain["persistent-apps"] = persistentApps
        if let modCount = domain["mod-count"] as? Int {
            domain["mod-count"] = modCount + 1
        }

        UserDefaults.standard.setPersistentDomain(domain, forName: dockDomain)
        CFPreferencesAppSynchronize(dockDomain as CFString)
        try restartDock()

        return true
    }

    private func resolvedBundleIdentifier(for url: URL) -> String? {
        Bundle(url: url.resolvingSymlinksInPath())?.bundleIdentifier
    }

    private func dockURL(from fileData: [String: Any]) -> URL? {
        guard let rawValue = fileData["_CFURLString"] as? String else {
            return nil
        }

        guard let url = URL(string: rawValue), url.isFileURL else {
            return nil
        }

        return url
    }

    private func normalizedDirectoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true)
    }

    private func makeFreshDockEntry(
        targetURL: URL,
        bundleIdentifier: String?,
        existingGUID: Int?
    ) -> [String: Any] {
        var tileData: [String: Any] = [
            "file-data": [
                "_CFURLString": targetURL.absoluteString,
                "_CFURLStringType": 15,
            ],
        ]

        if let bundleIdentifier {
            tileData["bundle-identifier"] = bundleIdentifier
        }

        return [
            "GUID": existingGUID ?? Int.random(in: 1...Int(Int32.max)),
            "tile-data": tileData,
            "tile-type": "file-tile",
        ]
    }

    private func restartDock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]

        let stderr = Pipe()
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DockIntegrationError.restartFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let errorOutput = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "killall Dock 失败。"
            throw DockIntegrationError.restartFailed(errorOutput)
        }
    }
}
