import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppMoverViewModel
    @State private var pendingOperation: PendingOperation?
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
        ZStack {
            backgroundLayer

            VStack(alignment: .leading, spacing: 18) {
                headerCard
                statusStrip

                HStack(alignment: .top, spacing: 18) {
                    appPanel(
                        title: "系统盘中的第三方应用",
                        subtitle: "仅展示可安全迁移的 /Applications 应用。",
                        apps: viewModel.localApps,
                        emptyTitle: "没有可迁移的第三方应用",
                        emptyMessage: "Apple 预装应用会被自动跳过，避免破坏系统更新与签名。",
                        tint: Color(red: 0.12, green: 0.47, blue: 0.43)
                    )

                    appPanel(
                        title: "已迁移到外置盘",
                        subtitle: "包含已迁移应用，以及外置盘上已存在但尚未创建系统入口的应用。",
                        apps: viewModel.migratedApps,
                        emptyTitle: "还没有已迁移应用",
                        emptyMessage: "迁移成功或自动识别到外置盘中的独立应用后，这里会显示可恢复或可创建系统链接的应用。",
                        tint: Color(red: 0.75, green: 0.38, blue: 0.17)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footerNote
            }
            .padding(28)
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

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [
                Color(red: 0.96, green: 0.92, blue: 0.86),
                Color(red: 0.86, green: 0.91, blue: 0.86),
                Color(red: 0.83, green: 0.90, blue: 0.93),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color(red: 0.87, green: 0.58, blue: 0.31).opacity(0.18))
                .frame(width: 320, height: 320)
                .offset(x: 80, y: -120)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Color(red: 0.16, green: 0.46, blue: 0.44).opacity(0.18))
                .frame(width: 360, height: 360)
                .offset(x: -120, y: 120)
        }
        .ignoresSafeArea()
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AppMover Native")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.18))

                    Text("把 `/Applications` 里的第三方应用迁移到外置硬盘，并支持一键恢复。")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.24, green: 0.29, blue: 0.30))

                    Text("支持列表 / 方块两种视图；双击应用图标或点击“打开”即可直接启动应用。")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 10) {
                    Button("刷新列表") {
                        Task {
                            await viewModel.refresh()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBusy)

                    Button("自定义目录") {
                        viewModel.chooseCustomDestination()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBusy)

                    Picker("布局", selection: layoutModeBinding) {
                        Text("列表").tag(AppLayoutMode.list)
                        Text("方块").tag(AppLayoutMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("推荐外置卷")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    if viewModel.availableVolumes.isEmpty {
                        Text("未检测到可用外置盘")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                    } else {
                        Picker(
                            "推荐外置卷",
                            selection: Binding(
                                get: { viewModel.selectedVolumeID },
                                set: { viewModel.chooseSuggestedVolume($0) }
                            )
                        ) {
                            ForEach(viewModel.availableVolumes) { volume in
                                Text(volume.name).tag(volume.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                }

                Divider()
                    .frame(height: 44)

                VStack(alignment: .leading, spacing: 8) {
                    Text("当前目标目录")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(viewModel.destinationSummary)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                }

                Spacer()

                statusCapsule(viewModel.mountedStatusText)
            }

            if let selectedVolumeDescription = viewModel.selectedVolumeDescription {
                Text("目标卷信息：\(selectedVolumeDescription)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if let destinationVolumeWarning = viewModel.destinationVolumeWarning {
                messageBanner(destinationVolumeWarning, tone: .warning)
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
        }
    }

    private var statusStrip: some View {
        VStack(spacing: 10) {
            if viewModel.isBusy {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.activityMessage)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.52), in: Capsule())
            }

            if let errorMessage = viewModel.errorMessage {
                messageBanner(errorMessage, tone: .error)
            }

            if let infoMessage = viewModel.infoMessage {
                messageBanner(infoMessage, tone: .success)
            }
        }
    }

    private func appPanel(
        title: String,
        subtitle: String,
        apps: [ManagedApp],
        emptyTitle: String,
        emptyMessage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(apps.count)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(tint)
            }

            if apps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(emptyTitle)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(emptyMessage)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(18)
                .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                ScrollView {
                    if layoutMode == .list {
                        LazyVStack(spacing: 12) {
                            ForEach(apps) { app in
                                appRow(app: app, tint: tint)
                            }
                        }
                        .padding(.vertical, 2)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 14)],
                            spacing: 14
                        ) {
                            ForEach(apps) { app in
                                appTile(app: app, tint: tint)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
        }
    }

    private func appRow(
        app: ManagedApp,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AppBundleIconView(app: app, tint: tint)

            VStack(alignment: .leading, spacing: 8) {
                Text(app.displayName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                if let bundleIdentifier = app.bundleIdentifier {
                    Text(bundleIdentifier)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text(app.residencyText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 10) {
                statusCapsule(statusText(for: app), tint: statusTint(for: app, defaultTint: tint))
                appActionControls(for: app, compact: false)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.open(app)
        }
    }

    private func appTile(
        app: ManagedApp,
        tint: Color
    ) -> some View {
        VStack(spacing: 12) {
            AppBundleIconView(app: app, tint: tint)

            VStack(spacing: 4) {
                Text(app.displayName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if let bundleIdentifier = app.bundleIdentifier {
                    Text(bundleIdentifier)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(statusText(for: app))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(statusTint(for: app, defaultTint: tint))
            }

            appActionControls(for: app, compact: true)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
        .padding(16)
        .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.open(app)
        }
    }

    @ViewBuilder
    private func appActionControls(for app: ManagedApp, compact: Bool) -> some View {
        if compact {
            VStack(spacing: 8) {
                openButton(for: app)
                    .frame(maxWidth: .infinity)

                managementMenu(for: app)
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                openButton(for: app)

                managementMenu(for: app)
            }
        }
    }

    private func openButton(for app: ManagedApp) -> some View {
        Button("打开") {
            viewModel.open(app)
        }
        .buttonStyle(.bordered)
        .disabled(!app.canOpen)
    }

    private func managementMenu(for app: ManagedApp) -> some View {
        Menu {
            managementMenuItems(for: app)
        } label: {
            Label("更多操作", systemImage: "ellipsis.circle")
        }
        .disabled(isManagementDisabled(for: app))
    }

    @ViewBuilder
    private func managementMenuItems(for app: ManagedApp) -> some View {
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

    private func isManagementDisabled(for app: ManagedApp) -> Bool {
        if !app.isMigrated {
            return !app.canMigrate || viewModel.destinationRoot == nil || viewModel.isBusy
        }

        if app.hasSystemLink {
            return !app.canRestore || viewModel.isBusy
        }

        return (!app.canCreateSystemLink && !app.canRestore) || viewModel.isBusy
    }

    private func statusText(for app: ManagedApp) -> String {
        if !app.isMigrated {
            return "可迁移"
        }

        if app.hasSystemLink {
            return app.canRestore ? "已链接" : "目标未连接"
        }

        return app.canCreateSystemLink ? "可创建链接" : "目标未连接"
    }

    private func statusTint(for app: ManagedApp, defaultTint: Color) -> Color {
        if !app.isMigrated {
            return defaultTint
        }

        let isAvailable = app.hasSystemLink ? app.canRestore : app.canCreateSystemLink
        return isAvailable ? defaultTint : .gray
    }

    private func statusCapsule(_ text: String, tint: Color = Color(red: 0.16, green: 0.46, blue: 0.44)) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private func messageBanner(_ message: String, tone: BannerTone) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tone.iconName)
                .foregroundStyle(tone.tint)
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.16, green: 0.19, blue: 0.20))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(tone.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var footerNote: some View {
        Text("说明：这个原型默认只迁移第三方 `.app` 包，并依赖 `/Applications` 中的符号链接保持原路径不变。部分更新器、Mac App Store 应用和带系统扩展的应用仍然可能不适合迁移。")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

private enum AppLayoutMode: String {
    case list
    case grid
}

private enum BannerTone {
    case success
    case error
    case warning

    var tint: Color {
        switch self {
        case .success:
            return Color(red: 0.13, green: 0.47, blue: 0.33)
        case .error:
            return Color(red: 0.72, green: 0.24, blue: 0.19)
        case .warning:
            return Color(red: 0.74, green: 0.47, blue: 0.12)
        }
    }

    var iconName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "xmark.octagon.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct PendingOperation: Identifiable {
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
        case .migrate:
            return "确认迁移 \(app.displayName)"
        case .createLink:
            return "确认创建 \(app.displayName) 的系统链接"
        case .restore:
            return "确认恢复 \(app.displayName)"
        }
    }

    var confirmLabel: String {
        switch kind {
        case .migrate:
            return "开始迁移"
        case .createLink:
            return "创建链接"
        case .restore:
            return "开始恢复"
        }
    }

    var message: String {
        let baseMessage: String
        switch kind {
        case .migrate:
            baseMessage = "应用会被复制到以下目录，并在 /Applications 原位改成符号链接：\n\(targetPath)"
        case .createLink:
            baseMessage = "会在以下位置创建指向外置盘应用的符号链接，不会复制应用文件：\n\(targetPath)"
        case .restore:
            baseMessage = "应用会从以下位置恢复回系统盘，并删除外置盘副本：\n\(targetPath)"
        }

        guard let extraWarning, !extraWarning.isEmpty else {
            return baseMessage
        }

        return "\(baseMessage)\n\n注意：\(extraWarning)"
    }
}

private struct AppBundleIconView: View {
    let app: ManagedApp
    let tint: Color

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: AppIconCache.shared.icon(for: iconPath))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)

            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: badgeSymbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                }
                .offset(x: 4, y: 4)
        }
        .frame(width: 60, height: 60)
    }

    private var iconPath: String {
        let candidatePaths = [app.currentURL.path, app.originalURL.path]
        return candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? app.currentURL.path
    }

    private var badgeSymbol: String {
        if !app.isMigrated {
            return "arrow.down.circle.fill"
        }
        return app.hasSystemLink ? "link.circle.fill" : "externaldrive.fill.badge.plus"
    }
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()

    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 128, height: 128)
        cache.setObject(image, forKey: key)
        return image
    }
}
