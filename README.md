# PluralMac Plus

<img src="docs/images/icon.png" alt="" width="96" align="right">

Run the same Mac app more than once, each copy with its own login, settings and cache.

This is my fork of [PluralMac](https://github.com/Devrax/PluralMac) by Rafael Alexander Mejia Blanco. I started it because I wanted two accounts of the same app on one Mac, with the data on an encrypted drive, and I didn't want to keep juggling symlinks for that. PluralMac Plus reads the same `~/Library/PluralMac/instances.json` as the original, so existing instances keep working.

## What I added

Launcher apps. For each instance you can create a small app named after it, by default in `/Applications`. Start it from the Dock or Spotlight and the instance opens without PluralMac Plus. A hue slider lets you tint its icon so the launchers don't all look the same. When you rename an instance or move its data, the launcher gets rebuilt; deleting the instance moves the launcher to the Trash. The running app still shows its original name and icon in the Dock, because macOS takes those from the real app bundle and I don't touch that.

Data folders. You pick the data folder when you create an instance. If the folder already contains a profile, PluralMac Plus asks whether to use it or pick a different one. Settings → Storage sets the default location, and "Move Data Folder…" relocates an existing instance. If the data sits on a drive that isn't connected, the instance won't start, so you don't end up with an empty profile by accident.

Better isolation. The original only set `HOME`, which macOS's own path functions ignore. Caches, Application Support, HTTPStorages and preferences of many apps ended up in the real home folder and were shared between instances. I now also set `CFFIXED_USER_HOME`, which fixes that.

Running instances. Double-click an instance to start it, or to bring it to the front and restore a minimized window if it's already running. After restarting PluralMac Plus it still knows which instances are running, including ones started through a launcher.

Also fixed: Settings crashed on open, the menu bar entries didn't launch anything, and you can now rename instances from the sidebar.

## Building

You need macOS 14 and Xcode 26.

```bash
git clone https://github.com/knutwurst/PluralMacPlus.git
cd PluralMacPlus
scripts/build-release.sh
```

The app ends up in `dist/`. It's ad-hoc signed and not notarized, so the first time you open it, right-click it and choose Open, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/PluralMac Plus.app"
```

There are no pre-built releases yet. I'll publish 1.1 when I consider it done.

## Using it

Click +, choose the app, give the instance a name, and decide on the data folder and whether you want a launcher. The first start looks like a fresh install, so you sign in again.

Everything else lives in the sidebar's context menu and the detail view: rename, duplicate, move the data folder, manage the launcher, stop, delete. "Delete Shortcut" keeps the data; "Delete Shortcut & Data" removes it too.

## How it works

PluralMac Plus starts the original app via `NSWorkspace.openApplication` with `createsNewApplicationInstance`, and sets `HOME`, `CFFIXED_USER_HOME` and the `XDG_*` variables to the instance's data folder. For apps that support it, it adds the matching argument: `--user-data-dir` for Chromium and Electron apps, `-profile` for Firefox, `--mu` for Spotify. Desktop, Documents, Downloads and a few other folders inside the data folder link back to your real ones.

A launcher is just a bundle with a shell script that runs `open -n -a <app> --env … --args …`.

To find running instances, PluralMac Plus reads the `HOME` variable of the app's running processes and compares it with the instance folders.

## What works and what doesn't

Chromium browsers, VS Code, Cursor, Slack, Firefox and Spotify work through their own arguments. Most native and Flutter apps work through the environment variables, as long as they keep their data in the usual Library folders.

Sandboxed apps (most of the Mac App Store) and Apple's own apps can't be isolated. Neither can apps that hardcode their data paths. Discord runs in several windows but with one shared account.

Some things are always shared between instances: the Keychain, the temporary folder under `/var/folders` and macOS's shader caches.

If your data lives on an exFAT drive, quit the instances before you eject it. exFAT has no journaling and databases can get corrupted.

## Tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project PluralMac.xcodeproj -scheme PluralMac test
```

## License

MIT, see [LICENSE](LICENSE). Original code by Rafael Alexander Mejia Blanco, changes by Knutwurst.
