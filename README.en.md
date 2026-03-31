# AppMover Native

AppMover Native is a native macOS utility prototype for moving third-party apps from `/Applications` to an external drive, then restoring them back to the internal system volume when needed.

The current implementation is built with SwiftUI and AppKit. The goal is a practical desktop utility without Electron or background helper services.

Language:

- [中文](./README.zh-CN.md)
- [English](./README.en.md)
- [日本語](./README.ja.md)

## Current Features

- Scan third-party `.app` bundles in `/Applications`
- Detect available external volumes under `/Volumes` and support a custom destination directory
- Move apps to an external drive while keeping a symbolic link at the original path
- Detect apps that already live on an external drive, including ones without an existing system symlink
- Restore apps back to the system volume
- Create a system symlink for standalone apps stored on an external drive
- Support both list and grid layouts
- Open apps directly from inside the tool
- Attempt to stop the target app's running processes before migration or restore
- Provide a native packaging script to produce a runnable `.app`

## Good Fit

- Your internal disk is running out of space and you want to move large third-party apps to an external SSD
- You want to preserve the `/Applications/AppName.app` entry point so launchers, scripts, or Spotlight keep working
- You already moved an app manually and want to recreate a consistent system entry point

## Not a Good Fit

- Apple-preinstalled apps
- Apps that depend on a fixed install volume, system extensions, background agents, or complex updaters
- Some Mac App Store apps with strict signing or installation-location assumptions
- External volumes formatted as ExFAT, FAT, or NTFS, which are not ideal for storing macOS `.app` bundles long term

## Development Environment

- macOS 14+
- Xcode 16+ or Swift 6.2 command line tools

## Run Locally

```bash
swift run
```

## Package as a `.app`

```bash
chmod +x scripts/package-app.sh
./scripts/package-app.sh
```

The packaged app is generated at:

```text
dist/AppMoverNative.app
```

## Project Structure

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

## Design Notes

- This is a native macOS project, not a cross-platform shell
- Migration is effectively "copy to external drive + replace original path with a symlink"
- Operations that write to `/Applications` or replace app bundles still require system authorization
- To reduce file-lock and in-use issues, the app first tries to terminate the target app before migration or restore
- The current focus is stability and control rather than visual flourish

## Known Limitations

- Some app updaters may reinstall the app back onto the system volume
- If the external drive is disconnected, apps that rely on symlinks will not launch
- Drag-and-drop migration interactions are still being refined
- There is no auto-update mechanism yet

## License

This project is released under [WTFPL](./LICENSE).
