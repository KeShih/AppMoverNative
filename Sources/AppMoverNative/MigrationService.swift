import Foundation

enum MigrationError: LocalizedError {
    case invalidDestination
    case unsupportedApp(String)
    case missingMigrationRecord(String)
    case commandFailed(String)
    case bundleScanFailed

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "请选择位于 /Volumes 下的外置硬盘目录作为迁移目标。"
        case let .unsupportedApp(name):
            return "\(name) 属于系统或 Apple 预装应用，当前原型不会迁移它。"
        case let .missingMigrationRecord(name):
            return "没有找到 \(name) 的迁移记录，无法恢复。"
        case let .commandFailed(message):
            return message
        case .bundleScanFailed:
            return "读取 /Applications 失败。"
        }
    }
}

struct MigrationService: Sendable {
    private let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

    func loadSnapshot() throws -> AppSnapshot {
        let manifestEntries = loadManifest()
        let volumeList = discoverVolumes()
        let appListing = try discoverApps(using: manifestEntries)
        let externalOnlyApps = discoverExternalStandaloneApps(
            using: volumeList,
            knownMigratedApps: appListing.migratedApps
        )

        return AppSnapshot(
            localApps: appListing.localApps,
            migratedApps: (appListing.migratedApps + externalOnlyApps)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending },
            availableVolumes: volumeList
        )
    }

    func migrate(_ app: ManagedApp, to destinationRoot: URL) throws {
        guard destinationRoot.path.hasPrefix("/Volumes/") else {
            throw MigrationError.invalidDestination
        }
        guard !app.isAppleApp else {
            throw MigrationError.unsupportedApp(app.displayName)
        }

        let destinationDirectory = destinationRoot.appendingPathComponent("Applications", isDirectory: true)
        let externalAppURL = destinationDirectory.appendingPathComponent(app.originalURL.lastPathComponent, isDirectory: true)
        let backupURL = applicationsURL.appendingPathComponent(".appmover-backup-\(UUID().uuidString)", isDirectory: true)
        let copyScript = """
        set -eu
        SRC=\(shellLiteral(app.originalURL.path))
        DST=\(shellLiteral(externalAppURL.path))
        DST_DIR=\(shellLiteral(destinationDirectory.path))

        if [ -L "$SRC" ]; then
          echo "该应用已经是符号链接。" >&2
          exit 1
        fi

        if [ ! -d "$SRC" ]; then
          echo "源应用不存在。" >&2
          exit 1
        fi

        if [ -e "$DST" ]; then
          echo "目标目录已存在同名应用。" >&2
          exit 1
        fi

        mkdir -p "$DST_DIR"
        ditto "$SRC" "$DST"
        """

        let linkScript = """
        set -eu
        SRC=\(shellLiteral(app.originalURL.path))
        DST=\(shellLiteral(externalAppURL.path))
        BACKUP=\(shellLiteral(backupURL.path))

        if [ ! -e "$DST" ]; then
          echo "外置盘中的复制结果不存在。" >&2
          exit 1
        fi

        rm -rf "$BACKUP"
        mv "$SRC" "$BACKUP"

        if ln -s "$DST" "$SRC"; then
          rm -rf "$BACKUP"
        else
          mv "$BACKUP" "$SRC"
          echo "创建符号链接失败，已回滚。" >&2
          exit 1
        fi
        """

        try runUserShell(copyScript)

        do {
            try runShellPreferringUser(linkScript)
        } catch {
            try? runUserShell("""
            set -eu
            rm -rf \(shellLiteral(externalAppURL.path))
            """)
            throw error
        }

        try upsertMigrationEntry(
            appName: app.displayName,
            originalPath: app.originalURL.path,
            externalPath: externalAppURL.path,
            destinationRootPath: destinationRoot.path
        )
    }

    func createSystemLink(for app: ManagedApp) throws {
        guard case let .migrated(externalURL, destinationRoot, isReachable) = app.residency else {
            throw MigrationError.missingMigrationRecord(app.displayName)
        }

        guard isReachable else {
            throw MigrationError.commandFailed("外置盘中的应用当前不可访问，无法创建系统链接。")
        }

        guard !app.hasSystemLink else {
            throw MigrationError.commandFailed("该应用已经存在系统链接。")
        }

        let script = """
        set -eu
        LINK=\(shellLiteral(app.originalURL.path))
        EXT=\(shellLiteral(externalURL.path))

        if [ ! -e "$EXT" ]; then
          echo "外置盘中的应用不存在，无法创建系统链接。" >&2
          exit 1
        fi

        if [ -e "$LINK" ] || [ -L "$LINK" ]; then
          echo "系统盘已存在同名应用，无法创建符号链接。" >&2
          exit 1
        fi

        ln -s "$EXT" "$LINK"
        """

        try runShellPreferringUser(script)
        try upsertMigrationEntry(
            appName: app.displayName,
            originalPath: app.originalURL.path,
            externalPath: externalURL.path,
            destinationRootPath: destinationRoot.path
        )
    }

    func restore(_ app: ManagedApp) throws {
        guard case let .migrated(externalURL, _, _) = app.residency else {
            throw MigrationError.missingMigrationRecord(app.displayName)
        }

        let backupLinkURL = applicationsURL.appendingPathComponent(".appmover-link-\(UUID().uuidString)")
        let stagedAppURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(".appmover-stage-\(UUID().uuidString).app", isDirectory: true)

        let stageScript = """
        set -eu
        EXT=\(shellLiteral(externalURL.path))
        STAGE=\(shellLiteral(stagedAppURL.path))

        if [ ! -e "$EXT" ]; then
          echo "外置盘中的应用不存在，无法恢复。" >&2
          exit 1
        fi

        rm -rf "$STAGE"
        ditto "$EXT" "$STAGE"
        """

        let installScript = """
        set -eu
        LINK=\(shellLiteral(app.originalURL.path))
        STAGE=\(shellLiteral(stagedAppURL.path))
        BACKUP=\(shellLiteral(backupLinkURL.path))

        if [ ! -e "$STAGE" ]; then
          echo "恢复暂存文件不存在。" >&2
          exit 1
        fi

        if [ -L "$LINK" ]; then
          rm -f "$BACKUP"
          mv "$LINK" "$BACKUP"

          if ditto "$STAGE" "$LINK"; then
            rm "$BACKUP"
          else
            mv "$BACKUP" "$LINK"
            echo "恢复失败，已回滚。" >&2
            exit 1
          fi
        elif [ -e "$LINK" ]; then
          echo "系统盘已存在同名应用，拒绝覆盖。" >&2
          exit 1
        else
          ditto "$STAGE" "$LINK"
        fi
        """

        try runUserShell(stageScript)

        do {
            try runShellPreferringUser(installScript)
        } catch {
            try? runUserShell("""
            set -eu
            rm -rf \(shellLiteral(stagedAppURL.path))
            """)
            throw error
        }

        try? runUserShell("""
        set -eu
        rm -rf \(shellLiteral(externalURL.path))
        rm -rf \(shellLiteral(stagedAppURL.path))
        """)

        let manifestEntries = loadManifest().filter { $0.originalPath != app.originalURL.path }
        try saveManifest(manifestEntries)
    }

    private func upsertMigrationEntry(
        appName: String,
        originalPath: String,
        externalPath: String,
        destinationRootPath: String
    ) throws {
        var manifestEntries = loadManifest().filter { $0.originalPath != originalPath }
        manifestEntries.append(
            MigrationEntry(
                appName: appName,
                originalPath: originalPath,
                externalPath: externalPath,
                destinationRootPath: destinationRootPath,
                migratedAt: Date()
            )
        )
        try saveManifest(manifestEntries)
    }

    private func discoverApps(using manifestEntries: [MigrationEntry]) throws -> (localApps: [ManagedApp], migratedApps: [ManagedApp]) {
        let fileManager = FileManager.default
        let manifestByOriginal = Dictionary(uniqueKeysWithValues: manifestEntries.map { ($0.originalPath, $0) })
        let directoryContents: [URL]

        do {
            directoryContents = try fileManager.contentsOfDirectory(
                at: applicationsURL,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw MigrationError.bundleScanFailed
        }

        var localApps: [ManagedApp] = []
        var migratedApps: [ManagedApp] = []

        for itemURL in directoryContents where itemURL.lastPathComponent.hasSuffix(".app") {
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            let isSymlink = resourceValues?.isSymbolicLink == true

            if isSymlink {
                let resolvedURL = itemURL.resolvingSymlinksInPath()
                let manifestEntry = manifestByOriginal[itemURL.path] ?? inferManifestEntry(for: itemURL, resolvedURL: resolvedURL)
                let isReachable = fileManager.fileExists(atPath: resolvedURL.path)

                migratedApps.append(
                    ManagedApp(
                        id: itemURL.path,
                        displayName: itemURL.deletingPathExtension().lastPathComponent,
                        bundleIdentifier: bundleIdentifier(for: resolvedURL),
                        originalURL: itemURL,
                        currentURL: resolvedURL,
                        residency: .migrated(
                            externalURL: resolvedURL,
                            destinationRoot: URL(fileURLWithPath: manifestEntry?.destinationRootPath ?? resolvedURL.deletingLastPathComponent().deletingLastPathComponent().path, isDirectory: true),
                            isReachable: isReachable
                        ),
                        hasSystemLink: true
                    )
                )
                continue
            }

            let bundleIdentifier = bundleIdentifier(for: itemURL)
            let app = ManagedApp(
                id: itemURL.path,
                displayName: itemURL.deletingPathExtension().lastPathComponent,
                bundleIdentifier: bundleIdentifier,
                originalURL: itemURL,
                currentURL: itemURL,
                residency: .local,
                hasSystemLink: false
            )

            if app.isAppleApp {
                continue
            }

            localApps.append(app)
        }

        return (
            localApps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending },
            migratedApps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        )
    }

    private func discoverExternalStandaloneApps(
        using volumes: [StorageVolume],
        knownMigratedApps: [ManagedApp]
    ) -> [ManagedApp] {
        let fileManager = FileManager.default
        let knownExternalPaths = Set(knownMigratedApps.map(\.currentURL.path))
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var detectedApps: [ManagedApp] = []
        var seenPaths = Set<String>()

        for volume in volumes {
            guard let enumerator = fileManager.enumerator(
                at: volume.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let baseDepth = volume.url.pathComponents.count

            for case let candidateURL as URL in enumerator {
                let depth = candidateURL.pathComponents.count - baseDepth
                let values = try? candidateURL.resourceValues(forKeys: keys)
                let isDirectory = values?.isDirectory == true
                let isSymlink = values?.isSymbolicLink == true

                if isSymlink {
                    if isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if candidateURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                    enumerator.skipDescendants()

                    if depth > 4 || knownExternalPaths.contains(candidateURL.path) || !seenPaths.insert(candidateURL.path).inserted {
                        continue
                    }

                    let expectedSystemURL = applicationsURL.appendingPathComponent(candidateURL.lastPathComponent, isDirectory: true)
                    if fileManager.fileExists(atPath: expectedSystemURL.path) {
                        continue
                    }

                    let bundleIdentifier = bundleIdentifier(for: candidateURL)
                    if bundleIdentifier?.hasPrefix("com.apple.") == true {
                        continue
                    }

                    detectedApps.append(
                        ManagedApp(
                            id: "external::\(candidateURL.path)",
                            displayName: candidateURL.deletingPathExtension().lastPathComponent,
                            bundleIdentifier: bundleIdentifier,
                            originalURL: expectedSystemURL,
                            currentURL: candidateURL,
                            residency: .migrated(
                                externalURL: candidateURL,
                                destinationRoot: inferredDestinationRoot(for: candidateURL, volume: volume),
                                isReachable: true
                            ),
                            hasSystemLink: false
                        )
                    )
                    continue
                }

                if isDirectory && depth >= 4 {
                    enumerator.skipDescendants()
                }
            }
        }

        return detectedApps
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func inferredDestinationRoot(for appURL: URL, volume: StorageVolume) -> URL {
        let parentDirectory = appURL.deletingLastPathComponent()

        if parentDirectory.lastPathComponent == "Applications" {
            return parentDirectory.deletingLastPathComponent()
        }

        if parentDirectory.path.hasPrefix(volume.url.path) {
            return parentDirectory
        }

        return volume.destinationRoot
    }

    private func inferManifestEntry(for originalURL: URL, resolvedURL: URL) -> MigrationEntry? {
        guard resolvedURL.path.hasPrefix("/Volumes/") else {
            return nil
        }

        let destinationRoot = resolvedURL.deletingLastPathComponent().deletingLastPathComponent()
        return MigrationEntry(
            appName: originalURL.deletingPathExtension().lastPathComponent,
            originalPath: originalURL.path,
            externalPath: resolvedURL.path,
            destinationRootPath: destinationRoot.path,
            migratedAt: .distantPast
        )
    }

    private func discoverVolumes() -> [StorageVolume] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeLocalizedFormatDescriptionKey,
        ]

        let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.compactMap { url in
            guard url.path.hasPrefix("/Volumes/") else {
                return nil
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsInternal == true {
                return nil
            }

            return StorageVolume(
                id: url.path,
                name: values?.volumeName ?? url.lastPathComponent,
                url: url,
                isRemovable: values?.volumeIsRemovable ?? false,
                isEjectable: values?.volumeIsEjectable ?? false,
                formatDescription: values?.volumeLocalizedFormatDescription
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func bundleIdentifier(for url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    private func loadManifest() -> [MigrationEntry] {
        let manifestURL = manifestFileURL()
        guard let data = try? Data(contentsOf: manifestURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MigrationEntry].self, from: data)) ?? []
    }

    private func saveManifest(_ entries: [MigrationEntry]) throws {
        let fileManager = FileManager.default
        let supportDirectory = manifestDirectoryURL()
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(entries)
        try data.write(to: manifestFileURL(), options: .atomic)
    }

    private func manifestDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppMoverNative", isDirectory: true)
    }

    private func manifestFileURL() -> URL {
        manifestDirectoryURL()
            .appendingPathComponent("migrations.json", isDirectory: false)
    }

    private func runPrivilegedShell(_ shellScript: String) throws {
        let appleScript = "do shell script \(appleScriptLiteral(shellScript)) with administrator privileges"
        try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript],
            launchFailurePrefix: "无法启动管理员授权流程："
        )
    }

    private func runUserShell(_ shellScript: String) throws {
        try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", shellScript],
            launchFailurePrefix: "无法启动复制流程："
        )
    }

    private func runShellPreferringUser(_ shellScript: String) throws {
        do {
            try runUserShell(shellScript)
        } catch {
            guard shouldRetryWithPrivileges(after: error) else {
                throw error
            }

            try runPrivilegedShell(shellScript)
        }
    }

    private func shouldRetryWithPrivileges(after error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("operation not permitted")
            || message.contains("permission denied")
            || message.contains("not owner")
            || message.contains("authorization required")
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        launchFailurePrefix: String
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw MigrationError.commandFailed("\(launchFailurePrefix)\(error.localizedDescription)")
        }

        let standardOutput = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let message = [errorOutput, standardOutput]
                .first(where: { !$0.isEmpty }) ?? "迁移命令执行失败。"
            throw MigrationError.commandFailed(message)
        }
    }

    private func shellLiteral(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
