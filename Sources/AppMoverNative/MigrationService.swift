import Foundation

enum MigrationError: LocalizedError {
    case invalidDestination
    case unsupportedApp(String)
    case missingMigrationRecord(String)
    case insufficientDiskSpace(destinationPath: String, required: Int64, available: Int64)
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
        case let .insufficientDiskSpace(destinationPath, required, available):
            let requiredText = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "目标磁盘空间不足。\n目标位置：\(destinationPath)\n预计至少需要 \(requiredText)，当前可用 \(availableText)。"
        case let .commandFailed(message):
            return message
        case .bundleScanFailed:
            return "读取 /Applications 失败。"
        }
    }
}

struct MigrationService: Sendable {
    private let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    private let dockIntegrationService = DockIntegrationService()

    func loadSnapshot(
        includeBundleSizes: Bool = true,
        includeExternalStandaloneApps: Bool = true
    ) throws -> AppSnapshot {
        let manifestEntries = loadManifest()
        let volumeList = discoverVolumes()
        let appListing = try discoverApps(
            using: manifestEntries,
            includeBundleSizes: includeBundleSizes
        )
        let externalOnlyApps: [ManagedApp]

        if includeExternalStandaloneApps {
            externalOnlyApps = discoverExternalStandaloneApps(
                using: volumeList,
                knownMigratedApps: appListing.migratedApps,
                includeBundleSizes: includeBundleSizes
            )
        } else {
            externalOnlyApps = []
        }

        return AppSnapshot(
            localApps: appListing.localApps,
            migratedApps: (appListing.migratedApps + externalOnlyApps)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending },
            availableVolumes: volumeList
        )
    }

    func migrate(_ app: ManagedApp, to destinationDirectory: URL) throws {
        guard destinationDirectory.path.hasPrefix("/Volumes/") else {
            throw MigrationError.invalidDestination
        }
        guard !app.isAppleApp else {
            throw MigrationError.unsupportedApp(app.displayName)
        }

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
            destinationRootPath: destinationDirectory.path
        )
        repairDockPinnedItem(for: app, targetURL: externalAppURL, matchingURLs: [app.originalURL])
    }

    func validateMigrationSpace(for apps: [ManagedApp], to destinationDirectory: URL) throws {
        try validateAvailableSpace(
            for: apps,
            destinationURL: destinationDirectory,
            fallbackExistingURL: destinationDirectory.deletingLastPathComponent()
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
        repairDockPinnedItem(for: app, targetURL: externalURL, matchingURLs: [app.originalURL])
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
        repairDockPinnedItem(for: app, targetURL: app.originalURL, matchingURLs: [externalURL])
    }

    func validateRestoreSpace(for apps: [ManagedApp]) throws {
        try validateAvailableSpace(
            for: apps,
            destinationURL: applicationsURL,
            fallbackExistingURL: applicationsURL
        )
    }

    func moveToTrash(_ app: ManagedApp) throws {
        guard !app.isAppleApp else {
            throw MigrationError.unsupportedApp(app.displayName)
        }

        switch app.residency {
        case .local:
            try runShellPreferringUser(trashScript(for: [app.currentURL.path]))
        case let .migrated(externalURL, _, isReachable):
            guard isReachable else {
                throw MigrationError.commandFailed("外置盘中的应用当前不可访问，无法移到废纸篓。")
            }

            let script = """
            set -eu
            LINK=\(shellLiteral(app.originalURL.path))
            EXT=\(shellLiteral(externalURL.path))

            if [ -L "$LINK" ]; then
              :
            elif [ -e "$LINK" ] && [ "$LINK" != "$EXT" ]; then
              echo "系统盘存在同名实体应用，已停止操作以避免误删。" >&2
              exit 1
            fi

            \(trashScriptBody(for: app.hasSystemLink ? [app.originalURL.path, externalURL.path] : [externalURL.path]))
            """

            try runShellPreferringUser(script)
        }

        try removeManifestEntries(for: app)
    }

    func deletePermanently(_ app: ManagedApp) throws {
        guard !app.isAppleApp else {
            throw MigrationError.unsupportedApp(app.displayName)
        }

        switch app.residency {
        case .local:
            let script = """
            set -eu
            APP=\(shellLiteral(app.currentURL.path))

            if [ ! -e "$APP" ] && [ ! -L "$APP" ]; then
              echo "应用不存在，无法永久删除。" >&2
              exit 1
            fi

            rm -rf "$APP"
            """

            try runShellPreferringUser(script)
        case let .migrated(externalURL, _, isReachable):
            guard isReachable else {
                throw MigrationError.commandFailed("外置盘中的应用当前不可访问，无法永久删除。")
            }

            let script = """
            set -eu
            LINK=\(shellLiteral(app.originalURL.path))
            EXT=\(shellLiteral(externalURL.path))

            if [ -L "$LINK" ]; then
              rm "$LINK"
            elif [ -e "$LINK" ] && [ "$LINK" != "$EXT" ]; then
              echo "系统盘存在同名实体应用，已停止永久删除以避免误删。" >&2
              exit 1
            fi

            if [ ! -e "$EXT" ] && [ ! -L "$EXT" ]; then
              echo "外置盘中的应用不存在，无法永久删除。" >&2
              exit 1
            fi

            rm -rf "$EXT"
            """

            try runShellPreferringUser(script)
        }

        try removeManifestEntries(for: app)
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

    private func discoverApps(
        using manifestEntries: [MigrationEntry],
        includeBundleSizes: Bool
    ) throws -> (localApps: [ManagedApp], migratedApps: [ManagedApp]) {
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
                        bundleSize: includeBundleSizes ? appSize(for: resolvedURL) : nil,
                        originalURL: itemURL,
                        currentURL: resolvedURL,
                            residency: .migrated(
                                externalURL: resolvedURL,
                                destinationRoot: URL(fileURLWithPath: manifestEntry?.destinationRootPath ?? resolvedURL.deletingLastPathComponent().path, isDirectory: true),
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
                bundleSize: includeBundleSizes ? appSize(for: itemURL) : nil,
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
        knownMigratedApps: [ManagedApp],
        includeBundleSizes: Bool
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
                            bundleSize: includeBundleSizes ? appSize(for: candidateURL) : nil,
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
            return parentDirectory
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

        let destinationRoot = resolvedURL.deletingLastPathComponent()
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

    private func appSize(for url: URL) -> Int64? {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ]

        if let values = try? url.resourceValues(forKeys: resourceKeys),
           let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
            return Int64(size)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }

        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else {
                continue
            }

            if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                totalSize += Int64(size)
            }
        }

        return totalSize > 0 ? totalSize : nil
    }

    private func validateAvailableSpace(
        for apps: [ManagedApp],
        destinationURL: URL,
        fallbackExistingURL: URL
    ) throws {
        guard !apps.isEmpty else {
            return
        }

        let required = totalRequiredSpace(for: apps)
        guard required > 0 else {
            return
        }

        guard let available = availableSpace(at: destinationURL, fallbackExistingURL: fallbackExistingURL) else {
            return
        }

        if required > available {
            throw MigrationError.insufficientDiskSpace(
                destinationPath: destinationURL.path,
                required: required,
                available: available
            )
        }
    }

    private func totalRequiredSpace(for apps: [ManagedApp]) -> Int64 {
        let total = apps.reduce(into: Int64(0)) { partialResult, app in
            let sourceURL = app.currentURL
            if let knownSize = app.bundleSize {
                partialResult += knownSize
            } else if let measuredSize = appSize(for: sourceURL) {
                partialResult += measuredSize
            }
        }

        guard total > 0 else {
            return 0
        }

        let safetyBuffer = max(total / 20, 256 * 1024 * 1024)
        return total + safetyBuffer
    }

    private func availableSpace(at destinationURL: URL, fallbackExistingURL: URL) -> Int64? {
        let fileManager = FileManager.default
        let probeURL = existingURL(forFileSystemProbe: destinationURL) ?? existingURL(forFileSystemProbe: fallbackExistingURL)

        guard let probePath = probeURL?.path,
              let attributes = try? fileManager.attributesOfFileSystem(forPath: probePath) else {
            return nil
        }

        if let freeSize = attributes[.systemFreeSize] as? NSNumber {
            return freeSize.int64Value
        }

        return nil
    }

    private func existingURL(forFileSystemProbe url: URL) -> URL? {
        var candidate = url
        let fileManager = FileManager.default

        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return fileManager.fileExists(atPath: "/") ? URL(fileURLWithPath: "/", isDirectory: true) : nil
    }

    private func removeManifestEntries(for app: ManagedApp) throws {
        let manifestEntries = loadManifest().filter {
            $0.originalPath != app.originalURL.path && $0.externalPath != app.currentURL.path
        }
        try saveManifest(manifestEntries)
    }

    private func trashScript(for paths: [String]) -> String {
        """
        set -eu
        \(trashScriptBody(for: paths))
        """
    }

    private func trashScriptBody(for paths: [String]) -> String {
        let uid = String(getuid())
        let homeTrashPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .path
        let items = paths.map(shellLiteral).joined(separator: " ")

        return """
        USER_TRASH=\(shellLiteral(homeTrashPath))
        USER_ID=\(shellLiteral(uid))

        unique_destination() {
          TRASH_DIR="$1"
          NAME="$2"
          EXT=""
          BASE="$NAME"

          case "$NAME" in
            *.app)
              EXT=".app"
              BASE="${NAME%.app}"
              ;;
          esac

          DEST="$TRASH_DIR/$NAME"
          if [ -e "$DEST" ] || [ -L "$DEST" ]; then
            SUFFIX="$(date +%Y%m%d-%H%M%S)"
            DEST="$TRASH_DIR/$BASE-$SUFFIX$EXT"
          fi

          printf '%s' "$DEST"
        }

        trash_item() {
          SRC="$1"

          if [ ! -e "$SRC" ] && [ ! -L "$SRC" ]; then
            echo "应用不存在，无法移到废纸篓。" >&2
            exit 1
          fi

          case "$SRC" in
            /Volumes/*)
              REST="${SRC#/Volumes/}"
              VOLUME_NAME="${REST%%/*}"
              TRASH_DIR="/Volumes/$VOLUME_NAME/.Trashes/$USER_ID"
              ;;
            *)
              TRASH_DIR="$USER_TRASH"
              ;;
          esac

          mkdir -p "$TRASH_DIR"
          DEST="$(unique_destination "$TRASH_DIR" "$(basename "$SRC")")"
          mv "$SRC" "$DEST"
        }

        for ITEM in \(items); do
          trash_item "$ITEM"
        done
        """
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

    private func repairDockPinnedItem(for app: ManagedApp, targetURL: URL, matchingURLs: [URL]) {
        do {
            try dockIntegrationService.repairPinnedItem(
                for: app,
                targetURL: targetURL,
                matchingURLs: matchingURLs
            )
        } catch {
            NSLog("Dock repair failed for %@: %@", app.displayName, error.localizedDescription)
        }
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
