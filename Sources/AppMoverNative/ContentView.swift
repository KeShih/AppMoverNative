import AppKit
import SwiftUI
struct ContentView: View {
    @ObservedObject var viewModel: AppMoverViewModel
    @State private var pendingOperation: PendingOperation?
    @State private var draggedApps: [ManagedApp] = []
    @State private var activeDropTarget: DropPanel?
    @State private var selectedAppIDs = Set<String>()
    @State private var selectedPanel: DropPanel?
    @State private var selectionAnchorID: String?
    @State private var sortedLocalApps: [ManagedApp] = []
    @State private var sortedMigratedApps: [ManagedApp] = []
    @AppStorage("appLayoutMode") private var layoutModeRaw = AppLayoutMode.list.rawValue
    @AppStorage("appSortMode") private var sortModeRaw = AppSortMode.nameAscending.rawValue

    private var layoutMode: AppLayoutMode {
        AppLayoutMode(rawValue: layoutModeRaw) ?? .list
    }

    private var sortMode: AppSortMode {
        AppSortMode(rawValue: sortModeRaw) ?? .nameAscending
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
                    apps: sortedLocalApps,
                    emptyTitle: "没有可迁移的第三方应用",
                    emptyMessage: "Apple 预装应用会被自动跳过，避免破坏系统更新与签名。",
                    tint: .accentColor,
                    isLocalPanel: true
                )
                Divider()
                appPanel(
                    title: "外置盘应用",
                    subtitle: "已迁移或独立存在",
                    apps: sortedMigratedApps,
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
                primaryButton: primaryButton(for: operation),
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onChange(of: viewModel.localApps) {
            syncSelection()
            resortDisplayedApps()
        }
        .onChange(of: viewModel.migratedApps) {
            syncSelection()
            resortDisplayedApps()
        }
        .onChange(of: sortModeRaw) {
            resortDisplayedApps()
        }
        .task {
            resortDisplayedApps()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            leadingToolbarGroup
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            layoutModeControl

            Menu {
                ForEach(AppSortMode.allCases) { mode in
                    Button {
                        sortModeRaw = mode.rawValue
                    } label: {
                        if mode == sortMode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                toolbarMenuLabel(title: "排序", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.9)
            )
            .help("排序")

            Button {
                viewModel.chooseCustomDestination()
            } label: {
                toolbarControlLabel(title: "选择目录", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .opacity(viewModel.isBusy ? 0.5 : 1)

            Button {
                Task { await viewModel.refresh() }
            } label: {
                toolbarControlLabel(title: "刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .opacity(viewModel.isBusy ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            clearSelection()
        }
    }

    @ViewBuilder
    private var leadingToolbarGroup: some View {
        HStack(spacing: 8) {
            if viewModel.availableVolumes.isEmpty {
                Text("无可用外置盘")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(viewModel.availableVolumes) { volume in
                        Button {
                            viewModel.chooseSuggestedVolume(volume.id)
                        } label: {
                            if viewModel.selectedVolumeID == volume.id {
                                Label(volume.name, systemImage: "checkmark")
                            } else {
                                Text(volume.name)
                            }
                        }
                    }
                } label: {
                    toolbarMenuLabel(
                        title: viewModel.selectedVolume?.name ?? "选择磁盘",
                        systemImage: "externaldrive"
                    )
                }
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.9)
                )
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

    private var layoutModeControl: some View {
        HStack(spacing: 4) {
            layoutModeButton(for: .list, systemImage: "list.bullet", helpText: "列表")
            layoutModeButton(for: .grid, systemImage: "square.grid.2x2", helpText: "网格")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.8)
        )
    }

    private func layoutModeButton(
        for mode: AppLayoutMode,
        systemImage: String,
        helpText: String
    ) -> some View {
        let isSelected = layoutMode == mode

        return Button {
            layoutModeRaw = mode.rawValue
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color(nsColor: .windowBackgroundColor) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isSelected ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                            lineWidth: 0.8
                        )
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func toolbarControlLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.8)
        )
    }

    private func toolbarMenuLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.primary)
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
        .contentShape(Rectangle())
        .onTapGesture {
            clearSelection()
        }
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
        let displayedApps = apps
        let panelSelectedApps = selectedApps(in: panel, displayedApps: displayedApps)

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
            .contentShape(Rectangle())
            .onTapGesture {
                clearSelection()
            }

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
                GeometryReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(Color.clear)
                                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    clearSelection()
                                }

                            if layoutMode == .list {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(displayedApps.enumerated()), id: \.element.id) { (idx, app) in
                                        appRow(
                                            app: app,
                                            panel: panel,
                                            selectedAppsInPanel: panelSelectedApps,
                                            tint: tint,
                                            showStatus: !isLocalPanel
                                        )
                                        if idx < displayedApps.count - 1 {
                                            Divider().padding(.leading, 54)
                                        }
                                    }
                                }
                            } else {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 18, alignment: .top)],
                                    spacing: 18
                                ) {
                                    ForEach(displayedApps) { app in
                                        appTile(
                                            app: app,
                                            panel: panel,
                                            selectedAppsInPanel: panelSelectedApps,
                                            tint: tint,
                                            showStatus: !isLocalPanel
                                        )
                                    }
                                }
                                .padding(18)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func appRow(
        app: ManagedApp,
        panel: DropPanel,
        selectedAppsInPanel: [ManagedApp],
        tint: Color,
        showStatus: Bool
    ) -> some View {
        let isSelected = isSelected(app, in: panel)

        return HStack(spacing: 10) {
            AppBundleIconView(app: app, size: 40, showBadge: showStatus)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(primaryTextColor(isSelected: isSelected))
                if let metadata = app.metadataText {
                    Text(metadata)
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryTextColor(isSelected: isSelected))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if showStatus {
                statusTag(for: app, tint: tint, isSelected: isSelected)
            }

            rowActions(for: app)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selectionBackground(isSelected))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 1)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            contextMenuItems(for: contextApps(for: app, in: panel, selectedAppsInPanel: selectedAppsInPanel))
        }
        .onDrag {
            dragProvider(for: app, in: panel)
        }
        .onTapGesture { handlePrimaryClick(on: app, in: panel) }
    }

    // MARK: - App Tile (Grid, Finder Style)

    private func appTile(
        app: ManagedApp,
        panel: DropPanel,
        selectedAppsInPanel: [ManagedApp],
        tint: Color,
        showStatus: Bool
    ) -> some View {
        let isSelected = isSelected(app, in: panel)

        return VStack(spacing: 6) {
            AppBundleIconView(app: app, size: 64, showBadge: showStatus)

            VStack(spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(primaryTextColor(isSelected: isSelected))

                if let metadata = app.metadataText {
                    Text(metadata)
                        .font(.system(size: 9))
                        .foregroundStyle(secondaryTextColor(isSelected: isSelected))
                        .lineLimit(1)
                }

                if showStatus {
                    Text(statusText(for: app))
                        .font(.system(size: 9))
                        .foregroundStyle(secondaryTextColor(isSelected: isSelected))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(selectionLabelBackground(isSelected))
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(selectionBackground(isSelected))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(4)
        .contentShape(Rectangle())
        .contextMenu {
            contextMenuItems(for: contextApps(for: app, in: panel, selectedAppsInPanel: selectedAppsInPanel))
        }
        .onDrag {
            dragProvider(for: app, in: panel)
        }
        .onTapGesture { handlePrimaryClick(on: app, in: panel) }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for apps: [ManagedApp]) -> some View {
        let app = apps.first!
        let hasPrimaryActions = canMigrate(apps) || canCreateSystemLink(apps) || canRestore(apps)

        if apps.count == 1 {
            Button("打开") { viewModel.open(app) }
                .disabled(!app.canOpen)

            Divider()
        }

        if canMigrate(apps) {
            Button(actionLabel("迁移到外置盘", count: apps.count)) {
                pendingOperation = makePendingOperation(
                    apps: apps,
                    kind: .migrate,
                    targetPath: viewModel.destinationSummary,
                    extraWarning: viewModel.destinationVolumeWarning
                )
            }
            .disabled(viewModel.destinationRoot == nil || viewModel.isBusy)
        }

        if canCreateSystemLink(apps) {
            Button(actionLabel("创建系统链接", count: apps.count)) {
                pendingOperation = makePendingOperation(
                    apps: apps,
                    kind: .createLink,
                    targetPath: apps.map(\.originalURL.path).joined(separator: "\n"),
                    extraWarning: nil
                )
            }
            .disabled(viewModel.isBusy)
        }

        if canRestore(apps) {
            Button(actionLabel("恢复到系统盘", count: apps.count)) {
                pendingOperation = makePendingOperation(
                    apps: apps,
                    kind: .restore,
                    targetPath: apps.map(\.currentURL.path).joined(separator: "\n"),
                    extraWarning: nil
                )
            }
            .disabled(viewModel.isBusy)
        }

        if hasPrimaryActions && canRemove(apps) {
            Divider()
        }

        Button(actionLabel("移到废纸篓", count: apps.count)) {
            pendingOperation = makePendingOperation(
                apps: apps,
                kind: .moveToTrash,
                targetPath: removalTargetPath(for: apps),
                extraWarning: nil
            )
        }
        .disabled(!canRemove(apps) || viewModel.isBusy)

        Button(actionLabel("永久删除", count: apps.count)) {
            pendingOperation = makePendingOperation(
                apps: apps,
                kind: .deletePermanently,
                targetPath: removalTargetPath(for: apps),
                extraWarning: nil
            )
        }
        .disabled(!canRemove(apps) || viewModel.isBusy)
    }

    // MARK: - Status Tag

    private func statusTag(for app: ManagedApp, tint: Color, isSelected: Bool) -> some View {
        let text = statusText(for: app)
        let color = statusTint(for: app, defaultTint: tint)
        return Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (isSelected ? Color(nsColor: .black).opacity(0.035) : color.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 4)
            )
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
                        apps: [app],
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
                        apps: [app],
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
                        apps: [app],
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
                        apps: [app],
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
        .contentShape(Rectangle())
        .onTapGesture {
            clearSelection()
        }
    }

    // MARK: - Helpers

    private func statusText(for app: ManagedApp) -> String {
        if !app.isMigrated { return "可迁移" }
        if app.hasSystemLink { return app.canRestore ? "已链接" : "目标未连接" }
        return app.canCreateSystemLink ? "可创建链接" : "目标未连接"
    }

    private func syncSelection() {
        let validIDs: Set<String>

        switch selectedPanel {
        case .local:
            validIDs = Set(sortedLocalApps.map(\.id))
        case .external:
            validIDs = Set(sortedMigratedApps.map(\.id))
        case nil:
            validIDs = []
        }

        selectedAppIDs = selectedAppIDs.intersection(validIDs)
        if let selectionAnchorID, !validIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = selectedAppIDs.first
        }
        if selectedAppIDs.isEmpty {
            selectedPanel = nil
            selectionAnchorID = nil
        }
    }

    private func clearSelection() {
        selectedAppIDs.removeAll()
        selectedPanel = nil
        selectionAnchorID = nil
    }

    private func isSelected(_ app: ManagedApp, in panel: DropPanel) -> Bool {
        selectedPanel == panel && selectedAppIDs.contains(app.id)
    }

    private func selectedApps(in panel: DropPanel, displayedApps: [ManagedApp]) -> [ManagedApp] {
        guard selectedPanel == panel, !selectedAppIDs.isEmpty else {
            return []
        }

        return displayedApps.filter { selectedAppIDs.contains($0.id) }
    }

    private func contextApps(for app: ManagedApp, in panel: DropPanel, selectedAppsInPanel: [ManagedApp]) -> [ManagedApp] {
        if isSelected(app, in: panel), selectedAppsInPanel.count > 1 {
            return selectedAppsInPanel
        }
        return [app]
    }

    private func handlePrimaryClick(on app: ManagedApp, in panel: DropPanel) {
        handleSelectionTap(on: app, in: panel)

        if NSApp.currentEvent?.clickCount == 2 {
            viewModel.open(app)
        }
    }

    private func handleSelectionTap(on app: ManagedApp, in panel: DropPanel) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let isCommandPressed = modifiers.contains(.command)
        let isShiftPressed = modifiers.contains(.shift)

        if selectedPanel != panel {
            selectedPanel = panel
            selectedAppIDs = [app.id]
            selectionAnchorID = app.id
            return
        }

        if isShiftPressed {
            let panelApps = sortedApps(for: panel)
            let anchorID = selectionAnchorID ?? selectedAppIDs.first ?? app.id

            guard
                let anchorIndex = panelApps.firstIndex(where: { $0.id == anchorID }),
                let targetIndex = panelApps.firstIndex(where: { $0.id == app.id })
            else {
                selectedPanel = panel
                selectedAppIDs = [app.id]
                selectionAnchorID = app.id
                return
            }

            let lowerBound = min(anchorIndex, targetIndex)
            let upperBound = max(anchorIndex, targetIndex)
            selectedPanel = panel
            selectedAppIDs = Set(panelApps[lowerBound...upperBound].map(\.id))
            return
        }

        if isCommandPressed {
            if selectedAppIDs.contains(app.id) {
                selectedAppIDs.remove(app.id)
            } else {
                selectedAppIDs.insert(app.id)
            }

            selectionAnchorID = app.id

            if selectedAppIDs.isEmpty {
                selectedPanel = nil
                selectionAnchorID = nil
            }
            return
        }

        selectedPanel = panel
        selectedAppIDs = [app.id]
        selectionAnchorID = app.id
    }

    private func selectionBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Color(nsColor: .black).opacity(0.055) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? Color(nsColor: .separatorColor).opacity(0.35) : Color.clear,
                        lineWidth: 0.8
                    )
            )
    }

    private func selectionLabelBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? Color(nsColor: .black).opacity(0.03) : Color.clear)
    }

    private func primaryTextColor(isSelected: Bool) -> Color {
        .primary
    }

    private func secondaryTextColor(isSelected: Bool) -> Color {
        .secondary
    }

    @ViewBuilder
    private func selectionMenuItems(for apps: [ManagedApp]) -> some View {
        let hasPrimaryActions = canMigrate(apps) || canCreateSystemLink(apps) || canRestore(apps)

        if canMigrate(apps) {
            Button(actionLabel("迁移到外置盘", count: apps.count)) {
                pendingOperation = makePendingOperation(
                    apps: apps,
                    kind: .migrate,
                    targetPath: viewModel.destinationSummary,
                    extraWarning: viewModel.destinationVolumeWarning
                )
            }
            .disabled(viewModel.destinationRoot == nil || viewModel.isBusy)
        }

        if canCreateSystemLink(apps) {
            Button(actionLabel("创建系统链接", count: apps.count)) {
                pendingOperation = makePendingOperation(
                    apps: apps,
                    kind: .createLink,
                    targetPath: apps.map(\.originalURL.path).joined(separator: "\n"),
                    extraWarning: nil
                )
            }
            .disabled(viewModel.isBusy)
        }

        if canRestore(apps) {
            Button(actionLabel("恢复到系统盘", count: apps.count)) {
                pendingOperation = makePendingOperation(
                    apps: apps,
                    kind: .restore,
                    targetPath: apps.map(\.currentURL.path).joined(separator: "\n"),
                    extraWarning: nil
                )
            }
            .disabled(viewModel.isBusy)
        }

        if canRemove(apps) {
            if hasPrimaryActions {
                Divider()
            }

            Button(actionLabel("移到废纸篓", count: apps.count)) {
                pendingOperation = makePendingOperation(
                    apps: apps,
                    kind: .moveToTrash,
                    targetPath: removalTargetPath(for: apps),
                    extraWarning: nil
                )
            }
            .disabled(viewModel.isBusy)

            Button(actionLabel("永久删除", count: apps.count)) {
                pendingOperation = makePendingOperation(
                    apps: apps,
                    kind: .deletePermanently,
                    targetPath: removalTargetPath(for: apps),
                    extraWarning: nil
                )
            }
            .disabled(viewModel.isBusy)
        }
    }

    private func sortedApps(_ apps: [ManagedApp]) -> [ManagedApp] {
        apps.sorted(by: sortComparator)
    }

    private func sortedApps(for panel: DropPanel) -> [ManagedApp] {
        panel == .local ? sortedLocalApps : sortedMigratedApps
    }

    private func resortDisplayedApps() {
        sortedLocalApps = sortedApps(viewModel.localApps)
        sortedMigratedApps = sortedApps(viewModel.migratedApps)
    }

    private func sortComparator(_ lhs: ManagedApp, _ rhs: ManagedApp) -> Bool {
        switch sortMode {
        case .nameAscending:
            return compareByName(lhs, rhs, ascending: true)
        case .nameDescending:
            return compareByName(lhs, rhs, ascending: false)
        case .sizeDescending:
            return compareBySize(lhs, rhs, descending: true)
        case .sizeAscending:
            return compareBySize(lhs, rhs, descending: false)
        }
    }

    private func compareByName(_ lhs: ManagedApp, _ rhs: ManagedApp, ascending: Bool) -> Bool {
        let result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if result == .orderedSame {
            return lhs.id < rhs.id
        }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compareBySize(_ lhs: ManagedApp, _ rhs: ManagedApp, descending: Bool) -> Bool {
        let lhsSize = lhs.bundleSize
        let rhsSize = rhs.bundleSize

        switch (lhsSize, rhsSize) {
        case let (lhs?, rhs?) where lhs != rhs:
            return descending ? lhs > rhs : lhs < rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return compareByName(lhs, rhs, ascending: true)
        }
    }

    private func canMigrate(_ apps: [ManagedApp]) -> Bool {
        !apps.isEmpty && apps.allSatisfy { !$0.isMigrated && $0.canMigrate }
    }

    private func canCreateSystemLink(_ apps: [ManagedApp]) -> Bool {
        !apps.isEmpty && apps.allSatisfy { $0.isMigrated && !$0.hasSystemLink && $0.canCreateSystemLink }
    }

    private func canRestore(_ apps: [ManagedApp]) -> Bool {
        !apps.isEmpty && apps.allSatisfy { $0.isMigrated && $0.canRestore }
    }

    private func canRemove(_ apps: [ManagedApp]) -> Bool {
        !apps.isEmpty && apps.allSatisfy(\.canRemove)
    }

    private func actionLabel(_ title: String, count: Int) -> String {
        count > 1 ? "\(title)（\(count) 项）" : title
    }

    private func removalTargetPath(for apps: [ManagedApp]) -> String {
        guard !apps.isEmpty else {
            return ""
        }

        if apps.count == 1, let app = apps.first {
            if !app.isMigrated {
                return app.currentURL.path
            }

            if app.hasSystemLink {
                return "/Applications 中的符号链接与外置盘应用：\n\(app.originalURL.path)\n\(app.currentURL.path)"
            }

            return app.currentURL.path
        }

        let sampleNames = apps.prefix(5).map(\.displayName).joined(separator: "、")
        let suffix = apps.count > 5 ? "\n等 \(apps.count) 项" : "\n共 \(apps.count) 项"
        return sampleNames + suffix
    }

    private func makePendingOperation(
        apps: [ManagedApp],
        kind: PendingOperation.Kind,
        targetPath: String,
        extraWarning: String?
    ) -> PendingOperation {
        PendingOperation(
            apps: apps,
            kind: kind,
            targetPath: targetPath,
            extraWarning: extraWarning
        )
    }

    private func primaryButton(for operation: PendingOperation) -> Alert.Button {
        let action: () -> Void = {
            Task {
                switch operation.kind {
                case .migrate:
                    await viewModel.migrate(operation.apps)
                case .createLink:
                    await viewModel.createSystemLink(operation.apps)
                case .restore:
                    await viewModel.restore(operation.apps)
                case .moveToTrash:
                    await viewModel.moveToTrash(operation.apps)
                case .deletePermanently:
                    await viewModel.deletePermanently(operation.apps)
                }
            }
        }

        if operation.kind == .deletePermanently {
            return .destructive(Text(operation.confirmLabel), action: action)
        }

        return .default(Text(operation.confirmLabel), action: action)
    }

    private func statusTint(for app: ManagedApp, defaultTint: Color) -> Color {
        if !app.isMigrated { return defaultTint }
        let isAvailable = app.hasSystemLink ? app.canRestore : app.canCreateSystemLink
        return isAvailable ? defaultTint : .secondary
    }

    private func dragProvider(for app: ManagedApp, in panel: DropPanel) -> NSItemProvider {
        let sourceApps = panel == .local ? sortedLocalApps : sortedMigratedApps
        let panelSelectedApps = selectedApps(in: panel, displayedApps: sourceApps)
        draggedApps = contextApps(for: app, in: panel, selectedAppsInPanel: panelSelectedApps)
        activeDropTarget = nil
        return NSItemProvider(object: app.id as NSString)
    }

    private func pendingOperation(for apps: [ManagedApp], onto panel: DropPanel) -> PendingOperation? {
        guard !viewModel.isBusy else {
            return nil
        }

        switch panel {
        case .local:
            guard canRestore(apps) else {
                return nil
            }
            return PendingOperation(
                apps: apps,
                kind: .restore,
                targetPath: apps.map(\.currentURL.path).joined(separator: "\n"),
                extraWarning: nil
            )
        case .external:
            guard canMigrate(apps), viewModel.destinationRoot != nil else {
                return nil
            }
            return PendingOperation(
                apps: apps,
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

                guard !draggedApps.isEmpty, pendingOperation(for: draggedApps, onto: panel) != nil else {
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
            draggedApps = []
        }

        guard !draggedApps.isEmpty, let operation = pendingOperation(for: draggedApps, onto: panel) else {
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

private enum AppSortMode: String, CaseIterable, Identifiable {
    case nameAscending
    case nameDescending
    case sizeDescending
    case sizeAscending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nameAscending:
            return "名称"
        case .nameDescending:
            return "名称倒序"
        case .sizeDescending:
            return "体积较大"
        case .sizeAscending:
            return "体积较小"
        }
    }
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
        case moveToTrash
        case deletePermanently
    }

    let id = UUID()
    let apps: [ManagedApp]
    let kind: Kind
    let targetPath: String
    let extraWarning: String?

    private var primaryApp: ManagedApp {
        apps[0]
    }

    private var summaryText: String {
        if apps.count == 1 {
            return primaryApp.displayName
        }

        let sampleNames = apps.prefix(3).map(\.displayName).joined(separator: "、")
        if apps.count > 3 {
            return "\(sampleNames) 等 \(apps.count) 项"
        }
        return sampleNames
    }

    var title: String {
        switch kind {
        case .migrate: return "确认迁移 \(summaryText)"
        case .createLink: return "确认创建 \(summaryText) 的系统链接"
        case .restore: return "确认恢复 \(summaryText)"
        case .moveToTrash: return "确认将 \(summaryText) 移到废纸篓"
        case .deletePermanently: return "确认永久删除 \(summaryText)"
        }
    }

    var confirmLabel: String {
        switch kind {
        case .migrate: return "开始迁移"
        case .createLink: return "创建链接"
        case .restore: return "开始恢复"
        case .moveToTrash: return "移到废纸篓"
        case .deletePermanently: return "永久删除"
        }
    }

    var message: String {
        let base: String
        switch kind {
        case .migrate:
            if apps.count == 1 {
                base = "开始前会先尝试退出该应用的运行中进程；如果无法退出，会中止迁移。\n\n应用会被复制到以下目录，并在 /Applications 原位改成符号链接：\n\(targetPath)"
            } else {
                base = "开始前会先尝试退出所选应用的运行中进程；如果其中任意应用无法退出，会中止当前批量迁移。\n\n\(apps.count) 个应用会被复制到以下目录，并在 /Applications 原位改成符号链接：\n\(targetPath)"
            }
        case .createLink:
            if apps.count == 1 {
                base = "会在以下位置创建指向外置盘应用的符号链接，不会复制应用文件：\n\(targetPath)"
            } else {
                base = "会为所选 \(apps.count) 个应用创建指向外置盘的符号链接，不会复制应用文件：\n\(targetPath)"
            }
        case .restore:
            if apps.count == 1 {
                base = "应用会从以下位置恢复回系统盘，并删除外置盘副本：\n\(targetPath)"
            } else {
                base = "所选 \(apps.count) 个应用会恢复回系统盘，并删除各自外置盘副本：\n\(targetPath)"
            }
        case .moveToTrash:
            if apps.count == 1 {
                base = "开始前会先尝试退出该应用的运行中进程；如果无法退出，会中止操作。\n\n以下应用文件会被移到废纸篓：\n\(targetPath)"
            } else {
                base = "开始前会先尝试退出所选应用的运行中进程；如果其中任意应用无法退出，会中止当前批量操作。\n\n以下所选项目会被移到废纸篓：\n\(targetPath)"
            }
        case .deletePermanently:
            if apps.count == 1 {
                base = "开始前会先尝试退出该应用的运行中进程；如果无法退出，会中止永久删除。\n\n以下应用文件会被永久删除，不能撤销：\n\(targetPath)"
            } else {
                base = "开始前会先尝试退出所选应用的运行中进程；如果其中任意应用无法退出，会中止当前批量永久删除。\n\n以下所选项目会被永久删除，不能撤销：\n\(targetPath)"
            }
        }
        guard let extraWarning, !extraWarning.isEmpty else { return base }
        return "\(base)\n\n注意：\(extraWarning)"
    }
}

private struct AppBundleIconView: View {
    let app: ManagedApp
    let size: CGFloat
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
                            .foregroundStyle(badgeColor)
                    }
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size + 4, height: size + 4)
    }

    private var iconPath: String {
        app.preferredIconPath
    }

    private var badgeSymbol: String {
        if !app.isMigrated { return "arrow.down" }
        return app.hasSystemLink ? "link" : "externaldrive.fill"
    }

    private var badgeColor: Color {
        if !app.isMigrated {
            return Color(nsColor: .secondaryLabelColor)
        }

        return app.hasSystemLink
            ? Color(nsColor: .systemGreen)
            : Color(nsColor: .systemOrange)
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
