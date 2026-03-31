# AppMover Native

一个原生 macOS 工具原型，用来把系统盘 `/Applications` 里的第三方应用迁移到外置硬盘，并在需要时恢复回系统盘。

当前实现基于 SwiftUI + AppKit，目标是做一个不依赖 Electron、不依赖 LaunchAgent 的桌面实用工具。

## 当前能力

- 扫描 `/Applications` 下可安全迁移的第三方 `.app`
- 自动识别 `/Volumes` 下可用外置卷，并支持自定义目标目录
- 迁移应用到外置盘，并在原路径保留符号链接
- 自动识别已经位于外置盘的应用，包括没有创建系统符号链接的应用
- 支持恢复到系统盘
- 支持为外置盘独立应用补建系统符号链接
- 支持列表 / 方块两种视图
- 支持在应用内直接打开目标 App
- 提供原生打包脚本，生成可直接运行的 `.app`

## 适用场景

- 系统盘空间紧张，希望把大型第三方 App 挪到外置 SSD
- 想保留 `/Applications/AppName.app` 这个入口路径，避免常见启动器、脚本或 Spotlight 入口失效
- 已经手动把 App 放到外置盘，但还想在系统盘补一个统一入口

## 不适合的场景

- Apple 预装应用
- 强依赖固定安装卷、系统扩展、后台代理或复杂自更新器的应用
- Mac App Store 应用里对签名和安装位置要求特别严格的个别 App
- ExFAT、FAT、NTFS 这类不适合长期承载 macOS `.app` 包的文件系统

## 开发环境

- macOS 14+
- Xcode 16+ 或带 Swift 6.2 的命令行工具

## 本地运行

```bash
swift run
```

## 打包成 `.app`

```bash
chmod +x scripts/package-app.sh
./scripts/package-app.sh
```

打包结果位于：

```text
dist/AppMoverNative.app
```

## 项目结构

```text
Sources/AppMoverNative/
  AppMoverNativeApp.swift
  AppMoverViewModel.swift
  ContentView.swift
  MigrationService.swift
  Models.swift

Packaging/
  Info.plist
  AppIcon-1024.png

scripts/
  package-app.sh
  generate_app_icon.py
```

## 设计说明

- 这是一个原生 macOS 项目，不是跨平台壳
- 迁移的本质是“复制到外置盘 + 原位符号链接”
- 涉及 `/Applications` 写入、替换和符号链接操作时，仍然需要系统授权
- 当前重点是稳定性和可控性，不追求花哨 UI

## 已知限制

- 某些 App 的升级器可能会重新写回系统盘
- 外置盘断开后，依赖符号链接的 App 无法启动
- 拖拽迁移交互仍在打磨中
- 目前还没有自动更新机制

## License

本项目使用 [WTFPL](./LICENSE) 开源。
