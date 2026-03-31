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
        errorMessage = nil
        isBusy = true
        activityMessage = "正在扫描应用与磁盘..."

        do {
            let service = self.service
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try service.loadSnapshot()
            }.value

            localApps = snapshot.localApps
            migratedApps = snapshot.migratedApps
            availableVolumes = snapshot.availableVolumes
            alignDestinationSelection(using: snapshot.availableVolumes)
        } catch {
            errorMessage = error.localizedDescription
        }

        isBusy = false
        activityMessage = "空闲"
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
        guard let destinationRoot, let destinationDirectory else {
            errorMessage = "请先选择外置硬盘目标目录。"
            return
        }

        guard isMountedDestinationRoot(destinationRoot) else {
            errorMessage = "当前目标外置盘未连接。"
            return
        }

        errorMessage = nil
        infoMessage = nil
        isBusy = true
        activityMessage = "正在准备迁移 \(app.displayName)..."

        do {
            try await stopRunningProcesses(for: app)

            let service = self.service
            try await Task.detached(priority: .userInitiated) {
                try service.migrate(app, to: destinationDirectory)
            }.value

            infoMessage = "\(app.displayName) 已迁移到外置盘，并在 /Applications 保留了符号链接。"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            isBusy = false
            activityMessage = "空闲"
        }
    }

    func restore(_ app: ManagedApp) async {
        errorMessage = nil
        infoMessage = nil
        isBusy = true
        activityMessage = "正在准备恢复 \(app.displayName)..."

        do {
            try await stopRunningProcesses(for: app)

            let service = self.service
            try await Task.detached(priority: .userInitiated) {
                try service.restore(app)
            }.value

            infoMessage = "\(app.displayName) 已恢复回系统盘。"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            isBusy = false
            activityMessage = "空闲"
        }
    }

    func createSystemLink(_ app: ManagedApp) async {
        errorMessage = nil
        infoMessage = nil
        isBusy = true
        activityMessage = "正在为 \(app.displayName) 创建系统链接..."

        do {
            let service = self.service
            try await Task.detached(priority: .userInitiated) {
                try service.createSystemLink(for: app)
            }.value

            infoMessage = "\(app.displayName) 已在 /Applications 创建符号链接。"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            isBusy = false
            activityMessage = "空闲"
        }
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
