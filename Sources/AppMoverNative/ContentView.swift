import AppKit
import SwiftUI
struct ContentView: View {
    @ObservedObject var viewModel: AppMoverViewModel
    @State private var pendingOperation: PendingOperation?
    @State private var draggedApp: ManagedApp?
    @State private var activeDropTarget: DropPanel?
    @AppStorage("appLayoutMode") private var layoutModeRaw = AppLayoutMode.list.rawValue

    private var layoutMode: AppLayoutMode {
        AppLayoutMode(rawValue: layoutModeRaw) ?? .list
    }

    private var layoutModeBinding: Binding<AppLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { layoutModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if viewModel.isBusy || viewModel.errorMessage != nil || viewModel.infoMessage != nil {
                statusBar
                Divider()
            }

            HStack(spacing: 0) {
                appPanel(
                    title: "系统盘应用",
                    subtitle: "可迁移的第三方应用",
                    apps: viewModel.localApps,
                    emptyTitle: "没有可迁移的第三方应用",
                    emptyMessage: "Apple 预装应用会被自动跳过，避免破坏系统更新与签名。",
                    tint: .accentColor,
                    isLocalPanel: true
                )
                Divider()
                appPanel(
                    title: "外置盘应用",
                    subtitle: "已迁移或独立存在",
                    apps: viewModel.migratedApps,
                    emptyTitle: "还没有已迁移应用",
                    emptyMessage: "迁移成功或检测到外置盘独立应用后会显示在这里。",
                    tint: .orange,
                    isLocalPanel: false
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footerBar
        }
        .alert(item: $pendingOperation) { operation in
            Alert(
                title: Text(operation.title),
                message: Text(operation.message),
                primaryButton: .default(Text(operation.confirmLabel)) {
                    Task {
                        switch operation.kind {
                        case .migrate:
                            await viewModel.migrate(operation.app)
                        case .createLink:
                            await viewModel.createSystemLink(operation.app)
                        case .restore:
                            await viewModel.restore(operation.app)
                        }
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            leadingToolbarGroup
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            Picker("", selection: layoutModeBinding) {
                Image(systemName: "list.bullet").tag(AppLayoutMode.list)
                Image(systemName: "square.grid.2x2").tag(AppLayoutMode.grid)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 58)

            Button("选择目录") {
                viewModel.chooseCustomDestination()
            }
            .controlSize(.small)
            .disabled(viewModel.isBusy)

            Button("刷新") {
                Task { await viewModel.refresh() }
            }
            .controlSize(.small)
            .disabled(viewModel.isBusy)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    @ViewBuilder
    private var leadingToolbarGroup: some View {
        HStack(spacing: 8) {
            if viewModel.availableVolumes.isEmpty {
                Text("无可用外置盘")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { viewModel.selectedVolumeID },
                    set: { viewModel.chooseSuggestedVolume($0) }
                )) {
                    ForEach(viewModel.availableVolumes) { volume in
                        Text(volume.name).tag(volume.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            }

            Text(viewModel.destinationSummary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            mountBadge
                .fixedSize(horizontal: true, vertical: false)

            if let warning = viewModel.destinationVolumeWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(warning)
            }
        }
    }

    @ViewBuilder
    private var mountBadge: some View {
        let ready = viewModel.mountedStatusText == "已就绪"
        HStack(spacing: 3) {
            Circle()
                .fill(ready ? Color(nsColor: .systemGreen) : Color(nsColor: .quaternaryLabelColor))
                .frame(width: 6, height: 6)
            Text(viewModel.mountedStatusText)
                .font(.system(size: 11))
                .foregroundStyle(ready ? Color.primary : Color.secondary)
        }
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 8) {
            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                Text(viewModel.activityMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let msg = viewModel.errorMessage {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let msg = viewModel.infoMessage {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - App Panel

    private func appPanel(
        title: String,
        subtitle: String,
        apps: [ManagedApp],
        emptyTitle: String,
        emptyMessage: String,
        tint: Color,
        isLocalPanel: Bool
    ) -> some View {
        let panel = isLocalPanel ? DropPanel.local : DropPanel.external

        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.4)
                Text("· \(subtitle)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(apps.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if apps.isEmpty {
                VStack(spacing: 6) {
                    Text(emptyTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                ScrollView {
                    if layoutMode == .list {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(apps.enumerated()), id: \.element.id) { (idx, app) in
                                appRow(app: app, tint: tint, showStatus: !isLocalPanel, isLocalPanel: isLocalPanel)
                                if idx < apps.count - 1 {
                                    Divider().padding(.leading, 54)
                                }
                            }
                        }
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 18, alignment: .top)],
                            spacing: 18
                        ) {
                            ForEach(apps) { app in
                                appTile(app: app, tint: tint, showStatus: !isLocalPanel, isLocalPanel: isLocalPanel)
                            }
                        }
                        .padding(18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            Rectangle()
                .fill(Color.black.opacity(activeDropTarget == panel ? 0.06 : 0))
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.12), value: activeDropTarget)
        .onDrop(of: [.text], isTargeted: dropTargetBinding(for: panel), perform: { _ in
            handleDrop(on: panel)
        })
    }

    // MARK: - App Row (List)

    private func appRow(app: ManagedApp, tint: Color, showStatus: Bool, isLocalPanel: Bool) -> some View {
        HStack(spacing: 10) {
            AppBundleIconView(app: app, size: 32, tint: tint, showBadge: showStatus)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let bid = app.bundleIdentifier {
                    Text(bid)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if showStatus {
                statusTag(for: app, tint: tint)
            }

            rowActions(for: app)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            contextMenuItems(for: app)
        }
        .onDrag {
            dragProvider(for: app)
        }
        .onTapGesture(count: 2) { viewModel.open(app) }
    }

    // MARK: - App Tile (Grid, Finder Style)

    private func appTile(app: ManagedApp, tint: Color, showStatus: Bool, isLocalPanel: Bool) -> some View {
        VStack(spacing: 6) {
            AppBundleIconView(app: app, size: 64, tint: tint, showBadge: showStatus)

            VStack(spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if showStatus {
                    Text(statusText(for: app))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .contentShape(Rectangle())
        .contextMenu {
            contextMenuItems(for: app)
        }
        .onDrag {
            dragProvider(for: app)
        }
        .onTapGesture(count: 2) { viewModel.open(app) }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for app: ManagedApp) -> some View {
        Button("打开") { viewModel.open(app) }
            .disabled(!app.canOpen)

        Divider()

        if !app.isMigrated {
            Button("迁移到外置盘") {
                pendingOperation = PendingOperation(
                    app: app,
                    kind: .migrate,
                    targetPath: viewModel.destinationSummary,
                    extraWarning: viewModel.destinationVolumeWarning
                )
            }
            .disabled(!app.canMigrate || viewModel.destinationRoot == nil || viewModel.isBusy)
        } else if app.hasSystemLink {
            Button("恢复到系统盘") {
                pendingOperation = PendingOperation(
                    app: app,
                    kind: .restore,
                    targetPath: app.currentURL.path,
                    extraWarning: app.canRestore ? nil : "外置盘未连接，恢复会失败。"
                )
            }
            .disabled(!app.canRestore || viewModel.isBusy)
        } else {
            Button("创建系统链接") {
                pendingOperation = PendingOperation(
                    app: app,
                    kind: .createLink,
                    targetPath: app.originalURL.path,
                    extraWarning: app.canCreateSystemLink ? nil : "外置盘未连接，无法创建系统链接。"
                )
            }
            .disabled(!app.canCreateSystemLink || viewModel.isBusy)

            Button("恢复到系统盘") {
                pendingOperation = PendingOperation(
                    app: app,
                    kind: .restore,
                    targetPath: app.currentURL.path,
                    extraWarning: app.canRestore ? nil : "外置盘未连接，恢复会失败。"
                )
            }
            .disabled(!app.canRestore || viewModel.isBusy)
        }
    }

    // MARK: - Status Tag

    private func statusTag(for app: ManagedApp, tint: Color) -> some View {
        let text = statusText(for: app)
        let color = statusTint(for: app, defaultTint: tint)
        return Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Action Controls (List only)

    @ViewBuilder
    private func rowActions(for app: ManagedApp) -> some View {
        HStack(spacing: 6) {
            Button("打开") { viewModel.open(app) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!app.canOpen)

            if !app.isMigrated {
                Button("迁移") {
                    pendingOperation = PendingOperation(
                        app: app,
                        kind: .migrate,
                        targetPath: viewModel.destinationSummary,
                        extraWarning: viewModel.destinationVolumeWarning
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!app.canMigrate || viewModel.destinationRoot == nil || viewModel.isBusy)
            } else if app.hasSystemLink {
                Button("恢复") {
                    pendingOperation = PendingOperation(
                        app: app,
                        kind: .restore,
                        targetPath: app.currentURL.path,
                        extraWarning: app.canRestore ? nil : "外置盘未连接，恢复会失败。"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!app.canRestore || viewModel.isBusy)
            } else {
                Button("创建链接") {
                    pendingOperation = PendingOperation(
                        app: app,
                        kind: .createLink,
                        targetPath: app.originalURL.path,
                        extraWarning: app.canCreateSystemLink ? nil : "外置盘未连接，无法创建系统链接。"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!app.canCreateSystemLink || viewModel.isBusy)

                Button("恢复") {
                    pendingOperation = PendingOperation(
                        app: app,
                        kind: .restore,
                        targetPath: app.currentURL.path,
                        extraWarning: app.canRestore ? nil : "外置盘未连接，恢复会失败。"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!app.canRestore || viewModel.isBusy)
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Text("仅迁移第三方 .app 包，依赖 /Applications 符号链接保持原路径不变。")
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
            Spacer()
            if let desc = viewModel.selectedVolumeDescription {
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .quaternaryLabelColor))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    // MARK: - Helpers

    private func statusText(for app: ManagedApp) -> String {
        if !app.isMigrated { return "可迁移" }
        if app.hasSystemLink { return app.canRestore ? "已链接" : "目标未连接" }
        return app.canCreateSystemLink ? "可创建链接" : "目标未连接"
    }

    private func statusTint(for app: ManagedApp, defaultTint: Color) -> Color {
        if !app.isMigrated { return defaultTint }
        let isAvailable = app.hasSystemLink ? app.canRestore : app.canCreateSystemLink
        return isAvailable ? defaultTint : .secondary
    }

    private func dragProvider(for app: ManagedApp) -> NSItemProvider {
        draggedApp = app
        activeDropTarget = nil
        return NSItemProvider(object: app.id as NSString)
    }

    private func pendingOperation(for app: ManagedApp, onto panel: DropPanel) -> PendingOperation? {
        guard !viewModel.isBusy else {
            return nil
        }

        switch panel {
        case .local:
            guard app.isMigrated, app.canRestore else {
                return nil
            }
            return PendingOperation(
                app: app,
                kind: .restore,
                targetPath: app.currentURL.path,
                extraWarning: nil
            )
        case .external:
            guard !app.isMigrated, app.canMigrate, viewModel.destinationRoot != nil else {
                return nil
            }
            return PendingOperation(
                app: app,
                kind: .migrate,
                targetPath: viewModel.destinationSummary,
                extraWarning: viewModel.destinationVolumeWarning
            )
        }
    }

    private func dropTargetBinding(for panel: DropPanel) -> Binding<Bool> {
        Binding(
            get: { activeDropTarget == panel },
            set: { isTargeted in
                guard isTargeted else {
                    if activeDropTarget == panel {
                        activeDropTarget = nil
                    }
                    return
                }

                guard let draggedApp, pendingOperation(for: draggedApp, onto: panel) != nil else {
                    if activeDropTarget == panel {
                        activeDropTarget = nil
                    }
                    return
                }

                activeDropTarget = panel
            }
        )
    }

    private func handleDrop(on panel: DropPanel) -> Bool {
        defer {
            activeDropTarget = nil
            draggedApp = nil
        }

        guard let draggedApp, let operation = pendingOperation(for: draggedApp, onto: panel) else {
            return false
        }

        pendingOperation = operation
        return true
    }
}

// MARK: - Supporting Types

private enum AppLayoutMode: String {
    case list
    case grid
}

private enum DropPanel {
    case local
    case external
}

struct PendingOperation: Identifiable {
    enum Kind {
        case migrate
        case createLink
        case restore
    }

    let id = UUID()
    let app: ManagedApp
    let kind: Kind
    let targetPath: String
    let extraWarning: String?

    var title: String {
        switch kind {
        case .migrate: return "确认迁移 \(app.displayName)"
        case .createLink: return "确认创建 \(app.displayName) 的系统链接"
        case .restore: return "确认恢复 \(app.displayName)"
        }
    }

    var confirmLabel: String {
        switch kind {
        case .migrate: return "开始迁移"
        case .createLink: return "创建链接"
        case .restore: return "开始恢复"
        }
    }

    var message: String {
        let base: String
        switch kind {
        case .migrate:
            base = "开始前会先尝试退出该应用的运行中进程；如果无法退出，会中止迁移。\n\n应用会被复制到以下目录，并在 /Applications 原位改成符号链接：\n\(targetPath)"
        case .createLink:
            base = "会在以下位置创建指向外置盘应用的符号链接，不会复制应用文件：\n\(targetPath)"
        case .restore:
            base = "应用会从以下位置恢复回系统盘，并删除外置盘副本：\n\(targetPath)"
        }
        guard let extraWarning, !extraWarning.isEmpty else { return base }
        return "\(base)\n\n注意：\(extraWarning)"
    }
}

private struct AppBundleIconView: View {
    let app: ManagedApp
    let size: CGFloat
    let tint: Color
    let showBadge: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: AppIconCache.shared.icon(for: iconPath))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)

            if showBadge {
                let badgeSize = size * 0.32
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: badgeSize, height: badgeSize)
                    .overlay(
                        Circle()
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
                    .overlay {
                        Image(systemName: badgeSymbol)
                            .font(.system(size: badgeSize * 0.5, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size + 4, height: size + 4)
    }

    private var iconPath: String {
        let candidates = [app.currentURL.path, app.originalURL.path]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? app.currentURL.path
    }

    private var badgeSymbol: String {
        if !app.isMigrated { return "arrow.down" }
        return app.hasSystemLink ? "link" : "externaldrive.fill"
    }
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 128, height: 128)
        cache.setObject(image, forKey: key)
        return image
    }
}
