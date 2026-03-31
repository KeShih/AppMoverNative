# AppMover Native

一个原生 macOS SwiftUI 原型，用来把 `/Applications` 中的第三方应用迁移到外置硬盘，并在原位置保留符号链接，随后支持一键恢复。

## 当前能力

- 扫描 `/Applications` 下的第三方 `.app` 应用
- 自动发现 `/Volumes` 下已挂载的外置卷
- 选择推荐外置卷或自定义外置目录作为迁移根目录
- 迁移时使用管理员授权复制应用到外置盘，再把原路径替换为符号链接
- 恢复时把外置盘中的应用复制回系统盘，并清理外置盘副本
- 在 `~/Library/Application Support/AppMoverNative/migrations.json` 保存迁移记录

## 运行方式

```bash
cd /Users/keshi/Code/tmp/AppMoverNative
swift run
```

也可以直接用 Xcode 打开这个 Swift Package 进行调试或打包。

## 打包成 .app

```bash
cd /Users/keshi/Code/tmp/AppMoverNative
chmod +x scripts/package-app.sh
./scripts/package-app.sh
```

打包结果会出现在 `dist/AppMoverNative.app`，可以直接双击启动。

## 重要限制

- 默认跳过 Apple 预装应用，避免影响系统完整性和系统更新
- 依赖管理员密码，因为 `/Applications` 和符号链接操作需要更高权限
- 推荐把应用迁移到 APFS 或 Mac OS Extended 外置卷；ExFAT、FAT、NTFS 不适合稳定保存 macOS `.app`
- 某些 App Store 应用、带系统扩展的应用、或强依赖固定安装卷的应用，不建议迁移
- 迁移本质上是“复制到外置盘 + 原位符号链接”，不是 APFS 克隆或真正的系统级卸载
