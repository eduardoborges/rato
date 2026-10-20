<div align="center">
  <img src=".github/icon.png" width="128" alt="Rato app icon">
  <h1>🐭 Rato</h1>
  <p>Logitech mouse settings in the <strong>macOS</strong> menu bar: battery with time left, DPI, polling rate and lighting.<br>
  <strong>No G HUB running:</strong> Rato talks HID++ to the mouse directly and saves changes to its onboard profile, so they stay after the app quits.<br>
  Rato is what Portugal calls a computer mouse.</p>

  [![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#requirements)
  [![swift](https://img.shields.io/badge/Swift-AppKit-orange)](app/Sources/Rato/)
  [![license](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

</div>

---

**[How it works](RELATORIO.md)** · **[Command line](#command-line)**

## Why

G HUB is big, keeps an agent and an updater daemon running all the time, and on my Mac it got stuck on the loading screen. What it does for a G703 (battery, DPI, polling rate, lighting) comes down to a few HID++ calls, so Rato makes just those, from the menu bar.

## What it does

- 🔋 **Battery with time left.** Percentage from the mouse's own discharge curve, plus the hours of use left at the current polling rate and lighting. The numbers come from the power model G HUB downloads for the mouse; without G HUB installed, Rato shows a voltage-based percentage only.
- 🎯 **DPI levels.** Edit the levels and pick the default one. The change applies right away.
- ⚡ **Polling rate.** 1, 2, 4 or 8 ms.
- 💡 **Lighting.** Off, fixed color, breathing or color cycle.
- 💾 **Saved on the mouse.** Changes go to the active onboard profile, the same place G HUB writes, so they keep working with Rato closed and after sleep. Every write backs up the profile sectors first and writes the original back if it fails halfway.

And the rest:

- A mouse icon in the menu bar that fills up with the battery level, with an optional percentage next to it.
- A command line with the same settings, plus profile dumps, backup and restore.
- A driver layer for other brands. A generic driver already shows the Bluetooth battery of any mouse.
- It refuses to write while G HUB's agent runs, since both would talk over the same HID++ channel.
- The interface is in Portuguese for now.

## Requirements

- macOS 13 or later
- A Logitech mouse with HID++ 2.0 and onboard profiles (feature `0x8100`). Only tested on a G703 LIGHTSPEED on its USB receiver.
- G HUB closed while Rato writes. It can stay installed, and it has to be installed for the time left estimate.
- Input Monitoring permission for Rato.app. macOS asks on first launch.

## 🛠 Build

You need Xcode 26 or later, because `actool` compiles the Icon Composer icon.

```sh
git clone https://github.com/eduardoborges/rato
cd rato
app/build.sh             # app/build/Rato.app
open app/build/Rato.app
```

`build.sh` signs ad hoc. With `SIGN_IDENTITY` set it signs for distribution with the hardened runtime, and `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` and `NOTARY_KEY_P8` add notarization. `--dmg` also builds `app/build/Rato.dmg`.

While developing, `swift run` in `app/` starts the menu bar app from the terminal, which lends it the terminal's Input Monitoring permission.

## Command line

The same binary takes commands:

```sh
cd app
swift run Rato state                         # DPI, polling rate, mode and lighting effects
swift run Rato profiles                      # the 5 profiles stored on the mouse
swift run Rato set dpi 400,800,1600,3200 4   # DPI levels and which one is the default
swift run Rato set dpi-default 2
swift run Rato set rate 1                    # polling in ms: 1, 2, 4 or 8
swift run Rato set led off                   # or: color ff0000, breathe 00ff00, cycle
swift run Rato backup
swift run Rato restore <backup folder>
swift run Rato selftest                      # driver routing, Bluetooth battery parser, power model
```

Backups go to `~/Library/Application Support/Rato/backups/`.

## Battery time left

G HUB downloads a `battery.xml` for each mouse into `/Library/Application Support/Logi/LGHUB/depots/`. Its discharge curve maps the voltage to the energy already used, and its power blocks give the draw in mW of the sensor, the MCU, each polling rate and each lighting effect. Rato reads that file, finds the energy left at the current voltage and divides it by the draw of the active profile. On a full G703 at 1 ms that gives 34.5 h with the lighting at full brightness and 60.6 h with it off. Logitech advertises 35 h and 60 h.

The estimate assumes continuous use. An idle mouse sleeps and lasts longer. The file belongs to Logitech, so it isn't in this repo; Rato only reads it from disk.

## Common problems

| Symptom | What to do |
|---|---|
| Grayed out icon | Move the mouse to wake it and click "Re-escanear". If that doesn't help, quit G HUB. `probe` shows what the receiver answered |
| The menu says "Não gravou" | Move the mouse to wake it and try again. If a write fails halfway, Rato writes the original back; `restore` brings back any backup |
| `probe` finds no device | The receiver isn't plugged in, or another process holds the HID channel |
| Nothing shows up in Rato.app | Turn on Rato in System Settings > Privacy & Security > Input Monitoring and reopen it |

## Limitations

- Buttons can't be remapped yet.
- Lighting uses the same effect on both G703 zones.
- The menu has a fixed color palette, and breathing and cycle run at 4 s and 8 s at full intensity. Other colors only from the command line.
- Without G HUB installed, the percentage is a straight line between 3400 and 4120 mV and there's no time left estimate.
- One mouse per receiver: the first slot that answers.
- Rato doesn't start at login.

## Other mice

Each brand has a driver in `app/Sources/Rato/Drivers/`. There are two today:

| Driver | Mice | What it does |
|---|---|---|
| Logitech | HID++ 2.0, direct or on a receiver | battery, DPI, polling rate, lighting and profile backup |
| Generic | any external mouse without its own driver | name and, over Bluetooth, battery |

The generic driver hasn't been tested with a real mouse, because the only one here was the G703. Its battery parser was checked against two Bluetooth keyboards (`Rato selftest`).

To add a brand:

1. Create `Drivers/<Brand>/` with a class that implements `MouseDriver` and `MouseDriverType`, with the brand's vendor IDs in `vendorIDs`.
2. In `probe`, recognize the right HID interface and return one driver per mouse. Return nothing for the other interfaces.
3. Add the class to `Drivers.all`, before `GenericDriver`.

The menu and the command line show DPI, polling and lighting according to what `readSettings()` returns.

## Reverse engineering

[RELATORIO.md](RELATORIO.md) has the protocol notes, in Portuguese: HID++ framing on macOS, feature discovery, battery, the lighting recipe, the onboard profile layout and the battery model.

The repo also sets up [REA](https://github.com/morluto/rea) for Claude Code without touching the global config. mise installs Node, Java 21, Ghidra 12.1.4 and REA itself:

```sh
mise install
mise exec -- rea doctor --provider ghidra --json
```

Then open Claude Code at the repo root. `.mcp.json` registers the server and the skill lives in `.claude/skills/`. Ghidra's zip ships no decompiler for arm64 Macs, so the first `mise install` builds one (it needs the Xcode Command Line Tools).

The analyzed binary stays out of git. It's 105 MB and belongs to Logitech, so it can't be redistributed. To recreate it with G HUB installed:

```sh
mkdir -p analysis
lipo -thin arm64 \
  /Applications/lghub.app/Contents/MacOS/lghub_agent.app/Contents/MacOS/lghub_agent \
  -output analysis/lghub_agent.arm64
shasum -a 256 analysis/lghub_agent.arm64
# 830c86d14865bfd263e11582af756c919985e10fb87542d3acf9e11f4d2151f8 (the analyzed version)
```

## Repository layout

- `app/`: the Swift package. `Core/` has the shared model and the HID engine, `Drivers/` one driver per brand
- `app/AppIcon.icon`: the Icon Composer icon
- `app/build.sh`: builds and signs `Rato.app`
- `RELATORIO.md`: the protocol, step by step
- `mise.toml` and `scripts/`: the analysis tools
- `.mcp.json` and `.claude/`: REA for Claude Code
- `analysis/lghub_agent.arm64`: the arm64 slice of `lghub_agent`, where the protocol came from (not in git)

## License

MIT, see [LICENSE](LICENSE). Logitech, G HUB and LIGHTSPEED are trademarks of Logitech. Rato isn't affiliated with Logitech.
