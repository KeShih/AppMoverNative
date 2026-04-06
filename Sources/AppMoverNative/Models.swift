import Foundation

struct StorageVolume: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let isRemovable: Bool
    let isEjectable: Bool
    let formatDescription: String?

    var destinationRoot: URL {
        url
    }

    var isRecommendedForAppBundles: Bool {
        guard let formatDescription else {
            return false
        }

        let normalized = formatDescription.lowercased()
        return normalized.contains("apfs")
            || normalized.contains("mac os extended")
            || normalized.contains("journaled hfs")
            || normalized == "hfs+"
    }

    var formatSummary: String {
        formatDescription ?? "未知格式"
    }
}

enum AppResidency: Hashable, Sendable {
    case local
    case migrated(externalURL: URL, destinationRoot: URL, isReachable: Bool)
}

struct ManagedApp: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let bundleSize: Int64?
    let originalURL: URL
    let currentURL: URL
    let residency: AppResidency
    let hasSystemLink: Bool

    var isMigrated: Bool {
        if case .migrated = residency {
            return true
        }
        return false
    }

    var canMigrate: Bool {
        !isAppleApp && !isMigrated
    }

    var canRestore: Bool {
        if case let .migrated(_, _, isReachable) = residency {
            return isReachable
        }
        return false
    }

    var canCreateSystemLink: Bool {
        if case let .migrated(_, _, isReachable) = residency {
            return !hasSystemLink && isReachable
        }
        return false
    }

    var canOpen: Bool {
        switch residency {
        case .local:
            return true
        case let .migrated(_, _, isReachable):
            return isReachable
        }
    }

    var canRemove: Bool {
        guard !isAppleApp else {
            return false
        }

        switch residency {
        case .local:
            return true
        case let .migrated(_, _, isReachable):
            return isReachable
        }
    }

    var launchURL: URL {
        if isMigrated {
            return hasSystemLink ? originalURL : currentURL
        }
        return currentURL
    }

    var preferredIconPath: String {
        switch residency {
        case .local:
            return currentURL.path
        case let .migrated(_, _, isReachable):
            if isReachable {
                return currentURL.path
            }
            return hasSystemLink ? originalURL.path : currentURL.path
        }
    }

    var isAppleApp: Bool {
        bundleIdentifier?.hasPrefix("com.apple.") == true
    }

    var sizeText: String? {
        guard let bundleSize else {
            return nil
        }

        return ByteCountFormatter.string(fromByteCount: bundleSize, countStyle: .file)
    }

    var metadataText: String? {
        var parts: [String] = []

        if let sizeText {
            parts.append(sizeText)
        }

        switch residency {
        case .local:
            break
        case let .migrated(_, _, isReachable):
            if hasSystemLink {
                parts.append(isReachable ? "系统链接已就绪" : "外置盘未连接")
            } else {
                parts.append(isReachable ? "无系统链接" : "外置盘未连接")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var residencyText: String {
        switch residency {
        case .local:
            return "位于系统盘 /Applications"
        case let .migrated(externalURL, _, isReachable):
            if isReachable {
                if hasSystemLink {
                    return "已迁移到 \(externalURL.deletingLastPathComponent().path)"
                }
                return "位于外置盘 \(externalURL.deletingLastPathComponent().path)，系统盘当前没有入口"
            }
            if hasSystemLink {
                return "外置盘当前未连接"
            }
            return "外置盘中的独立应用当前未连接"
        }
    }

    var actionTitle: String {
        if isMigrated {
            return hasSystemLink ? "恢复到系统盘" : "创建系统链接"
        }
        return "迁移到外置盘"
    }
}

struct MigrationEntry: Codable, Hashable, Identifiable, Sendable {
    let appName: String
    let originalPath: String
    let externalPath: String
    let destinationRootPath: String
    let migratedAt: Date

    var id: String { originalPath }
}

struct AppSnapshot: Sendable {
    let localApps: [ManagedApp]
    let migratedApps: [ManagedApp]
    let availableVolumes: [StorageVolume]
}
