# BalanceKeeper

**Keeps your Mac's audio balance centered — the lightest way.**

<p align="center">
  <img src="docs/screenshot.png" width="572" alt="The BalanceKeeper settings window">
</p>

macOS sometimes shifts the left/right audio balance on its own, often after the volume keys are pressed while the
Mac is busy. One ear gets quieter and you may not notice for days. BalanceKeeper puts the balance back the moment
it moves.

## Lightest by design

- **About 3 MB of memory, no CPU while idle.** Measured over 60 seconds idle: 0.0 % CPU, 0 wakeups.
- **No polling, no timers.** It sleeps until macOS reports a balance or output change.
- **Nothing on screen.** No menu bar icon and no window running in the background. The settings window runs only
  while you have it open.
- **Small.** The whole app is 1.5 MB.
- **No network, no permissions.**

Measured on macOS 26.7.1 with `footprint` and `top`.

## Features

- Locks the balance to the center, or to any point you choose
- Works on every output: built-in speakers, headphones, Bluetooth and USB audio devices, and switches with them
- Shows the current output, its balance and how often BalanceKeeper had to correct it
- Updates apply right away; moving the app to the Trash removes it cleanly

## Requirements

- A Mac with Apple silicon
- macOS 13 Ventura or later

Tested on a 14-inch MacBook Pro (Apple silicon) with macOS 26.7.1 Tahoe.

## Install

### Homebrew

```sh
brew install --cask fratayaydn/tap/balancekeeper
```

### Download

Download `BalanceKeeper-<version>.dmg` from the
[latest release](https://github.com/fratayaydn/balancekeeper/releases/latest), open it and drag **BalanceKeeper**
to **Applications**. The app is signed with a Developer ID and notarized by Apple.

### First run

Open **BalanceKeeper** and turn on **Enable BalanceKeeper**. That's it: it needs no permissions.

The settings window is only for settings: close it and BalanceKeeper keeps running in the background.

## Settings

**Keep balance at** is the same balance as in **System Settings > Sound**: moving it here moves that slider too.
While BalanceKeeper is on, change the balance here rather than in System Settings. macOS reports a change made
there exactly like a drift, so BalanceKeeper would put it back.

Leave it in the center unless you want to compensate for your hearing or your speakers.

## How it works

- `BalanceKeeper.app/Contents/MacOS/balancekeeperd` is a small background agent, registered as a login item
  through `SMAppService`. It asks CoreAudio to report changes to the default output device and to its balance, and
  otherwise sleeps.
- When the balance moves away from the lock point, it sets it back: the stereo pan for built-in speakers and most
  devices, the system's virtual balance for Bluetooth and many USB devices, or the lowered channel's volume for
  devices that only have separate left and right volumes.
- It watches its app bundle through the kernel's event queue (no polling): when the app is replaced by an update it
  restarts with the new version, and when the app is moved to the Trash it removes its login item and quits.
- `BalanceKeeper.app/Contents/MacOS/BalanceKeeper` is the SwiftUI settings window. It runs only while open.

BalanceKeeper uses only public macOS APIs.

## Building from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/fratayaydn/balancekeeper.git
cd balancekeeper
make install
```

This builds `BalanceKeeper.app`, copies it to `/Applications` and opens it. To update, pull and run `make install`
again.

Local builds are signed with a self-signed certificate that `scripts/create-signing-identity.sh` creates on the
first build, so the login item keeps working across rebuilds; `scripts/install.sh` re-registers it after each
update. To sign with your own Apple Developer ID instead:
`make install SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"`.

## Uninstall

Move **BalanceKeeper** from Applications to the Trash (or `brew uninstall --cask balancekeeper`). The background
agent notices, removes its login item and quits. If you built it from source, `make uninstall` in the cloned folder
also removes the settings.

## Command line

```sh
/Applications/BalanceKeeper.app/Contents/MacOS/balancekeeperd --status   # prints the output and its balance
```

## License

MIT — see [LICENSE](LICENSE).
