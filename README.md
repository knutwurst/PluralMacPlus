<h1 align="center">PluralMac Plus</h1>

<p align="center">
  <img src="docs/images/icon.png" alt="PluralMac Plus icon" width="128" height="128">
</p>

<p align="center">
  <strong>Run several copies of the same Mac app side by side, each with its own accounts, settings and cache.</strong>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <a href="#whats-new-in-plus">What's new</a> •
  <a href="#getting-started">Getting started</a> •
  <a href="#usage">Usage</a> •
  <a href="#how-it-works">How it works</a> •
  <a href="#compatibility">Compatibility</a> •
  <a href="#troubleshooting">Troubleshooting</a>
</p>

---

PluralMac Plus starts the apps you already have with a separate data folder per instance. You keep one installation of the app and get as many independent profiles as you need: a work and a personal account, a test profile, a client setup. The original app stays untouched.

PluralMac Plus is a fork of [PluralMac](https://github.com/Devrax/PluralMac) by Rafael Alexander Mejia Blanco. It reads the same `~/Library/PluralMac/instances.json`, so instances you created with PluralMac carry over.

## What's new in Plus

### 🚀 Launcher apps

Give every instance its own app. PluralMac Plus creates a small launcher named after the instance, in `/Applications` or any folder you pick. Start it from the Dock, Launchpad or Spotlight and the instance opens directly, without PluralMac Plus running.

- **Icon color:** a hue slider with live preview tints the launcher icon, so you can tell your instances apart at a glance.
- **Stays in sync:** rename the instance or move its data, and PluralMac Plus rebuilds the launcher. Launchers from an older version get updated on the next start.
- **Safe removal:** deleting an instance or pressing **Remove** moves the launcher to the Trash. PluralMac Plus never overwrites an app it didn't create.

The running app keeps its original name and icon in the Dock. macOS shows the bundle of the running process there, and PluralMac Plus doesn't copy or modify that bundle.

### 📁 Your data, where you want it

- **Pick the data folder when you create an instance.** Choose an empty folder for a fresh profile, or a folder that already holds a profile. PluralMac Plus asks whether you want to continue with the existing data or choose another folder. It never offers to delete anything.
- **Default location:** Settings → Storage → Data Directory decides where new instances go. Leave it empty for `~/Library/PluralMac/Data`.
- **Move Data Folder…** relocates an existing instance, for example to an encrypted external drive.
- **Unplugged drive protection:** if an instance's data lives on a volume that isn't connected, PluralMac Plus refuses to launch it and tells you why. Without that check the app would start with an empty profile.

### 🔒 Stronger isolation

The original PluralMac redirected `HOME`. macOS's own path APIs ignore `HOME`, so caches, `Application Support`, `HTTPStorages` and preferences of many apps still landed in your real home folder and got shared between instances. PluralMac Plus also sets `CFFIXED_USER_HOME`, which moves all of those into the instance's data folder.

### 🪟 Manage running instances

- **Double-click an instance** in the sidebar: PluralMac Plus starts it, or brings it to the front if it's already running and restores a minimized window, like a click on its Dock icon.
- **Show** in the detail view does the same.
- **Running status survives restarts.** Quit and reopen PluralMac Plus, and it still recognizes which instances are running, including the ones you started through a launcher.

### 🛠 Fixes

- Opening Settings crashed the app (in the original 1.0 as well).
- The menu bar entry of an instance launched nothing. It now starts the instance or brings it to the front.
- You can rename instances from the sidebar's context menu, and blank names get rejected.

## Getting started

### Requirements

- macOS 14 Sonoma or later
- Xcode 26 to build from source
- The app you want to run more than once must not be sandboxed (most Mac App Store apps are)

### Build

```bash
git clone https://github.com/knutwurst/PluralMacPlus.git
cd PluralMacPlus
scripts/build-release.sh
```

The script builds the Release configuration and puts `PluralMac Plus.app` plus a zip into `dist/`. Move the app to `/Applications`. If `xcode-select` points to the Command Line Tools, the script switches to `/Applications/Xcode.app` by itself.

You can also open `PluralMac.xcodeproj` in Xcode and press ⌘R.

The build is ad-hoc signed and not notarized. On first launch, right-click the app and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/PluralMac Plus.app"
```

I'll publish pre-built releases once version 1.1 is finished.

## Usage

### Create an instance

1. Click **+** and select the app.
2. Give the instance a name.
3. Under **Data Folder**, keep the default or choose a folder.
4. Under **Launcher App**, decide whether you want a launcher, where it goes and which color its icon gets.
5. Click **Create**.

On first launch the instance starts with an empty profile, so you sign in like on a new machine.

### Everyday use

| Action | Where |
|---|---|
| Start or bring to front | Double-click in the sidebar, **Launch** / **Show** in the detail view, or the menu bar |
| Stop | **Stop** in the detail view, or the stop icon when you hover over an instance |
| Rename | Right-click → **Rename…** |
| Move the data folder | Right-click → **Move Data Folder…** (the instance must not be running) |
| Launcher app | Detail view → **Launcher App**: create, recreate, move, remove, change color |
| Open the data folder | Right-click → **Show Data Folder** |
| Duplicate | Right-click → **Duplicate** |
| Delete | Right-click → **Delete Shortcut** keeps the data, **Delete Shortcut & Data** removes it too |

## How it works

PluralMac Plus starts the original app through `NSWorkspace.openApplication` with `createsNewApplicationInstance`, so macOS treats every instance as a separate process. Each instance gets:

- **Environment:** `HOME` and `CFFIXED_USER_HOME` point to the data folder, plus the `XDG_*` variables for apps that follow them.
- **App-specific arguments** where an app supports them, such as `--user-data-dir` for Chromium and Electron apps, `-profile` for Firefox and `--mu` for Spotify.
- **A prepared data folder** with links to your real Desktop, Documents, Downloads, Movies, Music, Pictures, Public and Keychains, so file dialogs and saved passwords keep working.

A **launcher app** is a tiny bundle with an `Info.plist`, an icon and a shell script that calls `open -n -a <app> --env … --args …`, the same launch PluralMac Plus performs.

To **recognize running instances**, PluralMac Plus reads the `HOME` variable of running processes of the target app and matches it against the instance data folders.

```
~/Library/PluralMac/
├── instances.json        # instance configuration
└── Data/                 # default location for instance data
    └── <instance-id>/
        ├── Library/
        │   ├── Application Support/
        │   ├── Caches/
        │   ├── HTTPStorages/
        │   └── Preferences/
        └── Desktop -> ~/Desktop, Documents -> ~/Documents, …
```

## Compatibility

| App | Method | Notes |
|---|---|---|
| Google Chrome, Microsoft Edge, Brave, Arc, Vivaldi | `--user-data-dir` | Full profile isolation |
| VS Code, Cursor | `--user-data-dir` | Separate settings and extensions |
| Slack | `--user-data-dir` | Separate workspaces |
| Firefox, Waterfox | `-profile` | Separate profiles |
| Spotify | `--mu` | Official multi-instance support |
| Flutter and native macOS apps | `HOME` + `CFFIXED_USER_HOME` | Works when the app stores its data in the usual Library folders |
| Discord | `--multi-instance` | Several windows, but one shared account |

PluralMac Plus can't isolate:

- **Sandboxed apps**, including most Mac App Store apps. macOS gives them a fixed container.
- **Apple system apps.** System Integrity Protection guards them.
- **Apps with hardcoded data paths** that ignore both arguments and environment.

A few things stay shared between instances: the Keychain, the per-user temporary folder (`/var/folders/…/T`) and macOS's shader caches.

## Troubleshooting

**The instance shows the data of the original app.** The app ignores the isolation methods above. Check the compatibility table. Editing custom arguments and environment variables in the UI isn't implemented yet; you can add them to the instance in `~/Library/PluralMac/instances.json` while PluralMac Plus is closed.

**"The data folder is on … which is not connected."** The instance's data lives on an external or encrypted volume that isn't mounted. Connect or unlock it and launch again.

**An external drive with exFAT.** exFAT has no journaling. Quit your instances before you eject the drive, otherwise their databases can get damaged.

**The app won't launch.** Make sure the original app still sits at the path shown in the detail view. Console.app lists errors under the subsystem `com.knutwurst.PluralMacPlus`.

**"App is damaged" or "can't be opened".** Gatekeeper blocks the ad-hoc signed build. See the `xattr` command under [Build](#build).

## Development

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project PluralMac.xcodeproj -scheme PluralMac test
```

The `PluralMacTests` target covers data locations, moving data folders, launcher generation, icon tinting, process discovery and window activation.

To add support for another app, extend the app type detection in `Services/AppTypeDetector.swift` and the arguments in `AppInstance.effectiveCommandLineArguments`.

## Credits and license

PluralMac Plus builds on [PluralMac](https://github.com/Devrax/PluralMac) by Rafael Alexander Mejia Blanco. Maintained by [Knutwurst](https://github.com/knutwurst).

MIT License. See [LICENSE](LICENSE).
