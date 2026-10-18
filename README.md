# PluralMac Plus

<img src="docs/images/icon.png" alt="" width="96" align="right">

Run the same Mac app several times, each instance with its own login and data.

<p align="center">
  If you like what I do, you can buy me a coffee*: <a href="https://paypal.me/oliverkoester"><img src="https://img.shields.io/badge/Donate-PayPal-0070ba?style=for-the-badge&logo=paypal&logoColor=white" alt="Donate with PayPal" align="absmiddle"></a><br>
  <sub>*It doesn't have to be a big donation. A few cents show me who uses the tool and cares about where it goes next. That keeps me motivated, and I know I'm not coding for the bin ;)</sub>
</p>

I wanted two accounts of one app on my Mac, with the data on an encrypted drive, and got tired of symlink tricks. [PluralMac](https://github.com/Devrax/PluralMac) by Rafael Alexander Mejia Blanco did most of what I needed, so I forked it and kept going. It still reads `~/Library/PluralMac/instances.json`, so instances from the original carry over.

## Download

Grab the zip from [Releases](https://github.com/knutwurst/PluralMacPlus/releases) and move the app to `/Applications`. I don't have a paid Apple developer account, so the app isn't notarized. Right-click it and choose Open the first time, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/PluralMac Plus.app"
```

## Usage

Click +, pick the app, name the instance and choose where its data should go. The first start behaves like a fresh install, so you'll have to sign in again.

Everything else sits in the detail view and the sidebar's context menu. You can rename, duplicate and reorder instances (drag them), move their data, change the icon color, add environment variables or arguments. "Delete Shortcut & Data" moves the data folder to the Trash. If you pointed an instance at an existing profile, that profile stays where it is.

## What's different from the original

- You choose the data folder when you create an instance and can move it later. If it's on a drive that isn't plugged in, the instance won't start, which beats ending up with an empty profile.
- The original only changed `HOME`, and a lot of apps ignore it, so caches and app data still ended up shared. Plus fixes that. Preferences can be separated too ("Separate preferences"), for apps that allow it.
- If an app refuses the preferences trick, an instance can run from a private copy of it. That copy shows up in the Dock under the instance name and with its own color. Downside: updates of the original don't reach the copy, but Plus tells you when it's time to rebuild it. Chromium and Electron apps get a small Dock app instead of a copy, so the original stays untouched.
- For browsers and Electron apps you can point an instance at a profile folder you already have. Plus never writes into it.
- Some apps recognize the Mac by its hardware ID, and their server then treats two instances as one device. "Separate device ID" gives each instance its own.
- Launcher apps: a small app named after the instance that starts it without opening Plus. Handy for Spotlight.
- Double-clicking a running instance brings it to the front. After a restart, Plus still knows which instances are running.
- Some fixes on top: Settings no longer crashes, and the menu bar entries work.

## Limits

- Sandboxed apps (most of the App Store) and Apple's own apps can't be separated. Neither can apps that hardcode their paths.
- Discord opens several windows, but they all share one account.
- The Keychain, notification settings and global shortcuts are shared by all instances.
- When an app updates itself, quit all of its instances first.
- If an instance of a Chromium or Electron app is already running and you open the original app afterwards, macOS just brings the instance to the front. Start the original first.
- Data on an exFAT drive works, but quit the instances before you eject it. exFAT has no journal, and I've had one app hang because of the hidden `._` files macOS puts there. Plus cleans those up before every launch. An APFS volume avoids the whole issue.

## How it works, briefly

Plus starts the original app with a few changed environment variables, mainly `HOME`, so the app writes into the instance folder. Browsers and Electron apps get their profile path as an argument instead (`--user-data-dir`, `-profile`) and keep your normal home folder. Otherwise they can't use the login keychain.

## Building

macOS 14 and Xcode 26:

```bash
git clone https://github.com/knutwurst/PluralMacPlus.git
cd PluralMacPlus
scripts/build-release.sh
```

The app lands in `dist/`. Run the tests with:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project PluralMac.xcodeproj -scheme PluralMac test
```

## License

MIT, see [LICENSE](LICENSE). Original code by Rafael Alexander Mejia Blanco, everything since the fork by Knutwurst.
