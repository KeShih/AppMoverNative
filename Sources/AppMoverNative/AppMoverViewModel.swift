import AppKit
import Foundation

@MainActor
final class AppMoverViewModel: ObservableObject {
    @Published private(set) var localApps: [ManagedApp] = []
    @Published private(set) var migratedApps: [ManagedApp] = []
    @Published private(set) var availableVolumes: [StorageVolume] = []
    @Published private(set) var isBusy = false
    @Published private(set) var activityMessage = "正在扫描应用与磁盘..."
    @Published var selectedVolumeID = ""
    @Published var destinationRoot: URL?
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private let service = MigrationService()
    private let destinationDefaultsKey = "selectedDestinationRootPath"
    private let destinationSelectionKindDefaultsKey = "selectedDestinationSelectionKind"
    private let defaults = UserDefaults.standard
    private var destinationSelectionKind: DestinationSelectionKind
    private var detailRefreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init() {
        let savedPath = defaults.string(forKey: destinationDefaultsKey) ?? ""
        let savedKindRaw = defaults.string(forKey: destinationSelectionKindDefaultsKey) ?? ""
        destinationSelectionKind = DestinationSelectionKind(
            rawValue: savedKindRaw
        ) ?? Self.inferSelectionKind(fromLegacySavedPath: savedPath)

        if let savedPath = defaults.string(forKey: destinationDefaultsKey), !savedPath.isEmpty {
            destinationRoot = URL(fileURLWithPath: savedPath, isDirectory: true)
        }

        Task {
            await refresh()
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        detailRefreshTask?.cancel()

        errorMessage = nil
        isBusy = true
        activityMessage = "正在扫描应用与磁盘..."

        do {
            let service = self.service
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try service.loadSnapshot(
                    includeBundleSizes: false,
                    includeExternalStandaloneApps: false
                )
            }.value

            localApps = snapshot.localApps
            migratedApps = snapshot.migratedApps
            availableVolumes = snapshot.availableVolumes
            alignDestinationSelection(using: snapshot.availableVolumes)
            startDeferredRefresh(for: generation)
        } catch {
            errorMessage = error.localizedDescription
        }

        isBusy = false
        activityMessage = "空闲"
    }

    deinit {
        detailRefreshTask?.cancel()
    }

    func chooseSuggestedVolume(_ volumeID: String) {
        guard let volume = availableVolumes.first(where: { $0.id == volumeID }) else {
            return
        }

        selectedVolumeID = volume.id
        setDestinationRoot(volume.destinationRoot, kind: .volumeRoot)
        infoMessage = "目标已切换到 \(volume.name)"
        errorMessage = nil
    }

    func chooseCustomDestination() {
        let panel = NSOpenPanel()
        panel.title = "选择外置硬盘中的迁移目录"
        panel.message = "建议选择外置卷根目录或其中的专用文件夹。"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        guard url.path.hasPrefix("/Volumes/") else {
            errorMessage = "请选择位于 /Volumes 下的外置盘目录。"
            return
        }

        setDestinationRoot(url, kind: .customDirectory)
        selectedVolumeID = volumeID(containing: url) ?? ""
        infoMessage = "目标目录已更新"
        errorMessage = nil
    }

    func migrate(_ app: ManagedApp) async {
        await migrate([app])
    }

    func migrate(_ apps: [ManagedApp]) async {
        let apps = uniqueApps(apps)
        guard !apps.isEmpty else {
            return
        }

        guard let destinationRoot, let destinationDirectory else {
            errorMessage = "请先选择外置硬盘目标目录。"
            return
        }

        guard isMountedDestinationRoot(destinationRoot) else {
            errorMessage = "当前目标外置盘未连接。"
            return
        }

        await performBatch(
            apps: apps,
            stopRunningApps: true,
            preflightMessage: "正在检查目标外置盘可用空间...",
            preflight: { service, apps in
                try service.validateMigrationSpace(for: apps, to: destinationDirectory)
            },
            progressMessage: { index, count, app in
                if count == 1 {
                    return "正在准备迁移 \(app.displayName)..."
                }
                return "正在迁移 \(index + 1)/\(count)：\(app.displayName)..."
            },
            operation: { service, app in
                try service.migrate(app, to: destinationDirectory)
            },
            successMessage: { apps in
                if apps.count == 1, let app = apps.first {
                    return "\(app.displayName) 已迁移到外置盘，并在 /Applications 保留了符号链接。"
                }
                return "已迁移 \(apps.count) 个应用到外置盘，并在 /Applications 保留了符号链接。"
            }
        )
    }

    func restore(_ app: ManagedApp) async {
        await restore([app])
    }

    func restore(_ apps: [ManagedApp]) async {
        await performBatch(
            apps: uniqueApps(apps),
            stopRunningApps: true,
            preflightMessage: "正在检查系统盘可用空间...",
            preflight: { service, apps in
                try service.validateRestoreSpace(for: apps)
            },
            progressMessage: { index, count, app in
                if count == 1 {
                    return "正在准备恢复 \(app.displayName)..."
                }
                return "正在恢复 \(index + 1)/\(count)：\(app.displayName)..."
            },
            operation: { service, app in
                try service.restore(app)
            },
            successMessage: { apps in
                if apps.count == 1, let app = apps.first {
                    return "\(app.displayName) 已恢复回系统盘。"
                }
                return "已恢复 \(apps.count) 个应用回系统盘。"
            }
        )
    }

    func createSystemLink(_ app: ManagedApp) async {
        await createSystemLink([app])
    }

    func createSystemLink(_ apps: [ManagedApp]) async {
        await performBatch(
            apps: uniqueApps(apps),
            stopRunningApps: false,
            progressMessage: { index, count, app in
                if count == 1 {
                    return "正在为 \(app.displayName) 创建系统链接..."
                }
                return "正在创建链接 \(index + 1)/\(count)：\(app.displayName)..."
            },
            operation: { service, app in
                try service.createSystemLink(for: app)
            },
            successMessage: { apps in
                if apps.count == 1, let app = apps.first {
                    return "\(app.displayName) 已在 /Applications 创建符号链接。"
                }
                return "已为 \(apps.count) 个应用创建系统链接。"
            }
        )
    }

    func moveToTrash(_ app: ManagedApp) async {
        await moveToTrash([app])
    }

    func moveToTrash(_ apps: [ManagedApp]) async {
        await performBatch(
            apps: uniqueApps(apps),
            stopRunningApps: true,
            progressMessage: { index, count, app in
                if count == 1 {
                    return "正在准备将 \(app.displayName) 移到废纸篓..."
                }
                return "正在移到废纸篓 \(index + 1)/\(count)：\(app.displayName)..."
            },
            operation: { service, app in
                try service.moveToTrash(app)
            },
            successMessage: { apps in
                if apps.count == 1, let app = apps.first {
                    return "\(app.displayName) 已移到废纸篓。"
                }
                return "已将 \(apps.count) 个应用移到废纸篓。"
            }
        )
    }

    func deletePermanently(_ app: ManagedApp) async {
        await deletePermanently([app])
    }

    func deletePermanently(_ apps: [ManagedApp]) async {
        await performBatch(
            apps: uniqueApps(apps),
            stopRunningApps: true,
            progressMessage: { index, count, app in
                if count == 1 {
                    return "正在准备永久删除 \(app.displayName)..."
                }
                return "正在永久删除 \(index + 1)/\(count)：\(app.displayName)..."
            },
            operation: { service, app in
                try service.deletePermanently(app)
            },
            successMessage: { apps in
                if apps.count == 1, let app = apps.first {
                    return "\(app.displayName) 已永久删除。"
                }
                return "已永久删除 \(apps.count) 个应用。"
            }
        )
    }

    func open(_ app: ManagedApp) {
        guard app.canOpen else {
            errorMessage = "应用当前不可访问，无法打开。"
            return
        }

        errorMessage = nil
        infoMessage = nil

        let configuration = NSWorkspace.OpenConfiguration()
        let targetURL = app.launchURL

        NSWorkspace.shared.openApplication(at: targetURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    var destinationSummary: String {
        guard let destinationDirectory else {
            return "尚未选择外置盘 Applications 目录"
        }
        return destinationDirectory.path
    }

    var mountedStatusText: String {
        guard let destinationRoot else {
            return "需要选择外置盘"
        }
        return isMountedDestinationRoot(destinationRoot) ? "已就绪" : "目标盘未连接"
    }

    var selectedVolume: StorageVolume? {
        guard let destinationRoot else {
            return nil
        }

        return availableVolumes.first(where: {
            destinationRoot.path.hasPrefix($0.url.path + "/") || destinationRoot.path == $0.url.path
        })
    }

    var selectedVolumeDescription: String? {
        guard let selectedVolume else {
            return nil
        }
        return "\(selectedVolume.name) · \(selectedVolume.formatSummary)"
    }

    var destinationVolumeWarning: String? {
        guard let destinationRoot else {
            return nil
        }

        guard isMountedDestinationRoot(destinationRoot) else {
            return "目标目录所在的外置卷当前没有挂载。"
        }

        guard let selectedVolume else {
            return "无法识别目标目录所在卷的文件系统，迁移前请确认它支持 macOS 应用包。"
        }

        guard !selectedVolume.isRecommendedForAppBundles else {
            return nil
        }

        return "\(selectedVolume.name) 当前是 \(selectedVolume.formatSummary)，不建议直接放置 macOS `.app`，可能影响权限、扩展属性或签名。"
    }

    var destinationDirectory: URL? {
        guard let destinationRoot else {
            return nil
        }

        switch destinationSelectionKind {
        case .volumeRoot:
            return destinationRoot.appendingPathComponent("Applications", isDirectory: true)
        case .customDirectory:
            return destinationRoot
        }
    }

    private func setDestinationRoot(_ url: URL, kind: DestinationSelectionKind) {
        destinationRoot = url
        destinationSelectionKind = kind
        defaults.set(url.path, forKey: destinationDefaultsKey)
        defaults.set(kind.rawValue, forKey: destinationSelectionKindDefaultsKey)
    }

    private func alignDestinationSelection(using volumes: [StorageVolume]) {
        if let destinationRoot {
            destinationSelectionKind = inferredSelectionKind(for: destinationRoot, volumes: volumes)
            selectedVolumeID = volumeID(containing: destinationRoot) ?? selectedVolumeID
            if selectedVolumeID.isEmpty, destinationRoot.path.hasPrefix("/Volumes/"), mountedVolumeExists(for: destinationRoot) {
                return
            }
        }

        if destinationRoot == nil, let firstVolume = volumes.first {
            selectedVolumeID = firstVolume.id
            setDestinationRoot(firstVolume.destinationRoot, kind: .volumeRoot)
        }
    }

    private func volumeID(containing url: URL) -> String? {
        availableVolumes.first(where: { url.path.hasPrefix($0.url.path + "/") || url.path == $0.url.path })?.id
    }

    private func mountedVolumeExists(for url: URL) -> Bool {
        guard let mountPoint = mountedVolumePath(for: url) else {
            return false
        }
        return FileManager.default.fileExists(atPath: mountPoint)
    }

    private func isMountedDestinationRoot(_ url: URL) -> Bool {
        guard url.path.hasPrefix("/Volumes/") else {
            return false
        }
        return mountedVolumeExists(for: url)
    }

    private func mountedVolumePath(for url: URL) -> String? {
        let components = url.pathComponents
        guard components.count >= 3 else {
            return nil
        }
        return NSString.path(withComponents: Array(components.prefix(3)))
    }

    private func stopRunningProcesses(for app: ManagedApp) async throws {
        let runningApps = runningApplications(matching: app)
        guard !runningApps.isEmpty else {
            return
        }

        activityMessage = "正在退出 \(app.displayName)..."

        for runningApp in runningApps where !runningApp.isTerminated {
            _ = runningApp.terminate()
        }

        try await waitForTermination(of: runningApps, timeout: 3.0)

        let stubbornApps = runningApps.filter { !$0.isTerminated }
        for runningApp in stubbornApps {
            _ = runningApp.forceTerminate()
        }

        try await waitForTermination(of: stubbornApps, timeout: 2.0)

        guard runningApps.allSatisfy(\.isTerminated) else {
            throw MigrationError.commandFailed("无法停止 \(app.displayName) 的运行进程，请手动退出后重试。")
        }
    }

    private func waitForTermination(of runningApps: [NSRunningApplication], timeout: TimeInterval) async throws {
        guard !runningApps.isEmpty else {
            return
        }

        let interval: UInt64 = 200_000_000
        let maxChecks = max(1, Int((timeout / 0.2).rounded(.up)))

        for _ in 0..<maxChecks {
            if runningApps.allSatisfy(\.isTerminated) {
                return
            }

            try await Task.sleep(nanoseconds: interval)
        }
    }

    private func runningApplications(matching app: ManagedApp) -> [NSRunningApplication] {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let knownPaths = matchedBundlePaths(for: app)

        return NSWorkspace.shared.runningApplications.filter { runningApp in
            guard runningApp.processIdentifier != currentProcessID else {
                return false
            }

            if let bundleIdentifier = app.bundleIdentifier, runningApp.bundleIdentifier == bundleIdentifier {
                return true
            }

            guard let bundleURL = runningApp.bundleURL?.resolvingSymlinksInPath() else {
                return false
            }

            let bundlePath = bundleURL.path
            return knownPaths.contains(where: { path in
                bundlePath == path || bundlePath.hasPrefix(path + "/") || path.hasPrefix(bundlePath + "/")
            })
        }
    }

    private func matchedBundlePaths(for app: ManagedApp) -> Set<String> {
        let candidates = [
            app.originalURL.path,
            app.currentURL.path,
            app.originalURL.resolvingSymlinksInPath().path,
            app.currentURL.resolvingSymlinksInPath().path,
        ]

        return Set(candidates.filter { !$0.isEmpty })
    }

    private func uniqueApps(_ apps: [ManagedApp]) -> [ManagedApp] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.id).inserted }
    }

    private func performBatch(
        apps: [ManagedApp],
        stopRunningApps: Bool,
        preflightMessage: String? = nil,
        preflight: (@Sendable (MigrationService, [ManagedApp]) throws -> Void)? = nil,
        progressMessage: (_ index: Int, _ count: Int, _ app: ManagedApp) -> String,
        operation: @escaping @Sendable (MigrationService, ManagedApp) throws -> Void,
        successMessage: ([ManagedApp]) -> String
    ) async {
        guard !apps.isEmpty else {
            return
        }

        errorMessage = nil
        infoMessage = nil
        isBusy = true

        do {
            let service = self.service

            if let preflight {
                activityMessage = preflightMessage ?? "正在检查操作条件..."
                try await Task.detached(priority: .userInitiated) {
                    try preflight(service, apps)
                }.value
            }

            for (index, app) in apps.enumerated() {
                activityMessage = progressMessage(index, apps.count, app)

                if stopRunningApps {
                    try await stopRunningProcesses(for: app)
                }

                try await Task.detached(priority: .userInitiated) {
                    try operation(service, app)
                }.value
            }

            infoMessage = successMessage(apps)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            isBusy = false
            activityMessage = "空闲"
        }
    }

    private func startDeferredRefresh(for generation: Int) {
        let service = self.service

        detailRefreshTask = Task {
            do {
                let snapshot = try await Task.detached(priority: .utility) {
                    try service.loadSnapshot(
                        includeBundleSizes: true,
                        includeExternalStandaloneApps: true
                    )
                }.value

                guard !Task.isCancelled, generation == refreshGeneration else {
                    return
                }

                localApps = snapshot.localApps
                migratedApps = snapshot.migratedApps
                availableVolumes = snapshot.availableVolumes
                alignDestinationSelection(using: snapshot.availableVolumes)
            } catch is CancellationError {
                return
            } catch {
                NSLog("Deferred snapshot refresh failed: %@", error.localizedDescription)
            }
        }
    }

    private func inferredSelectionKind(for url: URL, volumes: [StorageVolume]) -> DestinationSelectionKind {
        if volumes.contains(where: { $0.url.path == url.path }) {
            return .volumeRoot
        }
        return .customDirectory
    }

    private static func inferSelectionKind(fromLegacySavedPath path: String) -> DestinationSelectionKind {
        guard path.hasPrefix("/Volumes/") else {
            return .customDirectory
        }

        let components = URL(fileURLWithPath: path, isDirectory: true).pathComponents
        return components.count == 3 ? .volumeRoot : .customDirectory
    }
}

private enum DestinationSelectionKind: String {
    case volumeRoot
    case customDirectory
}
