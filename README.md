# PluralMac Plus

<img src="docs/images/icon.png" alt="" width="96" align="right">

Run the same Mac app more than once, each copy with its own login, settings and cache.

<p align="center">
  If you like what I do, you can buy me a coffee*: <a href="https://paypal.me/oliverkoester"><img src="https://img.shields.io/badge/Donate-PayPal-0070ba?style=for-the-badge&logo=paypal&logoColor=white" alt="Donate with PayPal" align="absmiddle"></a><br>
  <sub>*It doesn't have to be a big donation. A few cents show me who uses the tool and cares about where it goes next. That keeps me motivated, and I know I'm not coding for the bin ;)</sub>
</p>

This is my fork of [PluralMac](https://github.com/Devrax/PluralMac) by Rafael Alexander Mejia Blanco. I started it because I wanted two accounts of the same app on one Mac, with the data on an encrypted drive, and I didn't want to keep juggling symlinks for that. PluralMac Plus reads the same `~/Library/PluralMac/instances.json` as the original, so existing instances keep working.

## What I added

Launcher apps. For each instance you can create a small app named after it, by default in `/Applications`. Start it from the Dock or Spotlight and the instance opens without PluralMac Plus. A hue slider lets you tint its icon so the launchers don't all look the same. When you rename an instance or move its data, the launcher gets rebuilt; deleting the instance moves the launcher to the Trash. The running app still shows its original name and icon in the Dock, because macOS takes those from the real app bundle and I don't touch that.

Data folders. You pick the data folder when you create an instance. If the folder already contains a profile, PluralMac Plus asks whether to use it or pick a different one. Settings → Storage sets the default location, and "Move Data Folder…" relocates an existing instance. If the data sits on a drive that isn't connected, the instance won't start, so you don't end up with an empty profile by accident.

Better isolation. The original only set `HOME`, which macOS's own path functions ignore. Caches, Application Support and HTTPStorages of many apps ended up in the real home folder and were shared between instances. I now also set `CFFIXED_USER_HOME`, which fixes that. Preferences stored through `UserDefaults` need more: the system's preferences daemon picks the folder itself and ignores both variables. With "Separate preferences" turned on, PluralMac Plus loads a small library into the app (`DYLD_INSERT_LIBRARIES`) that points the app's standard defaults at a plist in the instance folder. macOS only allows that for apps without Hardened Runtime or apps that opt in to it. New instances get it by default, existing ones take a copy of the shared preferences when you turn it on.

Private copies. For apps that don't allow the library, an instance can run from its own copy of the app instead ("Use a Private Copy…"). PluralMac Plus clones the app (APFS, so it takes almost no disk space), renames it to the instance, gives it the launcher icon and signs it again without Hardened Runtime. Separate preferences then work, and Dock and Cmd-Tab show the instance name. The copy starts through a small script that sets up the instance first, so you can keep it in the Dock ("Options → Keep in Dock") and start it from there, from Finder or from Spotlight. Updates of the original don't reach the copy; when the original changes version, PluralMac Plus offers to recreate it. Apps that depend on iCloud, push notifications or keychain groups may not start from a copy.

Apps with their own profile folder. Chromium, Electron and Firefox apps keep everything in the folder passed as `--user-data-dir` or `-profile`. You can point an instance at a profile that already exists ("Use Existing Profile…"); PluralMac Plus passes the path and never writes into it. These apps run with your normal home folder, because a redirected `HOME` hides the login keychain from them: they can't store new keys there, and Electron apps then keep their database key unencrypted. A re-signed copy would risk losing access to keychain items too, so instead they get their own Dock app ("Use Own Dock Name and Icon"): a small bundle with the instance's name and icon whose script starts the original binary. The Dock shows the instance name and icon, the original app stays untouched and keeps its updates, and you can keep the Dock app in the Dock. One limit: macOS still counts the running instance as the original app. If an instance is already running and you then open the original app itself, macOS only brings the instance to the front. Start the original first, or give it an instance of its own.

Separate device ID. Some apps identify the Mac by its hardware UUID, so two instances look like the same device to the app's server. The server then only talks to one of them. Turn on "Separate device ID" for an instance and it sees its own UUID; "New Device ID…" hands out a fresh one. It works for apps that ask `ioreg` through the shell, which covers the Flutter plugins I've looked at.

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

Everything else lives in the sidebar's context menu and the detail view: rename, duplicate, move the data folder, manage the launcher, set extra environment variables and arguments, stop, delete. Drag instances in the sidebar to change their order. "Delete Shortcut" keeps the data; "Delete Shortcut & Data" removes it too.

## How it works

PluralMac Plus starts the original app via `NSWorkspace.openApplication` with `createsNewApplicationInstance`, and sets `HOME`, `CFFIXED_USER_HOME` and the `XDG_*` variables to the instance's data folder. Desktop, Documents, Downloads and a few other folders inside the data folder link back to your real ones. Apps with a profile argument get that instead and keep your `HOME`: `--user-data-dir` for Chromium and Electron apps, `-profile` for Firefox. Spotify gets `--mu`.

A launcher is just a bundle with a shell script that runs `open -n -a <app> --env … --args …`. A Dock app is a bundle with its own bundle ID whose script exports the environment and `exec`s the original binary with the instance's arguments.

To find running instances, PluralMac Plus reads the environment and arguments of the app's running processes and compares `HOME` or the profile argument with the instances.

## What works and what doesn't

Chromium browsers, VS Code, Cursor, Slack, Firefox and Spotify work through their own arguments. Most native and Flutter apps work through the environment variables, as long as they keep their data in the usual Library folders.

Sandboxed apps (most of the Mac App Store) and Apple's own apps can't be isolated. Neither can apps that hardcode their data paths. Discord runs in several windows but with one shared account.

Some things are always shared between instances: preferences an app writes outside `UserDefaults.standard` (for example a bundled Sparkle updater's last check time), the Keychain, notification settings, global keyboard shortcuts, the temporary folder under `/var/folders` and macOS's shader caches. If the app updates itself, quit all its instances first, since they all run from the same app bundle.

If your data lives on an exFAT drive, quit the instances before you eject it. exFAT has no journaling and databases can get corrupted. exFAT also can't store file attributes, so macOS keeps them in hidden `._name` files and deletes those together with the file. Some apps fail when they delete a folder on startup and a `._` file vanishes underneath them; for one app that meant a black window on every second start. PluralMac Plus removes these `._` files from the instance folder before each launch on FAT and exFAT drives. An APFS volume (encrypted, if you like) avoids all of this.

## Tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project PluralMac.xcodeproj -scheme PluralMac test
```

## License

MIT, see [LICENSE](LICENSE). Original code by Rafael Alexander Mejia Blanco, changes by Knutwurst.
